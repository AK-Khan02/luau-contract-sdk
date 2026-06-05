"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { compilePatterns, matchesAny, normalizePath } = require("./glob");

const LUA_EXTENSIONS = [".lua", ".luau"];

function hasLuauExtension(filePath) {
	return LUA_EXTENSIONS.some((extension) => filePath.endsWith(extension));
}

function stripLuauExtension(filePath) {
	return filePath.replace(/\.luau?$/, "");
}

function scriptNameFromFile(filePath) {
	return stripLuauExtension(path.basename(filePath)).replace(/\.(server|client)$/, "");
}

function inferClassName(relativePath) {
	if (relativePath.endsWith(".server.lua") || relativePath.endsWith(".server.luau")) {
		return "Script";
	}
	if (relativePath.endsWith(".client.lua") || relativePath.endsWith(".client.luau")) {
		return "LocalScript";
	}
	return "ModuleScript";
}

function collectRojoMappings(projectRoot) {
	const projectPath = path.join(projectRoot, "default.project.json");
	if (!fs.existsSync(projectPath)) {
		return [];
	}

	const project = JSON.parse(fs.readFileSync(projectPath, "utf8"));
	const mappings = [];

	function visit(node, instancePath) {
		if (!node || typeof node !== "object") {
			return;
		}

		if (typeof node.$path === "string") {
			mappings.push({
				sourceRoot: normalizePath(path.normalize(node.$path)),
				instancePath: instancePath.join("."),
			});
		}

		for (const [key, child] of Object.entries(node)) {
			if (!key.startsWith("$")) {
				visit(child, instancePath.concat(key));
			}
		}
	}

	visit(project.tree, []);
	return mappings.sort((left, right) => right.sourceRoot.length - left.sourceRoot.length);
}

function mappedScriptPath(relativePath, mappings) {
	const normalized = normalizePath(relativePath);
	for (const mapping of mappings) {
		if (normalized === mapping.sourceRoot || normalized.startsWith(`${mapping.sourceRoot}/`)) {
			const rest = normalized.slice(mapping.sourceRoot.length).replace(/^\//, "");
			const parts = rest === "" ? [] : stripLuauExtension(rest).split("/").map((part) => part.replace(/\.(server|client)$/, ""));
			return [mapping.instancePath].concat(parts).filter(Boolean).join(".");
		}
	}
	return stripLuauExtension(normalized).split("/").map((part, index, parts) => {
		return index === parts.length - 1 ? part.replace(/\.(server|client)$/, "") : part;
	}).join(".");
}

function shouldPruneDirectory(relativePath, excludeMatchers) {
	const normalized = normalizePath(relativePath);
	return matchesAny(`${normalized}/index.lua`, excludeMatchers) || matchesAny(`${normalized}/placeholder.luau`, excludeMatchers);
}

function walkFiles(projectRoot, excludeMatchers) {
	const files = [];

	function walk(directory) {
		for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
			const absolutePath = path.join(directory, entry.name);
			const relativePath = normalizePath(path.relative(projectRoot, absolutePath));

			if (entry.isDirectory()) {
				if (!shouldPruneDirectory(relativePath, excludeMatchers)) {
					walk(absolutePath);
				}
			} else if (entry.isFile()) {
				files.push({ absolutePath, relativePath });
			}
		}
	}

	walk(projectRoot);
	return files;
}

function discoverLuauFiles(projectRoot, includePatterns, excludePatterns) {
	const includeMatchers = compilePatterns(includePatterns);
	const excludeMatchers = compilePatterns(excludePatterns);

	return walkFiles(projectRoot, excludeMatchers)
		.filter((file) => hasLuauExtension(file.relativePath))
		.filter((file) => matchesAny(file.relativePath, includeMatchers))
		.filter((file) => !matchesAny(file.relativePath, excludeMatchers))
		.sort((left, right) => left.relativePath.localeCompare(right.relativePath));
}

function discoverScripts(projectRoot, config) {
	const mappings = collectRojoMappings(projectRoot);

	return discoverLuauFiles(projectRoot, config.include, config.exclude).map((file) => {
		return {
			path: mappedScriptPath(file.relativePath, mappings),
			filePath: file.relativePath,
			name: scriptNameFromFile(file.relativePath),
			className: inferClassName(file.relativePath),
			source: fs.readFileSync(file.absolutePath, "utf8"),
		};
	});
}

function discoverContractFiles(projectRoot, config, exactPatterns) {
	const patterns = exactPatterns.length > 0 ? exactPatterns : config.contractModules;
	const contractPatterns = patterns.length > 0 ? patterns : ["**/*.contract.lua", "**/*.contract.luau"];
	const mappings = collectRojoMappings(projectRoot);

	return discoverLuauFiles(projectRoot, contractPatterns, config.exclude).map((file) => {
		return {
			path: mappedScriptPath(file.relativePath, mappings),
			filePath: file.relativePath,
			absolutePath: file.absolutePath,
		};
	});
}

module.exports = {
	discoverContractFiles,
	discoverLuauFiles,
	discoverScripts,
	inferClassName,
	mappedScriptPath,
};
