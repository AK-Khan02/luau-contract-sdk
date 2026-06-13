"use strict";

const path = require("node:path");
const { loadAttackConfig } = require("../attackConfig");
const { loadConfig } = require("../config");
const { fromReport } = require("../contractArtifacts");
const { writeGeneratedFiles } = require("../generatedFiles");
const { generateRemoteAttackTestFiles } = require("../remoteAttackCaseGenerator");
const { generateRemoteWrapperFiles } = require("../remoteWrapperGenerator");
const { SDK_ROOT } = require("./paths");
const { exactContractsReport } = require("./exactContracts");
const { readCustomTypes, scanConfig } = require("./projectOptions");

async function runGenerate(options) {
	const projectRoot = path.resolve(options.root);
	const projectConfig = loadConfig(projectRoot, options.configPath);
	const discoveryConfig = scanConfig(projectConfig, options);
	const report = exactContractsReport(projectRoot, projectConfig, discoveryConfig, options);
	const artifacts = fromReport(report);
	const target = options.target || "all";
	const check = options.check === true || options.command === "check";
	const customTypes = readCustomTypes(projectRoot, options.customTypeMapPath);
	const attackConfig = loadAttackConfig(projectRoot, options.attackConfigPath);
	const files = [];

	if (target === "all" || target === "remotes" || target === "generated") {
		const remotesOut = path.resolve(projectRoot, options.out || "src/shared/ContractsGenerated");
		files.push(...generateRemoteWrapperFiles(artifacts, {
			outDir: remotesOut,
			attackConfig,
			customTypes,
		}));
	}

	if (target === "all" || target === "tests" || target === "generated") {
		const testsOut = path.resolve(projectRoot, options.testsOut || (target === "tests" ? options.out || "tests/generated" : "tests/generated"));
		files.push(...generateRemoteAttackTestFiles(artifacts, {
			outDir: testsOut,
			projectRoot,
			sdkRoot: SDK_ROOT,
			sdkRequire: options.sdkRequire,
			attackConfig,
		}));
	}

	if (target !== "all" && target !== "remotes" && target !== "tests" && target !== "generated") {
		throw new Error(`Unknown generate target: ${target}`);
	}

	const changed = writeGeneratedFiles(files, {
		check,
	});

	for (const warning of artifacts.warnings) {
		process.stderr.write(`${warning.level}: ${warning.message}\n`);
	}
	for (const filePath of changed) {
		process.stderr.write(`${check ? "would update" : "wrote"} ${filePath}\n`);
	}
	if (changed.length === 0) {
		process.stderr.write("generated files are up to date\n");
	}
	return 0;
}

module.exports = {
	runGenerate,
};
