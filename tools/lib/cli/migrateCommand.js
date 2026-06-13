"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { loadConfig } = require("../config");
const { discoverScripts } = require("../projectDiscovery");
const { applyMigrationPatches } = require("../remoteMigrationPatcher");
const { renderMigrationContract } = require("../remoteMigrationContract");
const { scanRemoteMigrations } = require("../remoteMigrationScanner");
const { renderMigrationReport } = require("../remoteMigrationSuggestions");
const { scanConfig } = require("./projectOptions");

function writeMigrationReports(projectRoot, report, options) {
	const formats = options.formats.length > 0 ? options.formats : ["text"];
	if (formats.length > 1 && !options.outDir) {
		throw new Error("Multiple migration report formats require --out-dir");
	}
	if (options.out && formats.length !== 1) {
		throw new Error("--out can only be used with one --format value");
	}

	const written = [];
	for (const format of formats) {
		const contents = renderMigrationReport(report, format);
		if (options.out) {
			const outputPath = path.resolve(projectRoot, options.out);
			fs.mkdirSync(path.dirname(outputPath), { recursive: true });
			fs.writeFileSync(outputPath, contents);
			written.push(outputPath);
		} else if (options.outDir) {
			const extension = format === "markdown" ? "md" : format;
			const outputPath = path.resolve(projectRoot, options.outDir, `remote-migration.${extension}`);
			fs.mkdirSync(path.dirname(outputPath), { recursive: true });
			fs.writeFileSync(outputPath, contents);
			written.push(outputPath);
		} else {
			process.stdout.write(contents);
		}
	}
	return written;
}

async function runMigrate(options) {
	const projectRoot = path.resolve(options.root);
	const projectConfig = loadConfig(projectRoot, options.configPath);
	const discoveryConfig = scanConfig(projectConfig, options);
	const target = options.target || "scan";

	if (target !== "scan" && target !== "suggest" && target !== "patch" && target !== "contract") {
		throw new Error(`Unknown migrate target: ${target}`);
	}

	const scripts = discoverScripts(projectRoot, discoveryConfig);
	const report = scanRemoteMigrations(scripts);
	report.mode = target;

	if (target === "contract") {
		const contents = renderMigrationContract(report.findings, {
			contractsRequire: options.contractsRequire,
			strictPayload: options.strictPayload,
			systemName: options.systemName,
		});
		if (options.out) {
			const outputPath = path.resolve(projectRoot, options.out);
			fs.mkdirSync(path.dirname(outputPath), { recursive: true });
			fs.writeFileSync(outputPath, contents);
			process.stderr.write(`wrote ${outputPath}\n`);
		} else {
			process.stdout.write(contents);
		}
		return 0;
	}

	if (target === "patch") {
		report.patches = applyMigrationPatches(projectRoot, report.findings, {
			contractsRequire: options.contractsRequire,
			strictPayload: options.strictPayload,
			write: options.write,
		});
		report.summary.patchedCount = report.patches.filter((patch) => patch.status === "patched").length;
		report.summary.wouldPatchCount = report.patches.filter((patch) => patch.status === "would-patch").length;
		report.summary.skippedCount = report.patches.filter((patch) => patch.status === "skipped").length;
	}

	const writtenReports = writeMigrationReports(projectRoot, report, options);
	for (const filePath of writtenReports) {
		process.stderr.write(`wrote ${filePath}\n`);
	}

	return 0;
}

module.exports = {
	runMigrate,
};
