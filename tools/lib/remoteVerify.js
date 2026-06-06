"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { generatedCoverage } = require("./generatedCoverage");
const { remoteSecuritySummary } = require("./remoteContractModel");

function generatedFilesAreCurrent(generated) {
	const summary = generated.summary || {};
	return (summary.missingFileCount || 0) === 0 && (summary.staleFileCount || 0) === 0;
}

function runAttackTests(testsDir, luauPath) {
	const runFile = path.join(testsDir, "run.luau");
	if (!fs.existsSync(runFile)) {
		return {
			ok: false,
			skipped: false,
			command: `${luauPath} ${runFile}`,
			reason: "generated attack test runner is missing",
			status: null,
			stdout: "",
			stderr: "",
		};
	}

	const result = spawnSync(luauPath, [runFile], {
		encoding: "utf8",
	});
	return {
		ok: result.status === 0,
		skipped: false,
		command: `${luauPath} ${runFile}`,
		status: result.status,
		stdout: result.stdout || "",
		stderr: result.stderr || "",
	};
}

function skippedAttackTests(reason, testsDir, luauPath) {
	return {
		ok: false,
		skipped: true,
		command: `${luauPath} ${path.join(testsDir, "run.luau")}`,
		reason,
		status: null,
		stdout: "",
		stderr: "",
	};
}

function policyFor(generated, attackTestRun) {
	const reasons = [];
	const summary = generated.summary || {};
	if ((summary.missingFileCount || 0) > 0) {
		reasons.push(`${summary.missingFileCount} generated remote files are missing`);
	}
	if ((summary.staleFileCount || 0) > 0) {
		reasons.push(`${summary.staleFileCount} generated remote files are stale`);
	}
	if (!attackTestRun.skipped && attackTestRun.ok !== true) {
		reasons.push("generated remote attack tests failed");
	}
	if (attackTestRun.skipped) {
		reasons.push(attackTestRun.reason);
	}
	return {
		ok: reasons.length === 0,
		exitCode: reasons.length === 0 ? 0 : 1,
		reasons,
	};
}

function verifyRemoteWorkflow(artifacts, options = {}) {
	const projectRoot = path.resolve(options.projectRoot || process.cwd());
	const remotesDir = path.resolve(projectRoot, options.remotesDir || "src/shared/ContractsGenerated");
	const testsDir = path.resolve(projectRoot, options.testsDir || "tests/generated");
	const luauPath = options.luauPath || "luau";
	const generated = generatedCoverage(artifacts, {
		projectRoot,
		sdkRoot: options.sdkRoot,
		remotesDir,
		testsDir,
		sdkRequire: options.sdkRequire,
		customTypes: options.customTypes || {},
		attackConfig: options.attackConfig || {},
	});

	const attackTestRun = generatedFilesAreCurrent(generated)
		? runAttackTests(testsDir, luauPath)
		: skippedAttackTests("generated remote files must be current before attack tests can run", testsDir, luauPath);
	const policy = policyFor(generated, attackTestRun);

	return {
		summary: {
			scriptCount: 0,
			systemCount: artifacts.contracts.length,
			contractCount: artifacts.contracts.length,
			scannerFindingCount: 0,
			remoteCount: generated.summary.remoteCount,
			attackCaseCount: generated.summary.attackCaseCount,
		},
		policy,
		generated,
		remoteSecurity: remoteSecuritySummary(artifacts, {
			attackConfig: options.attackConfig || {},
		}),
		verify: {
			remotesDir,
			testsDir,
			attackTestRun,
		},
	};
}

module.exports = {
	verifyRemoteWorkflow,
};
