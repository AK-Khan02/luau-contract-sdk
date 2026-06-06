"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { attackCaseSummary, generateRemoteAttackTestFiles } = require("./remoteAttackCaseGenerator");
const { generateRemoteWrapperFiles } = require("./remoteWrapperGenerator");

function fileStatus(projectRoot, generatedFile, kind) {
	const exists = fs.existsSync(generatedFile.path);
	const current = exists ? fs.readFileSync(generatedFile.path, "utf8") : null;
	const relativePath = path.relative(projectRoot, generatedFile.path).replace(/\\/g, "/");
	const displayPath = relativePath.startsWith("../") || relativePath === ".."
		? generatedFile.path
		: relativePath;
	return {
		kind,
		path: displayPath,
		absolutePath: generatedFile.path,
		exists,
		stale: exists && current !== generatedFile.contents,
	};
}

function summarizeFiles(files) {
	return {
		expectedFileCount: files.length,
		presentFileCount: files.filter((file) => file.exists).length,
		missingFileCount: files.filter((file) => !file.exists).length,
		staleFileCount: files.filter((file) => file.stale).length,
	};
}

function generatedCoverage(artifacts, options = {}) {
	const projectRoot = path.resolve(options.projectRoot || process.cwd());
	const files = [];

	if (options.remotesDir) {
		const remotesDir = path.resolve(projectRoot, options.remotesDir);
		files.push(...generateRemoteWrapperFiles(artifacts, {
			outDir: remotesDir,
			attackConfig: options.attackConfig || {},
			customTypes: options.customTypes || {},
		}).map((file) => fileStatus(projectRoot, file, "remote-wrapper")));
	}

	if (options.testsDir) {
		const testsDir = path.resolve(projectRoot, options.testsDir);
		files.push(...generateRemoteAttackTestFiles(artifacts, {
			outDir: testsDir,
			projectRoot,
			sdkRoot: options.sdkRoot,
			sdkRequire: options.sdkRequire,
			attackConfig: options.attackConfig || {},
		}).map((file) => fileStatus(projectRoot, file, "remote-attack-test")));
	}

	const attackCases = attackCaseSummary(artifacts, {
		attackConfig: options.attackConfig || {},
	});

	return {
		summary: {
			...summarizeFiles(files),
			remoteCount: attackCases.remoteCount,
			attackCaseCount: attackCases.caseCount,
		},
		files,
		attackCases: attackCases.remotes,
	};
}

module.exports = {
	generatedCoverage,
};
