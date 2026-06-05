"use strict";

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const test = require("node:test");
const { globToRegExp } = require("../lib/glob");
const { discoverScripts } = require("../lib/projectDiscovery");
const { renderReport } = require("../lib/reportWriters");

const repoRoot = path.resolve(__dirname, "../..");
const cliPath = path.join(repoRoot, "tools/luau-contract.js");

function makeTempProject() {
	const projectRoot = fs.mkdtempSync(path.join(os.tmpdir(), "luau-contract-test-"));
	fs.mkdirSync(path.join(projectRoot, "src"), { recursive: true });
	fs.writeFileSync(path.join(projectRoot, "default.project.json"), JSON.stringify({
		name: "TestProject",
		tree: {
			$className: "DataModel",
			ServerScriptService: {
				$path: "src",
			},
		},
	}, null, 2));
	return projectRoot;
}

test("glob matcher supports recursive Luau patterns", () => {
	const matcher = globToRegExp("src/**/*.lua");
	assert.equal(matcher.test("src/Inventory.lua"), true);
	assert.equal(matcher.test("src/server/Inventory.lua"), true);
	assert.equal(matcher.test("plugin/Inventory.lua"), false);
});

test("project discovery maps Rojo paths and infers script classes", () => {
	const projectRoot = makeTempProject();
	fs.writeFileSync(path.join(projectRoot, "src", "Match.server.lua"), "print('match')");

	const scripts = discoverScripts(projectRoot, {
		include: ["src/**/*.lua"],
		exclude: [],
	});

	assert.equal(scripts.length, 1);
	assert.equal(scripts[0].path, "ServerScriptService.Match");
	assert.equal(scripts[0].className, "Script");
});

test("report writers render JSON and SARIF", () => {
	const report = {
		summary: { scriptCount: 1, systemCount: 0, contractCount: 0, scannerFindingCount: 1 },
		policy: { ok: false, reasons: ["1 new finding"] },
		scanner: {
			rules: {
				"raw-remote-handler": {
					id: "raw-remote-handler",
					title: "Raw remote server handler",
					severity: "error",
				},
			},
			findings: [
				{
					ruleId: "raw-remote-handler",
					severity: "error",
					path: "ServerScriptService.Match",
					line: 1,
					column: 1,
					message: "unsafe",
					snippet: "Remote.OnServerEvent:Connect",
				},
			],
		},
		exact: { errors: [] },
	};

	assert.match(renderReport(report, "json"), /"raw-remote-handler"/);
	assert.match(renderReport(report, "sarif"), /"version": "2.1.0"/);
});

test("cli scan fails on new raw remote and passes with baseline", () => {
	const projectRoot = makeTempProject();
	const reportPath = path.join(projectRoot, "report.json");
	fs.writeFileSync(path.join(projectRoot, "src", "Unsafe.server.lua"), `
DeployRequest.OnServerEvent:Connect(function(player, payload)
\tprint(payload)
end)
`);

	const firstRun = spawnSync(process.execPath, [
		cliPath,
		"scan",
		"--root",
		projectRoot,
		"--format",
		"json",
		"--out",
		reportPath,
		"--fail-on",
		"error",
	], {
		cwd: repoRoot,
		encoding: "utf8",
	});

	assert.equal(firstRun.status, 1, firstRun.stderr || firstRun.stdout);
	const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
	assert.equal(report.summary.scannerFindingCount, 1);
	assert.equal(report.scanner.findings[0].path, "ServerScriptService.Unsafe");

	const secondRun = spawnSync(process.execPath, [
		cliPath,
		"scan",
		"--root",
		projectRoot,
		"--format",
		"json",
		"--out",
		path.join(projectRoot, "second-report.json"),
		"--baseline",
		reportPath,
		"--fail-on",
		"error",
	], {
		cwd: repoRoot,
		encoding: "utf8",
	});

	assert.equal(secondRun.status, 0, secondRun.stderr || secondRun.stdout);
});

test("cli exact mode loads configured contract modules", () => {
	const reportPath = path.join(os.tmpdir(), `luau-contract-exact-${process.pid}.json`);
	const run = spawnSync(process.execPath, [
		cliPath,
		"scan",
		"--root",
		repoRoot,
		"--exact",
		"--contract-module",
		"examples/inventory.contract.lua",
		"--format",
		"json",
		"--out",
		reportPath,
	], {
		cwd: repoRoot,
		encoding: "utf8",
	});

	assert.equal(run.status, 0, run.stderr || run.stdout);
	const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
	assert.equal(report.contracts.some((contract) => contract.name === "InventoryService"), true);
	fs.rmSync(reportPath, { force: true });
});

test("cli exact mode loads contract modules outside sdk root", () => {
	const projectRoot = makeTempProject();
	const reportPath = path.join(projectRoot, "exact-report.json");
	fs.writeFileSync(path.join(projectRoot, "src", "External.contract.lua"), `
return {
\tdescribe = function()
\t\treturn {
\t\t\tformatVersion = 1,
\t\t\tname = "ExternalInventory",
\t\t\tactions = {},
\t\t\tremotes = {},
\t\t\tlifecycles = {},
\t\t\tpermissions = {
\t\t\t\tstrict = true,
\t\t\t},
\t\t}
\tend,
}
`);

	const run = spawnSync(process.execPath, [
		cliPath,
		"scan",
		"--root",
		projectRoot,
		"--exact",
		"--contract-module",
		"src/*.contract.lua",
		"--format",
		"json",
		"--out",
		reportPath,
	], {
		cwd: repoRoot,
		encoding: "utf8",
	});

	assert.equal(run.status, 0, run.stderr || run.stdout);
	const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
	assert.equal(report.contracts.some((contract) => contract.name === "ExternalInventory"), true);
	assert.equal(report.exact.errors.length, 0);
});
