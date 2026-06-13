"use strict";

const path = require("node:path");
const { loadAttackConfig } = require("../attackConfig");
const { loadConfig } = require("../config");
const { fromReport } = require("../contractArtifacts");
const { verifyRemoteWorkflow } = require("../remoteVerify");
const { writeReports } = require("../reportWriters");
const { SDK_ROOT } = require("./paths");
const { exactContractsReport } = require("./exactContracts");
const { readCustomTypes, scanConfig } = require("./projectOptions");

async function runVerify(options) {
	const projectRoot = path.resolve(options.root);
	const projectConfig = loadConfig(projectRoot, options.configPath);
	const discoveryConfig = scanConfig(projectConfig, options);
	const target = options.target || "remotes";
	if (target !== "remotes") {
		throw new Error(`Unknown verify target: ${target}`);
	}

	const exactReport = exactContractsReport(projectRoot, projectConfig, discoveryConfig, options);
	const artifacts = fromReport(exactReport);
	const customTypes = readCustomTypes(projectRoot, options.customTypeMapPath);
	const attackConfig = loadAttackConfig(projectRoot, options.attackConfigPath);
	const report = verifyRemoteWorkflow(artifacts, {
		projectRoot,
		sdkRoot: SDK_ROOT,
		remotesDir: options.generatedRemotes || "src/shared/ContractsGenerated",
		testsDir: options.generatedTests || options.testsOut || "tests/generated",
		sdkRequire: options.sdkRequire,
		customTypes,
		attackConfig,
		luauPath: options.luauPath,
	});
	report.contracts = exactReport.contracts;
	report.exact = exactReport.exact;

	const formats = options.formats.length > 0 ? options.formats : projectConfig.report.formats;
	const writtenReports = writeReports(report, {
		formats,
		out: options.out ? path.resolve(projectRoot, options.out) : null,
		outDir: options.outDir || projectConfig.report.outDir
			? path.resolve(projectRoot, options.outDir || projectConfig.report.outDir)
			: null,
	});
	for (const filePath of writtenReports) {
		process.stderr.write(`wrote ${filePath}\n`);
	}
	return report.policy.exitCode;
}

module.exports = {
	runVerify,
};
