"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { scaffoldSystem } = require("./scaffoldCommand");

// Minimal config using only keys understood by tools/lib/config.js. Mirrors the
// documented defaults so `luau-contract scan` works immediately after init.
function defaultConfig() {
	return {
		include: ["src/**/*.lua", "src/**/*.luau"],
		exclude: [],
		failOn: "error",
		exact: true,
		contractModules: ["src/**/*.contract.lua"],
		report: {
			formats: ["text"],
		},
	};
}

async function runInit(options) {
	const projectRoot = path.resolve(options.out || process.cwd());
	fs.mkdirSync(projectRoot, { recursive: true });

	const created = [];
	const configPath = path.join(projectRoot, "luau-contracts.json");
	if (fs.existsSync(configPath) && !options.force) {
		process.stdout.write(`luau-contracts.json already exists at ${configPath}; leaving it untouched.\n`);
	} else {
		fs.writeFileSync(configPath, `${JSON.stringify(defaultConfig(), null, 2)}\n`);
		created.push(configPath);
	}

	// Reuse the scaffold file-emitting helper for the sample system.
	const sample = scaffoldSystem({
		system: "Example",
		actions: ["Ping"],
		outDir: path.join(projectRoot, "src"),
		sdkRequire: options.sdkRequire || "../../src/Contracts",
		force: options.force,
	});
	created.push(...sample.files);

	process.stdout.write("Created:\n");
	for (const filePath of created) {
		process.stdout.write(`  ${filePath}\n`);
	}

	process.stdout.write(`\nNext steps:
  1. Define real input/output schemas and an actor policy in src/Example.contract.lua.
  2. Run \`npm run scan\` (or \`node tools/luau-contract.js scan\`) to type-check your contracts.
  3. Generate strict remote wrappers: \`node tools/luau-contract.js generate remotes\`.
  4. Bind the remotes to a runtime in src/ExampleRuntime.server.lua.
  5. Flesh out src/Example.test.lua and run your Luau test suite.
`);
	return 0;
}

module.exports = {
	runInit,
};
