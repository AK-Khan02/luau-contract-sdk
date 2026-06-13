#!/usr/bin/env node
"use strict";

const { main, parseArgs } = require("./lib/cli");

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
