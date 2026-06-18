"use strict";

const { runGenerate } = require("./generateCommand");
const { runInit } = require("./initCommand");
const { parseArgs: parseCliArgs } = require("./parser");
const { runMigrate } = require("./migrateCommand");
const { runScaffold } = require("./scaffoldCommand");
const { runScan } = require("./scanCommand");
const { runTail } = require("./tailCommand");
const { usage } = require("./usage");
const { runVerify } = require("./verifyCommand");

const COMMANDS = {
	scan: {
		run: runScan,
	},
	generate: {
		takesTarget: true,
		run: runGenerate,
	},
	check: {
		takesTarget: true,
		normalize(options) {
			if ((options.target || "generated") !== "generated") {
				throw new Error(`Unknown check target: ${options.target}`);
			}
			options.target = "generated";
		},
		run: runGenerate,
	},
	verify: {
		takesTarget: true,
		run: runVerify,
	},
	migrate: {
		takesTarget: true,
		run: runMigrate,
	},
	tail: {
		run: runTail,
	},
	scaffold: {
		run: runScaffold,
	},
	init: {
		run: runInit,
	},
};

function parseArgs(argv) {
	return parseCliArgs(argv, COMMANDS);
}

async function main(argv) {
	const options = parseArgs(argv);
	if (options.help) {
		process.stdout.write(usage());
		return 0;
	}
	const command = COMMANDS[options.command];
	if (!command) {
		throw new Error(`Unknown command: ${options.command}`);
	}
	if (command.normalize) {
		command.normalize(options);
	}
	return command.run(options);
}

module.exports = {
	main,
	parseArgs,
};
