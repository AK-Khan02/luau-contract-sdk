"use strict";

function defaultOptions() {
	return {
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
		system: null,
		actions: [],
		remoteKind: null,
		force: false,
		help: false,
	};
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

const OPTION_DEFINITIONS = {
	"--help": { flag: "help" },
	"-h": { flag: "help" },
	"--root": { value: "root" },
	"--config": { value: "configPath" },
	"--include": { append: "include" },
	"--exclude": { append: "exclude" },
	"--format": { apply: (options, value) => appendFormats(options.formats, value) },
	"--out": { value: "out" },
	"--out-dir": { value: "outDir" },
	"--fail-on": { value: "failOn" },
	"--max-warnings": { value: "maxWarnings", coerce: Number },
	"--baseline": { value: "baselinePath" },
	"--update-baseline": { value: "updateBaselinePath" },
	"--exact": { flag: "exact" },
	"--contract-module": { append: "contractModules" },
	"--check": { flag: "check" },
	"--tests-out": { value: "testsOut" },
	"--sdk-require": { value: "sdkRequire" },
	"--attack-config": { value: "attackConfigPath" },
	"--custom-type-map": { value: "customTypeMapPath" },
	"--generated-remotes": { value: "generatedRemotes" },
	"--generated-tests": { value: "generatedTests" },
	"--write": { flag: "write" },
	"--contracts-require": { value: "contractsRequire" },
	"--system-name": { value: "systemName" },
	"--strict-payload": { flag: "strictPayload" },
	"--luau": { value: "luauPath" },
	"--endpoint": { value: "endpoint" },
	"--api-key": { value: "apiKey" },
	"--since": { value: "since", coerce: Number },
	"--interval": { value: "intervalSeconds", coerce: Number },
	"--once": { flag: "once" },
	"--system": { value: "system" },
	"--actions": { apply: (options, value) => appendFormats(options.actions, value) },
	"--remote-kind": { value: "remoteKind" },
	"--force": { flag: "force" },
};

function splitOption(arg) {
	const separator = arg.indexOf("=");
	if (separator === -1) {
		return [arg, null];
	}
	return [arg.slice(0, separator), arg.slice(separator + 1)];
}

function optionValue(args, index, flag, inlineValue) {
	if (inlineValue != null) {
		return { value: inlineValue || takeValue(args, index, flag), consumed: false };
	}
	return { value: takeValue(args, index, flag), consumed: true };
}

function applyOption(options, args, index, arg) {
	const [flag, inlineValue] = splitOption(arg);
	const definition = OPTION_DEFINITIONS[flag];
	if (!definition) {
		throw new Error(`Unknown option: ${arg}`);
	}

	if (definition.flag) {
		options[definition.flag] = true;
		return index;
	}

	const valueResult = optionValue(args, index, flag, inlineValue);
	const value = definition.coerce ? definition.coerce(valueResult.value) : valueResult.value;
	if (definition.append) {
		options[definition.append].push(value);
	} else if (definition.value) {
		options[definition.value] = value;
	} else {
		definition.apply(options, value);
	}

	return valueResult.consumed ? index + 1 : index;
}

function parseArgs(argv, commands = {}) {
	const options = defaultOptions();
	const args = argv.slice();
	if (args[0] && !args[0].startsWith("-")) {
		options.command = args.shift();
	}
	if (commands[options.command]?.takesTarget && args[0] && !args[0].startsWith("-")) {
		options.target = args.shift();
	}

	for (let index = 0; index < args.length; index += 1) {
		index = applyOption(options, args, index, args[index]);
	}

	return options;
}

module.exports = {
	parseArgs,
};
