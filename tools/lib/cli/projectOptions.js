"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { baselineKeysFromReport } = require("../ciPolicy");

function readBaselineKeys(projectRoot, baselinePath) {
	if (!baselinePath) {
		return [];
	}
	const absolutePath = path.resolve(projectRoot, baselinePath);
	if (!fs.existsSync(absolutePath)) {
		return [];
	}
	return baselineKeysFromReport(JSON.parse(fs.readFileSync(absolutePath, "utf8")));
}

function writeBaseline(projectRoot, baselinePath, report) {
	if (!baselinePath) {
		return null;
	}
	const absolutePath = path.resolve(projectRoot, baselinePath);
	fs.mkdirSync(path.dirname(absolutePath), { recursive: true });
	fs.writeFileSync(absolutePath, `${JSON.stringify(report, null, 2)}\n`);
	return absolutePath;
}

function scanConfig(projectConfig, options) {
	return {
		include: options.include.length > 0 ? options.include : projectConfig.include,
		exclude: projectConfig.exclude.concat(options.exclude),
		contractModules: projectConfig.contractModules.concat(options.contractModules),
	};
}

function readCustomTypes(projectRoot, customTypeMapPath) {
	if (!customTypeMapPath) {
		return {};
	}
	return JSON.parse(fs.readFileSync(path.resolve(projectRoot, customTypeMapPath), "utf8"));
}

module.exports = {
	readBaselineKeys,
	readCustomTypes,
	scanConfig,
	writeBaseline,
};
