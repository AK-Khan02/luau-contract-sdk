"use strict";

const path = require("node:path");
const { loadAttackConfig } = require("../attackConfig");
const { loadConfig } = require("../config");
const { fromReport } = require("../contractArtifacts");
const { generatedCoverage } = require("../generatedCoverage");
const { discoverContractFiles, discoverScripts } = require("../projectDiscovery");
const { remoteSecuritySummary } = require("../remoteContractModel");
const { runLuauReport } = require("../luauRunner");
const { writeReports } = require("../reportWriters");
const { SDK_ROOT } = require("./paths");
const { readBaselineKeys, readCustomTypes, scanConfig, writeBaseline } = require("./projectOptions");

async function runScan(options) {
	const projectRoot = path.resolve(options.root);
	const projectConfig = loadConfig(projectRoot, options.configPath);
	const discoveryConfig = scanConfig(projectConfig, options);
	const exact = options.exact || projectConfig.exact || discoveryConfig.contractModules.length > 0;
	const formats = options.formats.length > 0 ? options.formats : projectConfig.report.formats;

	const scripts = discoverScripts(projectRoot, discoveryConfig);
	const contractFiles = exact ? discoverContractFiles(projectRoot, discoveryConfig, discoveryConfig.contractModules) : [];
	const baselineKeys = readBaselineKeys(projectRoot, options.baselinePath);

	const report = runLuauReport({
		sdkRoot: SDK_ROOT,
		projectRoot,
		scripts,
		contractFiles,
		luauPath: options.luauPath,
		policy: {
			failOn: options.failOn || projectConfig.failOn,
			maxWarnings: options.maxWarnings == null ? projectConfig.maxWarnings : options.maxWarnings,
			baselineKeys,
		},
	});

	if (options.generatedRemotes || options.generatedTests) {
		const artifacts = fromReport(report);
		const attackConfig = loadAttackConfig(projectRoot, options.attackConfigPath);
		report.generated = generatedCoverage(artifacts, {
			projectRoot,
			sdkRoot: SDK_ROOT,
			remotesDir: options.generatedRemotes,
			testsDir: options.generatedTests,
			sdkRequire: options.sdkRequire,
			customTypes: readCustomTypes(projectRoot, options.customTypeMapPath),
			attackConfig,
		});
		report.remoteSecurity = remoteSecuritySummary(artifacts, {
			attackConfig,
		});
	}

	const outputOptions = {
		formats,
		out: options.out ? path.resolve(projectRoot, options.out) : null,
		outDir: options.outDir || projectConfig.report.outDir
			? path.resolve(projectRoot, options.outDir || projectConfig.report.outDir)
			: null,
	};
	const writtenReports = writeReports(report, outputOptions);
	const writtenBaseline = writeBaseline(projectRoot, options.updateBaselinePath, report);

	for (const filePath of writtenReports.concat(writtenBaseline ? [writtenBaseline] : [])) {
		process.stderr.write(`wrote ${filePath}\n`);
	}

	return report.policy?.exitCode || 0;
}

module.exports = {
	runScan,
};
