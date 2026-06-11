#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { loadAttackConfig } = require("./lib/attackConfig");
const { baselineKeysFromReport } = require("./lib/ciPolicy");
const { loadConfig } = require("./lib/config");
const { fromReport } = require("./lib/contractArtifacts");
const { generatedCoverage } = require("./lib/generatedCoverage");
const { writeGeneratedFiles } = require("./lib/generatedFiles");
const { discoverContractFiles, discoverScripts } = require("./lib/projectDiscovery");
const { generateRemoteAttackTestFiles } = require("./lib/remoteAttackCaseGenerator");
const { generateRemoteWrapperFiles } = require("./lib/remoteWrapperGenerator");
const { applyMigrationPatches } = require("./lib/remoteMigrationPatcher");
const { renderMigrationContract } = require("./lib/remoteMigrationContract");
const { scanRemoteMigrations } = require("./lib/remoteMigrationScanner");
const { renderMigrationReport } = require("./lib/remoteMigrationSuggestions");
const { verifyRemoteWorkflow } = require("./lib/remoteVerify");
const { remoteSecuritySummary } = require("./lib/remoteContractModel");
const { runLuauReport } = require("./lib/luauRunner");
const { writeReports } = require("./lib/reportWriters");

const SDK_ROOT = path.resolve(__dirname, "..");

function usage() {
	return `Luau Contract SDK

Usage:
  luau-contract scan [options]
  luau-contract generate remotes [options]
  luau-contract generate tests [options]
  luau-contract generate all [options]
  luau-contract check generated [options]
  luau-contract verify remotes [options]
  luau-contract migrate scan [options]
  luau-contract migrate suggest [options]
  luau-contract migrate patch [options]
  luau-contract migrate contract [options]
  luau-contract tail --endpoint <url> [options]

Options:
  --root <path>              Project root to scan. Defaults to cwd.
  --config <path>            Config file path. Defaults to luau-contracts.json when present.
  --include <glob>           Include glob. Repeatable. Replaces config include when used.
  --exclude <glob>           Exclude glob. Repeatable. Appends to default/config excludes.
  --format <format>          text, json, sarif, markdown. Repeatable or comma-separated.
  --out <path>               Output path for a single format.
  --out-dir <path>           Directory for multiple report formats.
  --fail-on <severity>       error, warn, or info. Defaults to error.
  --max-warnings <count>     Fail when new warnings exceed count.
  --baseline <path>          Existing JSON report whose findings are allowed.
  --update-baseline <path>   Write the current JSON report for future baseline use.
  --exact                    Load exact contract reports from configured contract modules.
  --contract-module <glob>   Exact contract module glob. Repeatable.
  --check                    Check generated files without writing them.
  --tests-out <path>         Output directory for generated attack tests when generating all.
  --sdk-require <path>       Require path used by generated tests for the SDK.
  --attack-config <path>     JSON fixtures for generated actor-policy attack cases.
  --custom-type-map <path>   JSON map from custom schema names to Luau type names.
  --generated-remotes <path> Include generated wrapper coverage for this directory.
  --generated-tests <path>   Include generated attack-test coverage for this directory.
  --write                    Write migration patches. Defaults to dry-run.
  --contracts-require <path> Require target inserted by migration patch. Use lua:<expr> for raw Luau.
  --system-name <name>       System name for migrate contract drafts.
  --strict-payload           Migration patches reject extra payload fields.
  --luau <path>              Luau executable. Defaults to luau.
  --endpoint <url>           Relay server base URL for tail.
  --api-key <key>            Relay API key sent as x-api-key.
  --since <seq>              Start tailing after this relay sequence number.
  --interval <seconds>       Poll interval for tail. Defaults to 2.
  --once                     Tail once and exit instead of polling.
  --help                     Show this help.
`;
}

function takeValue(args, index, flag) {
	const value = args[index + 1];
	if (value == null || value.startsWith("--")) {
		throw new Error(`${flag} expects a value`);
	}
	return value;
}

function appendFormats(target, value) {
	for (const entry of String(value).split(",")) {
		const format = entry.trim();
		if (format !== "") {
			target.push(format);
		}
	}
}

function parseArgs(argv) {
	const options = {
		command: "scan",
		root: process.cwd(),
		configPath: null,
		include: [],
		exclude: [],
		formats: [],
		out: null,
		outDir: null,
		failOn: null,
		maxWarnings: null,
		baselinePath: null,
		updateBaselinePath: null,
		exact: false,
		contractModules: [],
		target: null,
		check: false,
		testsOut: null,
		sdkRequire: null,
		attackConfigPath: null,
		customTypeMapPath: null,
		generatedRemotes: null,
		generatedTests: null,
		write: false,
		contractsRequire: null,
		systemName: null,
		strictPayload: false,
		luauPath: "luau",
		endpoint: null,
		apiKey: null,
		since: 0,
		intervalSeconds: 2,
		once: false,
		help: false,
	};

	const args = argv.slice();
	if (args[0] && !args[0].startsWith("-")) {
		options.command = args.shift();
	}
	if ((options.command === "generate" || options.command === "check" || options.command === "verify" || options.command === "migrate") && args[0] && !args[0].startsWith("-")) {
		options.target = args.shift();
	}

	for (let index = 0; index < args.length; index += 1) {
		const arg = args[index];
		const [flag, inlineValue] = arg.includes("=") ? arg.split(/=(.*)/s, 2) : [arg, null];
		const value = inlineValue == null ? null : inlineValue;

		if (flag === "--help" || flag === "-h") {
			options.help = true;
		} else if (flag === "--root") {
			options.root = value || takeValue(args, index, flag);
			if (value == null) index += 1;
		} else if (flag === "--config") {
			options.configPath = value || takeValue(args, index, flag);
			if (value == null) index += 1;
		} else if (flag === "--include") {
			options.include.push(value || takeValue(args, index, flag));
			if (value == null) index += 1;
		} else if (flag === "--exclude") {
			options.exclude.push(value || takeValue(args, index, flag));
			if (value == null) index += 1;
		} else if (flag === "--format") {
			appendFormats(options.formats, value || takeValue(args, index, flag));
			if (value == null) index += 1;
		} else if (flag === "--out") {
			options.out = value || takeValue(args, index, flag);
			if (value == null) index += 1;
		} else if (flag === "--out-dir") {
			options.outDir = value || takeValue(args, index, flag);
			if (value == null) index += 1;
		} else if (flag === "--fail-on") {
			options.failOn = value || takeValue(args, index, flag);
			if (value == null) index += 1;
		} else if (flag === "--max-warnings") {
			options.maxWarnings = Number(value || takeValue(args, index, flag));
			if (value == null) index += 1;
		} else if (flag === "--baseline") {
			options.baselinePath = value || takeValue(args, index, flag);
			if (value == null) index += 1;
		} else if (flag === "--update-baseline") {
			options.updateBaselinePath = value || takeValue(args, index, flag);
			if (value == null) index += 1;
		} else if (flag === "--exact") {
			options.exact = true;
		} else if (flag === "--contract-module") {
			options.contractModules.push(value || takeValue(args, index, flag));
			if (value == null) index += 1;
		} else if (flag === "--check") {
			options.check = true;
		} else if (flag === "--tests-out") {
			options.testsOut = value || takeValue(args, index, flag);
			if (value == null) index += 1;
		} else if (flag === "--sdk-require") {
			options.sdkRequire = value || takeValue(args, index, flag);
			if (value == null) index += 1;
		} else if (flag === "--attack-config") {
			options.attackConfigPath = value || takeValue(args, index, flag);
			if (value == null) index += 1;
		} else if (flag === "--custom-type-map") {
			options.customTypeMapPath = value || takeValue(args, index, flag);
			if (value == null) index += 1;
		} else if (flag === "--generated-remotes") {
			options.generatedRemotes = value || takeValue(args, index, flag);
			if (value == null) index += 1;
		} else if (flag === "--generated-tests") {
			options.generatedTests = value || takeValue(args, index, flag);
			if (value == null) index += 1;
		} else if (flag === "--write") {
			options.write = true;
		} else if (flag === "--contracts-require") {
			options.contractsRequire = value || takeValue(args, index, flag);
			if (value == null) index += 1;
		} else if (flag === "--system-name") {
			options.systemName = value || takeValue(args, index, flag);
			if (value == null) index += 1;
		} else if (flag === "--strict-payload") {
			options.strictPayload = true;
		} else if (flag === "--luau") {
			options.luauPath = value || takeValue(args, index, flag);
			if (value == null) index += 1;
		} else if (flag === "--endpoint") {
			options.endpoint = value || takeValue(args, index, flag);
			if (value == null) index += 1;
		} else if (flag === "--api-key") {
			options.apiKey = value || takeValue(args, index, flag);
			if (value == null) index += 1;
		} else if (flag === "--since") {
			options.since = Number(value || takeValue(args, index, flag));
			if (value == null) index += 1;
		} else if (flag === "--interval") {
			options.intervalSeconds = Number(value || takeValue(args, index, flag));
			if (value == null) index += 1;
		} else if (flag === "--once") {
			options.once = true;
		} else {
			throw new Error(`Unknown option: ${arg}`);
		}
	}

	return options;
}

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

function formatRelayEntry(serverId, entry) {
	const parts = [`[${entry.level || "info"}]`];
	if (serverId != null) {
		parts.push(`${serverId}`);
	}
	if (entry.system != null) {
		parts.push(`${entry.system}`);
	}
	parts.push(`${entry.name || entry.code || "Diagnostic"}`);
	const prefix = parts.join(" ");
	return entry.message != null ? `${prefix}: ${entry.message}` : prefix;
}

async function fetchTail(options, since) {
	const url = new URL("/tail", options.endpoint);
	url.searchParams.set("since", String(since));
	const headers = {};
	if (options.apiKey != null) {
		headers["x-api-key"] = options.apiKey;
	}

	const response = await fetch(url, { headers });
	if (response.status === 401) {
		throw new Error("relay rejected the API key (401)");
	}
	if (!response.ok) {
		throw new Error(`relay returned status ${response.status}`);
	}
	return response.json();
}

function isRecordObject(value) {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

// The endpoint is caller-supplied and may not be a relay at all; treat the
// payload as untrusted and skip records that do not match the wire shape.
function printTailPage(page) {
	if (!isRecordObject(page) || !Array.isArray(page.batches)) {
		throw new Error("relay returned an unexpected payload");
	}
	if (page.dropped > 0) {
		process.stdout.write(`-- relay dropped ${page.dropped} batch(es) before this point --\n`);
	}
	for (const record of page.batches) {
		if (!isRecordObject(record) || !isRecordObject(record.batch)) {
			continue;
		}
		const entries = Array.isArray(record.batch.entries) ? record.batch.entries : [];
		for (const entry of entries) {
			if (isRecordObject(entry)) {
				process.stdout.write(`${formatRelayEntry(record.serverId, entry)}\n`);
			}
		}
	}
}

async function runTail(options) {
	if (typeof options.endpoint !== "string" || options.endpoint === "") {
		throw new Error("tail requires --endpoint");
	}
	if (!Number.isInteger(options.since) || options.since < 0) {
		throw new Error("--since must be a non-negative integer");
	}
	if (!Number.isFinite(options.intervalSeconds) || options.intervalSeconds <= 0) {
		throw new Error("--interval must be a positive number");
	}

	let since = options.since;

	if (options.once) {
		try {
			printTailPage(await fetchTail(options, since));
		} catch (error) {
			process.stderr.write(`tail: ${error.message}\n`);
			return 1;
		}
		return 0;
	}

	process.stderr.write(`tailing ${options.endpoint} (every ${options.intervalSeconds}s, since ${since})\n`);
	for (;;) {
		try {
			const page = await fetchTail(options, since);
			printTailPage(page);
			if (Number.isInteger(page.latest)) {
				since = Math.max(since, page.latest);
			}
		} catch (error) {
			process.stderr.write(`tail: ${error.message}\n`);
		}
		await new Promise((resolve) => {
			setTimeout(resolve, options.intervalSeconds * 1000);
		});
	}
}

async function main(argv) {
	const options = parseArgs(argv);
	if (options.help) {
		process.stdout.write(usage());
		return 0;
	}
	if (options.command !== "scan") {
		if (options.command === "generate" || options.command === "check") {
			if (options.command === "check" && (options.target || "generated") !== "generated") {
				throw new Error(`Unknown check target: ${options.target}`);
			}
			if (options.command === "check") {
				options.target = "generated";
			}
			return runGenerate(options);
		}
		if (options.command === "verify") {
			return runVerify(options);
		}
		if (options.command === "migrate") {
			return runMigrate(options);
		}
		if (options.command === "tail") {
			return runTail(options);
		}
		throw new Error(`Unknown command: ${options.command}`);
	}
	return runScan(options);
}

if (require.main === module) {
	main(process.argv.slice(2))
		.then((exitCode) => {
			process.exitCode = exitCode;
		})
		.catch((error) => {
			process.stderr.write(`${error.message}\n`);
			process.exitCode = 2;
		});
}

module.exports = {
	main,
	parseArgs,
};
