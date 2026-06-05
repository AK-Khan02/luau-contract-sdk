#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { baselineKeysFromReport } = require("./lib/ciPolicy");
const { loadConfig } = require("./lib/config");
const { discoverContractFiles, discoverScripts } = require("./lib/projectDiscovery");
const { runLuauReport } = require("./lib/luauRunner");
const { writeReports } = require("./lib/reportWriters");

const SDK_ROOT = path.resolve(__dirname, "..");

function usage() {
	return `Luau Contract SDK

Usage:
  luau-contract scan [options]

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
  --luau <path>              Luau executable. Defaults to luau.
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
		luauPath: "luau",
		help: false,
	};

	const args = argv.slice();
	if (args[0] && !args[0].startsWith("-")) {
		options.command = args.shift();
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
		} else if (flag === "--luau") {
			options.luauPath = value || takeValue(args, index, flag);
			if (value == null) index += 1;
		} else {
			throw new Error(`Unknown option: ${arg}`);
		}
	}

	return options;
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

async function main(argv) {
	const options = parseArgs(argv);
	if (options.help) {
		process.stdout.write(usage());
		return 0;
	}
	if (options.command !== "scan") {
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
