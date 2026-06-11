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
	const finding = report.scanner.findings[0];
	assert.equal(finding.path, "ServerScriptService.Unsafe");
	assert.equal(finding.ruleId, "raw-remote-handler");
	assert.equal(finding.severity, "error");
	assert.equal(typeof finding.line, "number");
	assert.equal(finding.line > 0, true);
	assert.match(finding.message, /RemoteGuard\.connect/);
	assert.match(finding.snippet, /OnServerEvent/);
	assert.equal(report.policy.exitCode, 1);

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
		assert.match(suite, /never interleaves in-flight duplicates/);
		assert.match(suite, /records ActionBusy for in-flight duplicate/);
		assert.match(suite, /times out stuck handler/);
		assert.match(suite, /blocks commits after timeout/);

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

test("cli rejects unknown commands with a non-zero exit", () => {
	const run = spawnSync(process.execPath, [cliPath, "frobnicate"], {
		cwd: repoRoot,
		encoding: "utf8",
	});
	assert.notEqual(run.status, 0);
	assert.match(run.stderr || run.stdout, /Unknown command: frobnicate/);
});

test("cli generate fails when the contract module glob matches nothing", () => {
	const run = spawnSync(process.execPath, [
		cliPath,
		"generate",
		"tests",
		"--root",
		repoRoot,
		"--contract-module",
		"definitely/missing/*.contract.lua",
		"--out",
		path.join(os.tmpdir(), "luau-contract-missing-out"),
	], {
		cwd: repoRoot,
		encoding: "utf8",
	});
	assert.notEqual(run.status, 0);
	assert.match(run.stderr || run.stdout, /no contract modules matched: definitely\/missing/);
});

test("cli generate fails on contracts that do not load", () => {
	const projectRoot = makeTempProject();
	fs.writeFileSync(path.join(projectRoot, "src", "broken.contract.lua"), "local x = (\n");

	const run = spawnSync(process.execPath, [
		cliPath,
		"generate",
		"tests",
		"--root",
		projectRoot,
		"--contract-module",
		"src/broken.contract.lua",
		"--out",
		path.join(projectRoot, "generated"),
	], {
		cwd: repoRoot,
		encoding: "utf8",
	});
	assert.notEqual(run.status, 0);
	assert.match(run.stderr || run.stdout, /cannot generate from contracts with exact load errors/);
	assert.match(run.stderr || run.stdout, /broken\.contract/);
});

test("remote attack generator emits async cases for session contracts", () => {
	const outDir = makeRepoTempDir("async-attacks");
	try {
		const artifacts = {
			contracts: [
				{
					name: "MatchService",
					path: "src/match.contract.lua",
					actions: {
						AdvanceRound: {
							input: {
								kind: "object",
								allowExtra: false,
								shape: {
									Revision: { kind: "integer" },
								},
							},
							async: {
								timeoutSeconds: 5,
							},
							policy: {},
						},
					},
					remotes: [
						{
							remoteName: "AdvanceRound",
							actionName: "AdvanceRound",
							payload: {
								kind: "object",
								allowExtra: false,
								shape: {
									Revision: { kind: "integer" },
								},
							},
							lifecycle: {
								session: "match",
								revision: "Revision",
							},
							rateLimit: null,
							response: null,
						},
					],
				},
			],
		};

		const summary = attackCaseSummary(artifacts);
		const caseNames = summary.remotes[0].cases.map((testCase) => testCase.name);
		assert.equal(caseNames.includes("in-flight duplicate"), true);
		assert.equal(caseNames.includes("handler timeout"), true);
		assert.equal(caseNames.includes("stale revision after yield"), true);

		const files = generateRemoteAttackTestFiles(artifacts, {
			outDir,
			projectRoot: repoRoot,
			sdkRoot: repoRoot,
		});
		const suite = files.find((file) => file.path.endsWith("MatchServiceRemoteAttackTests.luau")).contents;
		assert.match(suite, /never interleaves in-flight duplicates/);
		assert.match(suite, /settles every duplicate call/);
		assert.match(suite, /refuses stale revision after yield/);
		assert.match(suite, /lifecycleSession\(\{\}, \{ revision = 1 \}\)/);
		assert.doesNotMatch(suite, /records ActionBusy/);
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

test("studio plugin shell calls real plugin APIs", () => {
	const source = fs.readFileSync(path.join(repoRoot, "plugin/LuauContractStudioPlugin.lua"), "utf8");
	assert.match(source, /plugin:CreateDockWidgetPluginGui\(/);
	assert.doesNotMatch(source, /CreateDockWidgetPluginGuiAsync/);
});

test("relay envelope validation pins the wire shape", () => {
	const { envelopeError } = require("../relay/server");
	assert.equal(envelopeError({ v: 1, batches: [{ entries: [] }] }), null);
	assert.equal(envelopeError({ v: 1 }), null);
	assert.match(envelopeError(null), /object/);
	assert.match(envelopeError([]), /object/);
	assert.match(envelopeError({ batches: "x" }), /array/);
	assert.match(envelopeError({ batches: [null] }), /batch objects/);
});

test("relay ring buffer assigns sequences and reports drops", () => {
	const { createRelayState, ingest, tail } = require("../relay/server");
	const state = createRelayState(2);

	ingest(state, { v: 1, serverId: "srv-1", batches: [{ v: 1, seq: 1, entries: [] }] });
	ingest(state, { v: 1, serverId: "srv-1", batches: [{ v: 1, seq: 2, entries: [] }, { v: 1, seq: 3, entries: [] }] });

	const page = tail(state, 0);
	assert.equal(page.latest, 3);
	assert.equal(page.dropped, 1);
	assert.equal(page.batches.length, 2);
	assert.equal(page.batches[0].serverSeq, 2);

	const caughtUp = tail(state, 3);
	assert.equal(caughtUp.batches.length, 0);
	assert.equal(caughtUp.dropped, 0);
});

function startRelayServer(extraArgs) {
	const { spawn } = require("node:child_process");
	const server = spawn(process.execPath, [
		path.join(repoRoot, "tools/relay/server.js"),
		"--port",
		"0",
		...extraArgs,
	], {
		stdio: ["ignore", "pipe", "pipe"],
	});
	const port = new Promise((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error("relay server did not start")), 5000);
		let buffer = "";
		server.stdout.on("data", (chunk) => {
			buffer += chunk.toString();
			const match = /relay listening on (\d+)/.exec(buffer);
			if (match) {
				clearTimeout(timer);
				resolve(Number(match[1]));
			}
		});
		server.on("error", reject);
	});
	return { server, port };
}

test("relay server end to end with auth and CLI tail", async () => {
	const { server, port } = startRelayServer(["--api-key", "hunter2"]);

	try {
		const base = `http://127.0.0.1:${await port}`;

		const unauthorized = await fetch(`${base}/ingest`, { method: "POST", body: "{}" });
		assert.equal(unauthorized.status, 401);

		const badJson = await fetch(`${base}/ingest`, {
			method: "POST",
			headers: { "x-api-key": "hunter2" },
			body: "{nope",
		});
		assert.equal(badJson.status, 400);

		const envelope = {
			v: 1,
			serverId: "srv-1",
			placeVersion: 7,
			relayDropped: 0,
			batches: [{
				v: 1,
				seq: 1,
				entries: [{
					level: "error",
					system: "InventoryService",
					name: "RemoteRateLimited",
					message: "too fast",
				}],
			}],
		};
		const ingested = await fetch(`${base}/ingest`, {
			method: "POST",
			headers: { "x-api-key": "hunter2", "content-type": "application/json" },
			body: JSON.stringify(envelope),
		});
		assert.equal(ingested.status, 200);
		const ingestBody = await ingested.json();
		assert.equal(ingestBody.accepted, 1);
		assert.equal(ingestBody.latest, 1);

		const health = await (await fetch(`${base}/health`)).json();
		assert.equal(health.ok, true);
		assert.equal(health.count, 1);

		const page = await (await fetch(`${base}/tail?since=0`, {
			headers: { "x-api-key": "hunter2" },
		})).json();
		assert.equal(page.latest, 1);
		assert.equal(page.dropped, 0);
		assert.equal(page.batches[0].batch.entries[0].name, "RemoteRateLimited");

		const tailRun = spawnSync(process.execPath, [
			cliPath,
			"tail",
			"--endpoint",
			base,
			"--api-key",
			"hunter2",
			"--once",
		], { encoding: "utf8" });
		assert.equal(tailRun.status, 0, tailRun.stderr || tailRun.stdout);
		assert.match(tailRun.stdout, /\[error\] srv-1 InventoryService RemoteRateLimited: too fast/);

		const deniedRun = spawnSync(process.execPath, [
			cliPath,
			"tail",
			"--endpoint",
			base,
			"--api-key",
			"wrong",
			"--once",
		], { encoding: "utf8" });
		assert.equal(deniedRun.status, 1);
		assert.match(deniedRun.stderr, /401/);

		const missingEndpoint = spawnSync(process.execPath, [cliPath, "tail", "--once"], { encoding: "utf8" });
		assert.equal(missingEndpoint.status, 2);
		assert.match(missingEndpoint.stderr, /requires --endpoint/);
	} finally {
		server.kill();
	}
});

function serveJson(payload) {
	const http = require("node:http");
	const server = http.createServer((request, response) => {
		const body = JSON.stringify(payload);
		response.writeHead(200, { "content-type": "application/json" });
		response.end(body);
	});
	return new Promise((resolve) => {
		server.listen(0, "127.0.0.1", () => resolve({
			server,
			base: `http://127.0.0.1:${server.address().port}`,
		}));
	});
}

// spawnSync would block the event loop and deadlock against in-process servers.
function runCliAsync(args) {
	const { spawn } = require("node:child_process");
	return new Promise((resolve, reject) => {
		const child = spawn(process.execPath, [cliPath, ...args], {
			stdio: ["ignore", "pipe", "pipe"],
		});
		let stdout = "";
		let stderr = "";
		child.stdout.on("data", (chunk) => {
			stdout += chunk.toString();
		});
		child.stderr.on("data", (chunk) => {
			stderr += chunk.toString();
		});
		child.on("error", reject);
		child.on("close", (status) => resolve({ status, stdout, stderr }));
	});
}

test("cli tail reports malformed relay payloads without crashing", async () => {
	const bogus = await serveJson({ unexpected: true });
	try {
		const run = await runCliAsync(["tail", "--endpoint", bogus.base, "--once"]);
		assert.equal(run.status, 1, run.stderr || run.stdout);
		assert.match(run.stderr, /tail: relay returned an unexpected payload/);
		assert.doesNotMatch(run.stderr, /TypeError/);
	} finally {
		bogus.server.close();
	}

	const junky = await serveJson({
		ok: true,
		latest: 3,
		dropped: 0,
		batches: [
			null,
			{ serverId: "srv-1", batch: null },
			{ serverId: "srv-1", batch: { entries: [null, { level: "error", name: "Survivor", message: "kept" }] } },
		],
	});
	try {
		const run = await runCliAsync(["tail", "--endpoint", junky.base, "--once"]);
		assert.equal(run.status, 0, run.stderr || run.stdout);
		assert.match(run.stdout, /\[error\] srv-1 Survivor: kept/);
	} finally {
		junky.server.close();
	}
});

test("relay server rejects malformed envelopes and stays alive", async () => {
	const { server, port } = startRelayServer([]);

	try {
		const base = `http://127.0.0.1:${await port}`;
		const headers = { "content-type": "application/json" };

		for (const body of ["null", "123", "\"text\"", "true", "[]"]) {
			const response = await fetch(`${base}/ingest`, { method: "POST", headers, body });
			assert.equal(response.status, 400, `expected 400 for envelope ${body}`);
		}

		const badBatchBodies = [
			{ v: 1, serverId: "srv-1", batches: "nope" },
			{ v: 1, serverId: "srv-1", batches: [null] },
			{ v: 1, serverId: "srv-1", batches: [{ v: 1, seq: 1, entries: [] }, 7] },
		];
		for (const envelope of badBatchBodies) {
			const response = await fetch(`${base}/ingest`, {
				method: "POST",
				headers,
				body: JSON.stringify(envelope),
			});
			assert.equal(response.status, 400, `expected 400 for batches ${JSON.stringify(envelope.batches)}`);
		}

		const health = await (await fetch(`${base}/health`)).json();
		assert.equal(health.ok, true);
		assert.equal(health.count, 0);
	} finally {
		server.kill();
	}
});
