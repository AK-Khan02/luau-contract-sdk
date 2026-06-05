"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { normalizePath } = require("./glob");

const JSON_MARKER = "__LUAU_CONTRACT_JSON__";

function luaString(value) {
	const text = String(value);
	let level = 0;
	while (text.includes(`]${"=".repeat(level)}]`)) {
		level += 1;
	}
	return `[${"=".repeat(level)}[${text}]${"=".repeat(level)}]`;
}

function luaLiteral(value) {
	if (value == null) {
		return "nil";
	}
	if (typeof value === "string") {
		return luaString(value);
	}
	if (typeof value === "number") {
		if (!Number.isFinite(value)) {
			throw new Error("Cannot encode non-finite number as Luau literal");
		}
		return String(value);
	}
	if (typeof value === "boolean") {
		return value ? "true" : "false";
	}
	if (Array.isArray(value)) {
		return `{${value.map((child) => luaLiteral(child)).join(",")}}`;
	}
	if (typeof value === "object") {
		const entries = Object.entries(value)
			.filter(([, child]) => child !== undefined)
			.sort(([left], [right]) => left.localeCompare(right))
			.map(([key, child]) => `[ ${luaString(key)} ]=${luaLiteral(child)}`);
		return `{${entries.join(",")}}`;
	}
	throw new Error(`Cannot encode ${typeof value} as Luau literal`);
}

function stripLuauExtension(filePath) {
	return filePath.replace(/\.luau?$/, "");
}

function modulePathFromSdkRoot(sdkRoot, absolutePath, projectLink) {
	if (projectLink && absolutePath.startsWith(`${projectLink.projectRoot}${path.sep}`)) {
		const relativeProjectPath = normalizePath(path.relative(projectLink.projectRoot, absolutePath));
		return `./${projectLink.name}/${stripLuauExtension(relativeProjectPath)}`;
	}

	const relativePath = normalizePath(path.relative(sdkRoot, absolutePath));
	const modulePath = stripLuauExtension(relativePath);
	return modulePath.startsWith(".") ? modulePath : `./${modulePath}`;
}

function runnerSource(input, contractFiles, sdkRoot, projectLink) {
	const exactLoads = contractFiles.map((file) => {
		return {
			path: file.filePath,
			modulePath: modulePathFromSdkRoot(sdkRoot, file.absolutePath, projectLink),
		};
	});

	return `local ScanRunner = require("./src/Host/ScanRunner")
local JsonEncode = require("./src/Host/JsonEncode")

local input = ${luaLiteral(input)}
local contracts = {}
local exactErrors = {}

local function addContract(path, value)
\tif type(value) == "table" and type(value.describe) == "function" then
\t\ttable.insert(contracts, {
\t\t\tpath = path,
\t\t\tcontract = value,
\t\t})
\t\treturn
\tend

\tif type(value) == "table" and value.Contract ~= nil then
\t\taddContract(path, value.Contract)
\t\treturn
\tend

\tif type(value) == "table" and type(value.Contracts) == "table" then
\t\tfor _, contract in ipairs(value.Contracts) do
\t\t\taddContract(path, contract)
\t\tend
\t\treturn
\tend

\ttable.insert(exactErrors, {
\t\tpath = path,
\t\tmessage = "module did not return a contract, Contract, or Contracts array",
\t})
end

for _, load in ipairs(${luaLiteral(exactLoads)}) do
\tlocal ok, value = pcall(require, load.modulePath)
\tif ok then
\t\taddContract(load.path, value)
\telse
\t\ttable.insert(exactErrors, {
\t\t\tpath = load.path,
\t\t\tmessage = tostring(value),
\t\t})
\tend
end

input.contracts = contracts
input.exactErrors = exactErrors

local report = ScanRunner.run(input)
print("${JSON_MARKER}" .. JsonEncode.encode(report))
`;
}

function needsProjectLink(sdkRoot, projectRoot, contractFiles) {
	if (!projectRoot || path.resolve(projectRoot) === path.resolve(sdkRoot)) {
		return false;
	}
	return contractFiles.some((file) => path.relative(sdkRoot, file.absolutePath).startsWith(".."));
}

function shouldCopyProjectEntry(sourcePath) {
	const baseName = path.basename(sourcePath);
	return ![
		".git",
		"node_modules",
		"Packages",
		"DevPackages",
		"reports",
	].includes(baseName) && !baseName.startsWith("luau-contract-project-");
}

function createProjectLink(sdkRoot, projectRoot, contractFiles) {
	if (!needsProjectLink(sdkRoot, projectRoot, contractFiles)) {
		return null;
	}

	const name = `luau-contract-project-${process.pid}-${Date.now()}`;
	const linkPath = path.join(sdkRoot, name);
	fs.cpSync(projectRoot, linkPath, {
		recursive: true,
		filter: shouldCopyProjectEntry,
	});
	return {
		name,
		linkPath,
		projectRoot,
	};
}

function extractReport(stdout) {
	const line = stdout
		.split(/\r?\n/)
		.reverse()
		.find((entry) => entry.startsWith(JSON_MARKER));

	if (!line) {
		throw new Error("Luau runner did not emit a contract report");
	}

	return JSON.parse(line.slice(JSON_MARKER.length));
}

function runLuauReport(options) {
	const sdkRoot = options.sdkRoot;
	const contractFiles = options.contractFiles || [];
	const projectLink = createProjectLink(sdkRoot, options.projectRoot, contractFiles);
	const runnerPath = path.join(sdkRoot, `.luau-contract-runner-${process.pid}-${Date.now()}.lua`);
	const input = {
		scripts: options.scripts,
		policy: options.policy,
	};

	fs.writeFileSync(runnerPath, runnerSource(input, contractFiles, sdkRoot, projectLink));

	try {
		const result = spawnSync(options.luauPath || "luau", [runnerPath], {
			cwd: sdkRoot,
			encoding: "utf8",
			maxBuffer: 1024 * 1024 * 64,
		});

		if (result.status !== 0) {
			const details = [result.stderr, result.stdout].filter(Boolean).join("\n");
			throw new Error(details || `Luau runner failed with exit code ${result.status}`);
		}

		return extractReport(result.stdout || "");
	} finally {
		fs.rmSync(runnerPath, { force: true });
		if (projectLink) {
			fs.rmSync(projectLink.linkPath, { force: true, recursive: true });
		}
	}
}

module.exports = {
	JSON_MARKER,
	luaLiteral,
	modulePathFromSdkRoot,
	runLuauReport,
};
