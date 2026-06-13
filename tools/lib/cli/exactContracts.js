"use strict";

const { discoverContractFiles } = require("../projectDiscovery");
const { runLuauReport } = require("../luauRunner");
const { SDK_ROOT } = require("./paths");

function exactContractsReport(projectRoot, projectConfig, discoveryConfig, options) {
	const contractFiles = discoverContractFiles(projectRoot, discoveryConfig, discoveryConfig.contractModules);
	if (contractFiles.length === 0 && discoveryConfig.contractModules.length > 0) {
		const patterns = discoveryConfig.contractModules.join(", ");
		throw new Error(`no contract modules matched: ${patterns}`);
	}
	const report = runLuauReport({
		sdkRoot: SDK_ROOT,
		projectRoot,
		scripts: [],
		contractFiles,
		luauPath: options.luauPath,
		policy: {
			failOn: "error",
		},
	});

	if ((report.exact?.errors || []).length > 0) {
		const details = report.exact.errors.map((error) => `${error.path}: ${error.message}`).join("\n");
		throw new Error(`cannot generate from contracts with exact load errors:\n${details}`);
	}
	return report;
}

module.exports = {
	exactContractsReport,
};
