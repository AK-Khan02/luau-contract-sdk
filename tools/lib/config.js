"use strict";

const fs = require("node:fs");
const path = require("node:path");

const DEFAULT_CONFIG = Object.freeze({
	include: ["**/*.lua", "**/*.luau"],
	exclude: [
		".git/**",
		".planning/**",
		".codex/**",
		".agents/**",
		"node_modules/**",
		"Packages/**",
		"DevPackages/**",
		"tests/**",
		".luau-contract-runner-*.lua",
		"luau-contract-project-*/**",
	],
	failOn: "error",
	maxWarnings: null,
	exact: false,
	contractModules: [],
	report: {
		formats: ["text"],
		outDir: null,
	},
});

function readJsonFile(filePath) {
	return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function findConfigPath(projectRoot, explicitPath) {
	if (explicitPath) {
		return path.resolve(projectRoot, explicitPath);
	}

	const candidate = path.join(projectRoot, "luau-contracts.json");
	return fs.existsSync(candidate) ? candidate : null;
}

function arrayValue(value, fallback) {
	if (value == null) {
		return fallback.slice();
	}
	if (Array.isArray(value)) {
		return value.slice();
	}
	return [value];
}

function loadConfig(projectRoot, explicitPath) {
	const configPath = findConfigPath(projectRoot, explicitPath);
	const fileConfig = configPath ? readJsonFile(configPath) : {};
	const report = fileConfig.report || {};

	return {
		configPath,
		include: arrayValue(fileConfig.include, DEFAULT_CONFIG.include),
		exclude: DEFAULT_CONFIG.exclude.concat(arrayValue(fileConfig.exclude, [])),
		failOn: fileConfig.failOn || DEFAULT_CONFIG.failOn,
		maxWarnings: fileConfig.maxWarnings == null ? DEFAULT_CONFIG.maxWarnings : Number(fileConfig.maxWarnings),
		exact: fileConfig.exact === true,
		contractModules: arrayValue(fileConfig.contractModules, DEFAULT_CONFIG.contractModules),
		report: {
			formats: arrayValue(report.formats, DEFAULT_CONFIG.report.formats),
			outDir: report.outDir || DEFAULT_CONFIG.report.outDir,
		},
	};
}

module.exports = {
	DEFAULT_CONFIG,
	loadConfig,
};
