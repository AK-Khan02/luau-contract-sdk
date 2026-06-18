"use strict";

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const test = require("node:test");
const { runInit } = require("../lib/cli/initCommand");
const { sanitizeIdentifier, scaffoldSystem } = require("../lib/cli/scaffoldCommand");

const repoRoot = path.resolve(__dirname, "../..");
const cliPath = path.join(repoRoot, "tools/luau-contract.js");

function makeOsTempDir() {
	return fs.mkdtempSync(path.join(os.tmpdir(), "luau-contract-scaffold-"));
}

// Repo-local, non-dot-prefixed temp dir so exact-mode scans produce a valid
// "./..." Luau require path for the scaffolded contract module.
function makeRepoTempDir() {
	const directory = path.join(repoRoot, `tmp-scaffold-${process.pid}-${Date.now()}`);
	fs.rmSync(directory, { force: true, recursive: true });
	fs.mkdirSync(directory, { recursive: true });
	return directory;
}

test("scaffold sanitizer strips unsafe identifier characters", () => {
	assert.equal(sanitizeIdentifier("Grant Item!", "fallback"), "GrantItem");
	assert.equal(sanitizeIdentifier("", "fallback"), "fallback");
	assert.equal(sanitizeIdentifier("9Lives", "fallback"), "fallback");
	assert.equal(sanitizeIdentifier("Valid_Name", "fallback"), "Valid_Name");
});

test("scaffoldSystem creates contract, runtime, and test files at expected paths", () => {
	const outDir = makeOsTempDir();
	try {
		const result = scaffoldSystem({
			system: "Inventory",
			actions: ["GrantItem", "DropItem"],
			outDir,
		});

		const contractPath = path.join(outDir, "Inventory.contract.lua");
		const runtimePath = path.join(outDir, "InventoryRuntime.server.lua");
		const testPath = path.join(outDir, "Inventory.test.lua");

		assert.deepEqual(result.files, [contractPath, runtimePath, testPath]);
		assert.equal(fs.existsSync(contractPath), true);
		assert.equal(fs.existsSync(runtimePath), true);
		assert.equal(fs.existsSync(testPath), true);
	} finally {
		fs.rmSync(outDir, { force: true, recursive: true });
	}
});

test("scaffolded contract declares the system and one remote per action", () => {
	const outDir = makeOsTempDir();
	try {
		scaffoldSystem({
			system: "Inventory",
			actions: ["GrantItem", "DropItem"],
			outDir,
		});
		const contract = fs.readFileSync(path.join(outDir, "Inventory.contract.lua"), "utf8");

		assert.match(contract, /Contracts\.system\("Inventory"\)/);
		assert.match(contract, /:action\("GrantItem", \{/);
		assert.match(contract, /:action\("DropItem", \{/);
		// One remote binding per action (name = "<Action>" inside the remote block).
		assert.equal((contract.match(/name = "GrantItem"/g) || []).length, 1);
		assert.equal((contract.match(/name = "DropItem"/g) || []).length, 1);
		assert.match(contract, /rateLimit = \{/);
	} finally {
		fs.rmSync(outDir, { force: true, recursive: true });
	}
});

test("scaffolded runtime implements each action with a transactional scope:write", () => {
	const outDir = makeOsTempDir();
	try {
		scaffoldSystem({
			system: "Inventory",
			actions: ["GrantItem", "DropItem"],
			outDir,
		});
		const runtime = fs.readFileSync(path.join(outDir, "InventoryRuntime.server.lua"), "utf8");

		assert.match(runtime, /Contracts\.runtime\(contract\)/);
		assert.match(runtime, /runtime:implement\("GrantItem", function\(scope/);
		assert.match(runtime, /runtime:implement\("DropItem", function\(scope/);
		// Transactional effect example: scope:write with a commit/rollback table.
		assert.match(runtime, /scope:write\("Player\.Path", \{/);
		assert.match(runtime, /commit = function\(context\)/);
		assert.match(runtime, /rollback = function\(context\)/);
		// The eager, non-transactional escape hatch is documented as a comment.
		assert.match(runtime, /scope:writeEager\(path, valueOrWriter\) runs immediately/);
		assert.match(runtime, /runtime:bindRemotes\(remotes\)/);
	} finally {
		fs.rmSync(outDir, { force: true, recursive: true });
	}
});

test("scaffolded test exercises each action through the RemoteHarness", () => {
	const outDir = makeOsTempDir();
	try {
		scaffoldSystem({
			system: "Inventory",
			actions: ["GrantItem", "DropItem"],
			outDir,
		});
		const suite = fs.readFileSync(path.join(outDir, "Inventory.test.lua"), "utf8");

		assert.match(suite, /Contracts\.Test\.remoteHarness\(contract\)/);
		assert.match(suite, /harness:call\("GrantItem", player, \{/);
		assert.match(suite, /harness:call\("DropItem", player, \{/);
		assert.match(suite, /test:section\("Inventory"\)/);
	} finally {
		fs.rmSync(outDir, { force: true, recursive: true });
	}
});

test("scaffold function remotes declare a response schema", () => {
	const outDir = makeOsTempDir();
	try {
		scaffoldSystem({
			system: "Trade",
			actions: ["Offer"],
			outDir,
			remoteKind: "function",
		});
		const contract = fs.readFileSync(path.join(outDir, "Trade.contract.lua"), "utf8");
		assert.match(contract, /response = Contracts\.object\(/);
	} finally {
		fs.rmSync(outDir, { force: true, recursive: true });
	}
});

test("scaffold honors a custom SDK require path", () => {
	const outDir = makeOsTempDir();
	try {
		scaffoldSystem({
			system: "Inventory",
			actions: ["GrantItem"],
			outDir,
			sdkRequire: "@pkg/Contracts",
		});
		const contract = fs.readFileSync(path.join(outDir, "Inventory.contract.lua"), "utf8");
		assert.match(contract, /local Contracts = require\("@pkg\/Contracts"\)/);
	} finally {
		fs.rmSync(outDir, { force: true, recursive: true });
	}
});

test("scaffold refuses to overwrite existing files without --force and succeeds with it", () => {
	const outDir = makeOsTempDir();
	try {
		scaffoldSystem({ system: "Inventory", actions: ["GrantItem"], outDir });

		assert.throws(() => {
			scaffoldSystem({ system: "Inventory", actions: ["GrantItem"], outDir });
		}, /refusing to overwrite/);

		assert.doesNotThrow(() => {
			scaffoldSystem({ system: "Inventory", actions: ["GrantItem"], outDir, force: true });
		});
	} finally {
		fs.rmSync(outDir, { force: true, recursive: true });
	}
});

test("scaffold rejects missing system and action inputs", () => {
	const outDir = makeOsTempDir();
	try {
		assert.throws(() => {
			scaffoldSystem({ system: "", actions: ["GrantItem"], outDir });
		}, /requires --system/);
		assert.throws(() => {
			scaffoldSystem({ system: "Inventory", actions: [], outDir });
		}, /requires --actions/);
	} finally {
		fs.rmSync(outDir, { force: true, recursive: true });
	}
});

test("scaffold routes test files to a separate tests-out directory", () => {
	const outDir = makeOsTempDir();
	const testsDir = makeOsTempDir();
	try {
		const result = scaffoldSystem({
			system: "Inventory",
			actions: ["GrantItem"],
			outDir,
			testsOutDir: testsDir,
		});
		assert.equal(result.contractPath, path.join(outDir, "Inventory.contract.lua"));
		assert.equal(result.testPath, path.join(testsDir, "Inventory.test.lua"));
		assert.equal(fs.existsSync(path.join(testsDir, "Inventory.test.lua")), true);
		assert.equal(fs.existsSync(path.join(outDir, "Inventory.test.lua")), false);
	} finally {
		fs.rmSync(outDir, { force: true, recursive: true });
		fs.rmSync(testsDir, { force: true, recursive: true });
	}
});

test("init creates luau-contracts.json and a sample system", async () => {
	const projectRoot = makeOsTempDir();
	const originalWrite = process.stdout.write;
	process.stdout.write = () => true;
	try {
		const exitCode = await runInit({ out: projectRoot });
		assert.equal(exitCode, 0);

		const configPath = path.join(projectRoot, "luau-contracts.json");
		assert.equal(fs.existsSync(configPath), true);
		const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
		// Only real config keys (see tools/lib/config.js).
		assert.deepEqual(config.contractModules, ["src/**/*.contract.lua"]);
		assert.equal(config.exact, true);
		assert.equal(config.failOn, "error");

		const contract = fs.readFileSync(path.join(projectRoot, "src", "Example.contract.lua"), "utf8");
		assert.match(contract, /Contracts\.system\("Example"\)/);
		assert.match(contract, /:action\("Ping", \{/);
		assert.equal(fs.existsSync(path.join(projectRoot, "src", "ExampleRuntime.server.lua")), true);
		assert.equal(fs.existsSync(path.join(projectRoot, "src", "Example.test.lua")), true);
	} finally {
		process.stdout.write = originalWrite;
		fs.rmSync(projectRoot, { force: true, recursive: true });
	}
});

test("init leaves an existing config untouched without --force", async () => {
	const projectRoot = makeOsTempDir();
	const configPath = path.join(projectRoot, "luau-contracts.json");
	fs.writeFileSync(configPath, JSON.stringify({ include: ["custom/**/*.lua"] }, null, 2));
	const originalWrite = process.stdout.write;
	process.stdout.write = () => true;
	try {
		await runInit({ out: projectRoot });
		const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
		assert.deepEqual(config.include, ["custom/**/*.lua"]);
	} finally {
		process.stdout.write = originalWrite;
		fs.rmSync(projectRoot, { force: true, recursive: true });
	}
});

test("scan accepts the scaffolded contract as a loadable exact module", () => {
	const projectRoot = makeRepoTempDir();
	try {
		// Scaffold under the repo so the relative SDK require resolves from src/Contracts.
		scaffoldSystem({
			system: "Inventory",
			actions: ["GrantItem", "DropItem"],
			outDir: path.join(projectRoot, "src"),
			sdkRequire: "../../src/Contracts",
		});

		const run = spawnSync(process.execPath, [
			cliPath,
			"scan",
			"--root",
			projectRoot,
			"--exact",
			"--contract-module",
			"src/Inventory.contract.lua",
			"--format",
			"json",
			"--out",
			path.join(projectRoot, "report.json"),
		], {
			cwd: repoRoot,
			encoding: "utf8",
		});

		assert.equal(run.status, 0, run.stderr || run.stdout);
		const report = JSON.parse(fs.readFileSync(path.join(projectRoot, "report.json"), "utf8"));
		assert.equal(report.exact.errors.length, 0, JSON.stringify(report.exact.errors));
		assert.equal(report.contracts.some((contract) => contract.name === "Inventory"), true);
		assert.equal(report.policy.ok, true);
	} finally {
		fs.rmSync(projectRoot, { force: true, recursive: true });
	}
});

test("cli scaffold subcommand writes files and prints next steps", () => {
	const projectRoot = makeRepoTempDir();
	try {
		const run = spawnSync(process.execPath, [
			cliPath,
			"scaffold",
			"--system",
			"Inventory",
			"--actions",
			"GrantItem,DropItem",
			"--out",
			path.join(projectRoot, "src"),
			"--sdk-require",
			"../../src/Contracts",
		], {
			cwd: repoRoot,
			encoding: "utf8",
		});

		assert.equal(run.status, 0, run.stderr || run.stdout);
		assert.match(run.stdout, /Created:/);
		assert.match(run.stdout, /Next steps:/);
		assert.equal(fs.existsSync(path.join(projectRoot, "src", "Inventory.contract.lua")), true);

		// Re-running without --force must refuse and exit non-zero.
		const rerun = spawnSync(process.execPath, [
			cliPath,
			"scaffold",
			"--system",
			"Inventory",
			"--actions",
			"GrantItem",
			"--out",
			path.join(projectRoot, "src"),
			"--sdk-require",
			"../../src/Contracts",
		], {
			cwd: repoRoot,
			encoding: "utf8",
		});
		assert.notEqual(rerun.status, 0);
		assert.match(rerun.stderr, /refusing to overwrite/);
	} finally {
		fs.rmSync(projectRoot, { force: true, recursive: true });
	}
});
