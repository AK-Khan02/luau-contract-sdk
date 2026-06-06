"use strict";

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const test = require("node:test");
const { globToRegExp } = require("../lib/glob");
const { attackCaseSummary, generateRemoteAttackTestFiles } = require("../lib/remoteAttackCaseGenerator");
const { emitType } = require("../lib/luauTypeEmitter");
const { discoverScripts } = require("../lib/projectDiscovery");
const { renderReport } = require("../lib/reportWriters");

const repoRoot = path.resolve(__dirname, "../..");
const cliPath = path.join(repoRoot, "tools/luau-contract.js");

function makeTempProject() {
	const projectRoot = fs.mkdtempSync(path.join(os.tmpdir(), "luau-contract-test-"));
	fs.mkdirSync(path.join(projectRoot, "src"), { recursive: true });
	fs.writeFileSync(path.join(projectRoot, "default.project.json"), JSON.stringify({
		name: "TestProject",
		tree: {
			$className: "DataModel",
			ServerScriptService: {
				$path: "src",
			},
		},
	}, null, 2));
	return projectRoot;
}

function makeRepoTempDir(name) {
	const directory = path.join(repoRoot, `.tmp-${name}-${process.pid}-${Date.now()}`);
	fs.rmSync(directory, { force: true, recursive: true });
	fs.mkdirSync(directory, { recursive: true });
	return directory;
}

test("glob matcher supports recursive Luau patterns", () => {
	const matcher = globToRegExp("src/**/*.lua");
	assert.equal(matcher.test("src/Inventory.lua"), true);
	assert.equal(matcher.test("src/server/Inventory.lua"), true);
	assert.equal(matcher.test("plugin/Inventory.lua"), false);
});

test("project discovery maps Rojo paths and infers script classes", () => {
	const projectRoot = makeTempProject();
	fs.writeFileSync(path.join(projectRoot, "src", "Match.server.lua"), "print('match')");

	const scripts = discoverScripts(projectRoot, {
		include: ["src/**/*.lua"],
		exclude: [],
	});

	assert.equal(scripts.length, 1);
	assert.equal(scripts[0].path, "ServerScriptService.Match");
	assert.equal(scripts[0].className, "Script");
});

test("report writers render JSON and SARIF", () => {
	const report = {
		summary: { scriptCount: 1, systemCount: 0, contractCount: 0, scannerFindingCount: 1 },
		policy: { ok: false, reasons: ["1 new finding"] },
		scanner: {
			rules: {
				"raw-remote-handler": {
					id: "raw-remote-handler",
					title: "Raw remote server handler",
					severity: "error",
				},
			},
			findings: [
				{
					ruleId: "raw-remote-handler",
					severity: "error",
					path: "ServerScriptService.Match",
					line: 1,
					column: 1,
					message: "unsafe",
					snippet: "Remote.OnServerEvent:Connect",
				},
			],
		},
		exact: { errors: [] },
	};

	assert.match(renderReport(report, "json"), /"raw-remote-handler"/);
	assert.match(renderReport(report, "sarif"), /"version": "2.1.0"/);
});

test("report writers render generated coverage in markdown", () => {
	const report = {
		summary: { scriptCount: 0, systemCount: 0, contractCount: 1, scannerFindingCount: 0 },
		policy: { ok: true },
		scanner: { findings: [] },
		contracts: [],
		generated: {
			summary: {
				expectedFileCount: 2,
				presentFileCount: 1,
				missingFileCount: 1,
				staleFileCount: 0,
				attackCaseCount: 4,
			},
			files: [
				{ kind: "remote-wrapper", path: "src/generated/InventoryClient.luau", exists: true, stale: false },
				{ kind: "remote-attack-test", path: "tests/generated/run.luau", exists: false, stale: false },
			],
			attackCases: [
				{
					contract: "InventoryService",
					remote: "EquipItem",
					caseCount: 4,
					cases: [{ kind: "payload", name: "missing ItemId" }],
				},
			],
		},
	};

	const markdown = renderReport(report, "markdown");
	assert.match(markdown, /Generated Coverage/);
	assert.match(markdown, /missing/);
	assert.match(markdown, /payload:missing ItemId/);
});

test("luau type emitter maps contract schemas to strict aliases", () => {
	const emitted = emitType({
		kind: "object",
		allowExtra: false,
		shape: {
			Action: {
				kind: "oneOf",
				values: ["Buy", "Sell"],
			},
			ItemId: {
				kind: "string",
			},
			Mode: {
				kind: "optional",
				schema: {
					kind: "oneOf",
					values: ["solo", "team"],
				},
			},
			Revision: {
				kind: "optional",
				schema: {
					kind: "integer",
				},
			},
		},
	});

	assert.match(emitted, /Action: "Buy" \| "Sell"/);
	assert.match(emitted, /ItemId: string/);
	assert.match(emitted, /Mode: \("solo" \| "team"\)\?/);
	assert.match(emitted, /Revision: number\?/);
});

test("cli scan fails on new raw remote and passes with baseline", () => {
	const projectRoot = makeTempProject();
	const reportPath = path.join(projectRoot, "report.json");
	fs.writeFileSync(path.join(projectRoot, "src", "Unsafe.server.lua"), `
DeployRequest.OnServerEvent:Connect(function(player, payload)
\tprint(payload)
end)
`);

	const firstRun = spawnSync(process.execPath, [
		cliPath,
		"scan",
		"--root",
		projectRoot,
		"--format",
		"json",
		"--out",
		reportPath,
		"--fail-on",
		"error",
	], {
		cwd: repoRoot,
		encoding: "utf8",
	});

	assert.equal(firstRun.status, 1, firstRun.stderr || firstRun.stdout);
	const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
	assert.equal(report.summary.scannerFindingCount, 1);
	assert.equal(report.scanner.findings[0].path, "ServerScriptService.Unsafe");

	const secondRun = spawnSync(process.execPath, [
		cliPath,
		"scan",
		"--root",
		projectRoot,
		"--format",
		"json",
		"--out",
		path.join(projectRoot, "second-report.json"),
		"--baseline",
		reportPath,
		"--fail-on",
		"error",
	], {
		cwd: repoRoot,
		encoding: "utf8",
	});

	assert.equal(secondRun.status, 0, secondRun.stderr || secondRun.stdout);
});

test("cli migration scan, suggest, and patch wrap raw remote handlers", () => {
	const projectRoot = makeTempProject();
	const scriptPath = path.join(projectRoot, "src", "Unsafe.server.lua");
	const reportPath = path.join(projectRoot, "migration.json");
	fs.writeFileSync(scriptPath, `--!strict
local GrantItem = {}

GrantItem.OnServerEvent:Connect(function(player, payload)
\tif type(payload.ItemId) == "string" and type(payload.Amount) == "number" then
\t\tprint(player, payload.ItemId, payload.Amount)
\tend
end)
`);

	const scan = spawnSync(process.execPath, [
		cliPath,
		"migrate",
		"scan",
		"--root",
		projectRoot,
		"--format",
		"json",
		"--out",
		reportPath,
	], {
		cwd: repoRoot,
		encoding: "utf8",
	});
	assert.equal(scan.status, 0, scan.stderr || scan.stdout);
	const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
	assert.equal(report.summary.findingCount, 1);
	assert.equal(report.findings[0].remoteName, "GrantItem");
	assert.deepEqual(report.findings[0].inferredFields.map((field) => field.name), ["ItemId", "Amount"]);
	assert.equal(report.findings[0].patchable, true);

	const suggest = spawnSync(process.execPath, [
		cliPath,
		"migrate",
		"suggest",
		"--root",
		projectRoot,
		"--format",
		"markdown",
	], {
		cwd: repoRoot,
		encoding: "utf8",
	});
	assert.equal(suggest.status, 0, suggest.stderr || suggest.stdout);
	assert.match(suggest.stdout, /Contracts\.guardRemote/);
	assert.match(suggest.stdout, /ItemId = Contracts\.stringId\(\)/);

	const patch = spawnSync(process.execPath, [
		cliPath,
		"migrate",
		"patch",
		"--root",
		projectRoot,
		"--contracts-require",
		"../../src/Contracts",
		"--write",
		"--format",
		"json",
		"--out",
		path.join(projectRoot, "patch.json"),
	], {
		cwd: repoRoot,
		encoding: "utf8",
	});
	assert.equal(patch.status, 0, patch.stderr || patch.stdout);
	const patched = fs.readFileSync(scriptPath, "utf8");
	assert.match(patched, /local Contracts = require\("\.\.\/\.\.\/src\/Contracts"\)/);
	assert.match(patched, /Contracts\.guardRemote\(GrantItem/);
	assert.match(patched, /allowExtra = true/);
	assert.match(patched, /function\(player, payload\)/);
});

test("cli migration patch can insert raw Roblox require expressions", () => {
	const projectRoot = makeTempProject();
	const scriptPath = path.join(projectRoot, "src", "RobloxRequire.server.lua");
	fs.writeFileSync(scriptPath, `
local Remote = {}

Remote.OnServerEvent:Connect(function(player, payload)
\tprint(player, payload)
end)
`);

	const patch = spawnSync(process.execPath, [
		cliPath,
		"migrate",
		"patch",
		"--root",
		projectRoot,
		"--contracts-require",
		"lua:game:GetService(\"ReplicatedStorage\").LuauContractSDK.Contracts",
		"--write",
	], {
		cwd: repoRoot,
		encoding: "utf8",
	});
	assert.equal(patch.status, 0, patch.stderr || patch.stdout);
	const patched = fs.readFileSync(scriptPath, "utf8");
	assert.match(patched, /local Contracts = require\(game:GetService\("ReplicatedStorage"\)\.LuauContractSDK\.Contracts\)/);
});

test("cli migration patches simple remote functions and drafts contracts", () => {
	const projectRoot = makeTempProject();
	const scriptPath = path.join(projectRoot, "src", "UnsafeFunction.server.lua");
	const contractPath = path.join(projectRoot, "src", "Migrated.contract.lua");
	fs.writeFileSync(scriptPath, `--!strict
local GetItem = {}

GetItem.OnServerInvoke = function(player, payload)
\tif type(payload.ItemId) == "string" then
\t\treturn { ok = true }
\tend
\treturn { ok = false }
end
`);

	const contract = spawnSync(process.execPath, [
		cliPath,
		"migrate",
		"contract",
		"--root",
		projectRoot,
		"--contracts-require",
		"../../src/Contracts",
		"--system-name",
		"MigratedInventory",
		"--out",
		contractPath,
	], {
		cwd: repoRoot,
		encoding: "utf8",
	});
	assert.equal(contract.status, 0, contract.stderr || contract.stdout);
	const draft = fs.readFileSync(contractPath, "utf8");
	assert.match(draft, /Contracts\.system\("MigratedInventory"\)/);
	assert.match(draft, /:remote\("GetItem", {/);
	assert.match(draft, /ItemId = Contracts\.stringId\(\)/);
	assert.match(draft, /output = Contracts\.any\(\)/);

	const patch = spawnSync(process.execPath, [
		cliPath,
		"migrate",
		"patch",
		"--root",
		projectRoot,
		"--contracts-require",
		"../../src/Contracts",
		"--write",
	], {
		cwd: repoRoot,
		encoding: "utf8",
	});
	assert.equal(patch.status, 0, patch.stderr || patch.stdout);
	const patched = fs.readFileSync(scriptPath, "utf8");
	assert.match(patched, /Contracts\.guardRemote\(GetItem/);
	assert.match(patched, /kind = "function"/);
	assert.match(patched, /end\)\s*$/);
});

test("cli exact mode loads configured contract modules", () => {
	const reportPath = path.join(os.tmpdir(), `luau-contract-exact-${process.pid}.json`);
	const run = spawnSync(process.execPath, [
		cliPath,
		"scan",
		"--root",
		repoRoot,
		"--exact",
		"--contract-module",
		"examples/inventory.contract.lua",
		"--format",
		"json",
		"--out",
		reportPath,
	], {
		cwd: repoRoot,
		encoding: "utf8",
	});

	assert.equal(run.status, 0, run.stderr || run.stdout);
	const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
	assert.equal(report.contracts.some((contract) => contract.name === "InventoryService"), true);
	fs.rmSync(reportPath, { force: true });
});

test("cli exact mode loads contract modules outside sdk root", () => {
	const projectRoot = makeTempProject();
	const reportPath = path.join(projectRoot, "exact-report.json");
	fs.writeFileSync(path.join(projectRoot, "src", "External.contract.lua"), `
return {
\tdescribe = function()
\t\treturn {
\t\t\tformatVersion = 1,
\t\t\tname = "ExternalInventory",
\t\t\tactions = {},
\t\t\tremotes = {},
\t\t\tlifecycles = {},
\t\t\tpermissions = {
\t\t\t\tstrict = true,
\t\t\t},
\t\t}
\tend,
}
`);

	const run = spawnSync(process.execPath, [
		cliPath,
		"scan",
		"--root",
		projectRoot,
		"--exact",
		"--contract-module",
		"src/*.contract.lua",
		"--format",
		"json",
		"--out",
		reportPath,
	], {
		cwd: repoRoot,
		encoding: "utf8",
	});

	assert.equal(run.status, 0, run.stderr || run.stdout);
	const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
	assert.equal(report.contracts.some((contract) => contract.name === "ExternalInventory"), true);
	assert.equal(report.exact.errors.length, 0);
});

test("cli generates strict remote wrappers and verifies check mode", () => {
	const outDir = makeRepoTempDir("generated-remotes");
	try {
		const run = spawnSync(process.execPath, [
			cliPath,
			"generate",
			"remotes",
			"--root",
			repoRoot,
			"--contract-module",
			"examples/inventory.contract.lua",
			"--out",
			outDir,
		], {
			cwd: repoRoot,
			encoding: "utf8",
		});

		assert.equal(run.status, 0, run.stderr || run.stdout);
		const clientPath = path.join(outDir, "InventoryServiceClient.luau");
		const serverPath = path.join(outDir, "InventoryServiceServer.luau");
		const manifestPath = path.join(outDir, "InventoryServiceManifest.luau");
		const client = fs.readFileSync(clientPath, "utf8");
		const server = fs.readFileSync(serverPath, "utf8");
		const manifest = fs.readFileSync(manifestPath, "utf8");
		assert.match(client, /--!strict/);
		assert.match(client, /export type InventoryServiceEquipItemPayload/);
		assert.match(client, /function Client\.EquipItem/);
		assert.match(server, /function Server\.guard/);
		assert.match(server, /function Server\.bind\(runtime: any, remotes: \{\[string\]: any\}, handlersOrOptions: any\?, options: any\?\)/);
		assert.match(manifest, /attackCaseCount/);

		const check = spawnSync(process.execPath, [
			cliPath,
			"generate",
			"remotes",
			"--root",
			repoRoot,
			"--contract-module",
			"examples/inventory.contract.lua",
			"--out",
			outDir,
			"--check",
		], {
			cwd: repoRoot,
			encoding: "utf8",
		});
		assert.equal(check.status, 0, check.stderr || check.stdout);

		fs.appendFileSync(clientPath, "-- stale\n");
		const stale = spawnSync(process.execPath, [
			cliPath,
			"generate",
			"remotes",
			"--root",
			repoRoot,
			"--contract-module",
			"examples/inventory.contract.lua",
			"--out",
			outDir,
			"--check",
		], {
			cwd: repoRoot,
			encoding: "utf8",
		});
		assert.equal(stale.status, 2);
		assert.match(stale.stderr, /generated files are not up to date/);
	} finally {
		fs.rmSync(outDir, { force: true, recursive: true });
	}
});

test("cli verifies complete remote workflow", () => {
	const outDir = makeRepoTempDir("verify-remotes");
	const remotesDir = path.join(outDir, "remotes");
	const testsDir = path.join(outDir, "tests");
	const reportPath = path.join(outDir, "verify.json");
	try {
		const generate = spawnSync(process.execPath, [
			cliPath,
			"generate",
			"all",
			"--root",
			repoRoot,
			"--contract-module",
			"examples/inventory.contract.lua",
			"--out",
			remotesDir,
			"--tests-out",
			testsDir,
		], {
			cwd: repoRoot,
			encoding: "utf8",
		});
		assert.equal(generate.status, 0, generate.stderr || generate.stdout);

		const verify = spawnSync(process.execPath, [
			cliPath,
			"verify",
			"remotes",
			"--root",
			repoRoot,
			"--contract-module",
			"examples/inventory.contract.lua",
			"--generated-remotes",
			remotesDir,
			"--generated-tests",
			testsDir,
			"--format",
			"json",
			"--out",
			reportPath,
		], {
			cwd: repoRoot,
			encoding: "utf8",
		});
		assert.equal(verify.status, 0, verify.stderr || verify.stdout);
		const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
		assert.equal(report.policy.ok, true);
		assert.equal(report.verify.attackTestRun.ok, true);
		assert.equal(report.generated.summary.staleFileCount, 0);
		assert.equal(report.remoteSecurity.remoteCount, 1);

		fs.appendFileSync(path.join(remotesDir, "InventoryServiceManifest.luau"), "-- stale\n");
		const stale = spawnSync(process.execPath, [
			cliPath,
			"verify",
			"remotes",
			"--root",
			repoRoot,
			"--contract-module",
			"examples/inventory.contract.lua",
			"--generated-remotes",
			remotesDir,
			"--generated-tests",
			testsDir,
			"--format",
			"json",
			"--out",
			path.join(outDir, "stale.json"),
		], {
			cwd: repoRoot,
			encoding: "utf8",
		});
		assert.equal(stale.status, 1);
		const staleReport = JSON.parse(fs.readFileSync(path.join(outDir, "stale.json"), "utf8"));
		assert.equal(staleReport.generated.summary.staleFileCount > 0, true);
		assert.equal(staleReport.verify.attackTestRun.skipped, true);
	} finally {
		fs.rmSync(outDir, { force: true, recursive: true });
	}
});

test("cli generates runnable remote attack tests", () => {
	const outDir = makeRepoTempDir("generated-attacks");
	try {
		const generate = spawnSync(process.execPath, [
			cliPath,
			"generate",
			"tests",
			"--root",
			repoRoot,
			"--contract-module",
			"examples/inventory.contract.lua",
			"--out",
			outDir,
		], {
			cwd: repoRoot,
			encoding: "utf8",
		});

		assert.equal(generate.status, 0, generate.stderr || generate.stdout);
		const suite = fs.readFileSync(path.join(outDir, "InventoryServiceRemoteAttackTests.luau"), "utf8");
		assert.match(suite, /remote-attack-tests/);
		assert.match(suite, /missing ItemId/);
		assert.match(suite, /pathological ItemId/);
		assert.match(suite, /missing actor/);
		assert.match(suite, /bad response shape/);

		const run = spawnSync("luau", [path.join(outDir, "run.luau")], {
			cwd: repoRoot,
			encoding: "utf8",
		});
		assert.equal(run.status, 0, run.stderr || run.stdout);
		assert.match(run.stdout, /generated remote attack checks passed/);
	} finally {
		fs.rmSync(outDir, { force: true, recursive: true });
	}
});

test("remote attack generator uses named actor attack config", () => {
	const outDir = makeRepoTempDir("actor-attacks");
	try {
		const artifacts = {
			contracts: [
				{
					name: "AdminService",
					path: "src/admin.contract.lua",
					actions: {
						GrantItem: {
							output: {
								kind: "object",
								allowExtra: false,
								shape: {
									ok: { kind: "boolean" },
								},
							},
							policy: {},
						},
					},
					remotes: [
						{
							remoteName: "GrantItem",
							actionName: "GrantItem",
							payload: {
								kind: "object",
								allowExtra: false,
								shape: {
									ItemId: { kind: "string" },
								},
							},
							actor: "admin",
							lifecycle: {},
							rateLimit: null,
							response: null,
						},
					],
				},
			],
		};
		const attackConfig = {
			actors: {
				admin: {
					invalid: {
						Name: "Guest",
						UserId: 2,
						IsAdmin: false,
					},
				},
			},
		};

		const summary = attackCaseSummary(artifacts, { attackConfig });
		assert.equal(summary.caseCount > 0, true);
		assert.equal(summary.remotes[0].cases.some((testCase) => testCase.name === "unauthorized admin"), true);

		const files = generateRemoteAttackTestFiles(artifacts, {
			outDir,
			projectRoot: repoRoot,
			sdkRoot: repoRoot,
			attackConfig,
		});
		const suite = files.find((file) => file.path.endsWith("AdminServiceRemoteAttackTests.luau")).contents;
		assert.match(suite, /unauthorized admin/);
		assert.match(suite, /IsAdmin = false/);
	} finally {
		fs.rmSync(outDir, { force: true, recursive: true });
	}
});

test("cli scan reports generated wrapper and attack-test coverage", () => {
	const outDir = makeRepoTempDir("coverage");
	const remotesDir = path.join(outDir, "remotes");
	const testsDir = path.join(outDir, "tests");
	try {
		const generate = spawnSync(process.execPath, [
			cliPath,
			"generate",
			"all",
			"--root",
			repoRoot,
			"--contract-module",
			"examples/inventory.contract.lua",
			"--out",
			remotesDir,
			"--tests-out",
			testsDir,
		], {
			cwd: repoRoot,
			encoding: "utf8",
		});
		assert.equal(generate.status, 0, generate.stderr || generate.stdout);

		const reportPath = path.join(outDir, "coverage.json");
		const scan = spawnSync(process.execPath, [
			cliPath,
			"scan",
			"--root",
			repoRoot,
			"--exact",
			"--contract-module",
			"examples/inventory.contract.lua",
			"--generated-remotes",
			remotesDir,
			"--generated-tests",
			testsDir,
			"--format",
			"json",
			"--out",
			reportPath,
		], {
			cwd: repoRoot,
			encoding: "utf8",
		});
		assert.equal(scan.status, 0, scan.stderr || scan.stdout);
		const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
		assert.equal(report.generated.summary.missingFileCount, 0);
		assert.equal(report.generated.summary.staleFileCount, 0);
		assert.equal(report.generated.summary.attackCaseCount > 0, true);

		fs.appendFileSync(path.join(remotesDir, "InventoryServiceClient.luau"), "-- stale\n");
		const stalePath = path.join(outDir, "stale.json");
		const stale = spawnSync(process.execPath, [
			cliPath,
			"scan",
			"--root",
			repoRoot,
			"--exact",
			"--contract-module",
			"examples/inventory.contract.lua",
			"--generated-remotes",
			remotesDir,
			"--generated-tests",
			testsDir,
			"--format",
			"json",
			"--out",
			stalePath,
		], {
			cwd: repoRoot,
			encoding: "utf8",
		});
		assert.equal(stale.status, 0, stale.stderr || stale.stdout);
		const staleReport = JSON.parse(fs.readFileSync(stalePath, "utf8"));
		assert.equal(staleReport.generated.summary.staleFileCount > 0, true);
	} finally {
		fs.rmSync(outDir, { force: true, recursive: true });
	}
});
