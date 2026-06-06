"use strict";

const path = require("node:path");
const {
	artifactFingerprint,
	modulePathForRequire,
	sanitizeIdentifier,
	sanitizeModuleName,
} = require("./contractArtifacts");

function quote(value) {
	return JSON.stringify(String(value));
}

function isIdentifier(value) {
	return /^[A-Za-z_][A-Za-z0-9_]*$/.test(value);
}

function luaKey(key) {
	return isIdentifier(key) ? key : `[${quote(key)}]`;
}

function luaLiteral(value, indent = "") {
	if (value == null) {
		return "nil";
	}
	if (typeof value === "string") {
		return quote(value);
	}
	if (typeof value === "number" || typeof value === "boolean") {
		return String(value);
	}
	if (Array.isArray(value)) {
		return `{ ${value.map((child) => luaLiteral(child, indent)).join(", ")} }`;
	}
	if (typeof value === "object") {
		const entries = Object.entries(value);
		if (entries.length === 0) {
			return "{}";
		}
		const childIndent = `${indent}\t`;
		const lines = ["{"];
		for (const [key, child] of entries) {
			lines.push(`${childIndent}${luaKey(key)} = ${luaLiteral(child, childIndent)},`);
		}
		lines.push(`${indent}}`);
		return lines.join("\n");
	}
	return "nil";
}

function validValue(schema) {
	if (schema == null) return {};
	if (schema.kind === "boolean") return true;
	if (schema.kind === "number" || schema.kind === "integer") return schema.min != null ? schema.min : 1;
	if (schema.kind === "string") return "ValidId";
	if (schema.kind === "oneOf") return (schema.values || [])[0];
	if (schema.kind === "literal") return schema.expected;
	if (schema.kind === "optional") return validValue(schema.schema);
	if (schema.kind === "array") return {};
	if (schema.kind === "vector3") return { X: 0, Y: 1, Z: 0 };
	if (schema.kind === "object") {
		const output = {};
		for (const [key, child] of Object.entries(schema.shape || {})) {
			if (child.kind !== "optional") {
				output[key] = validValue(child);
			}
		}
		return output;
	}
	return {};
}

function invalidValue(schema) {
	if (schema == null) return null;
	if (schema.kind === "boolean") return "not_boolean";
	if (schema.kind === "number" || schema.kind === "integer") return "not_number";
	if (schema.kind === "string") return 12345;
	if (schema.kind === "oneOf") return "__invalid_choice__";
	if (schema.kind === "literal") return "__wrong_literal__";
	if (schema.kind === "array") return "not_array";
	if (schema.kind === "object") return "not_object";
	if (schema.kind === "vector3") return "not_vector3";
	if (schema.kind === "optional") return invalidValue(schema.schema);
	return null;
}

function cloneJson(value) {
	return JSON.parse(JSON.stringify(value));
}

function payloadCases(remote) {
	const cases = [];
	const schema = remote.payload || { kind: "any" };
	if (schema.kind !== "object") {
		cases.push({
			name: "wrong payload type",
			payload: invalidValue(schema),
		});
		return cases;
	}

	const valid = validValue(schema);
	for (const [key, child] of Object.entries(schema.shape || {})) {
		if (child.kind !== "optional") {
			const missing = cloneJson(valid);
			delete missing[key];
			cases.push({
				name: `missing ${key}`,
				payload: missing,
			});
		}

		const wrongType = cloneJson(valid);
		wrongType[key] = invalidValue(child);
		cases.push({
			name: `invalid ${key}`,
			payload: wrongType,
		});
	}

	if (schema.allowExtra !== true) {
		const extra = cloneJson(valid);
		extra.__unexpected = true;
		cases.push({
			name: "extra field",
			payload: extra,
		});
	}

	return cases;
}

function defaultResponse(action) {
	return validValue(action?.output || { kind: "object", shape: {}, allowExtra: false });
}

function lifecycleStates(action) {
	return action?.lifecycle?.requires && !Array.isArray(action.lifecycle.requires)
		? action.lifecycle.requires
		: {};
}

function sessionSetup(contract, remote) {
	const action = contract.actions[remote.actionName];
	const sessionName = remote.lifecycle && remote.lifecycle.session;
	if (!sessionName) {
		return {
			lines: [],
			bindOptions: {
				context: {},
				states: lifecycleStates(action),
			},
		};
	}

	const states = lifecycleStates(action);
	return {
		lines: [
			"local sessions = {",
			`\t[${quote(sessionName)}] = Contract:lifecycleSession(${luaLiteral(states, "\t")}),`,
			"}",
		],
		bindOptions: {
			context: {},
			sessions: "__sessions__",
		},
	};
}

function bindOptionsLiteral(bindOptions) {
	const copy = { ...bindOptions };
	const sessions = copy.sessions;
	delete copy.sessions;
	const literal = luaLiteral(copy);
	if (sessions === "__sessions__") {
		return literal.replace(/\n}$/, ",\n\tsessions = sessions,\n}");
	}
	return literal;
}

function testRemoteBlock(contract, remote) {
	const action = contract.actions[remote.actionName];
	const functionName = sanitizeIdentifier(remote.remoteName);
	const validPayload = validValue(remote.payload);
	const badCases = payloadCases(remote);
	const setup = sessionSetup(contract, remote);
	const defaultResponses = {
		[remote.actionName]: defaultResponse(action),
	};
	const bindOptions = bindOptionsLiteral(setup.bindOptions);
	const lines = [
		`do -- ${contract.name}.${remote.remoteName}`,
		"\tlocal validActor = {",
		"\t\tName = \"ValidPlayer\",",
		"\t\tUserId = 1,",
		"\t}",
		"\tlocal _missingActor = nil",
		`\tlocal defaultResponses = ${luaLiteral(defaultResponses, "\t")}`,
		"\tlocal harness = Contracts.Test.remoteHarness(Contract, {",
		"\t\tdefaultResponses = defaultResponses,",
		"\t})",
		`\tharness:implement(${quote(remote.actionName)})`,
	];

	for (const setupLine of setup.lines) {
		lines.push(`\t${setupLine}`);
	}

	lines.push(`\tharness:bind(${quote(remote.remoteName)}, ${bindOptions})`);

	for (const testCase of badCases) {
		lines.push("");
		lines.push("\tdo");
		lines.push("\t\tharness:clearDiagnostics()");
		lines.push(`\t\tlocal beforeCalls = harness:handlerCalls(${quote(remote.actionName)})`);
		lines.push(`\t\tharness:call(${quote(remote.remoteName)}, validActor, ${luaLiteral(testCase.payload, "\t\t")})`);
		lines.push("\t\tlocal payloadDiagnostic = harness:lastDiagnostic()");
		lines.push(`\t\tcheck(${quote(`${contract.name}.${remote.remoteName} rejects ${testCase.name}`)}, harness:handlerCalls(${quote(remote.actionName)}) == beforeCalls)`);
		lines.push(`\t\tcheck(${quote(`${contract.name}.${remote.remoteName} records invalid payload for ${testCase.name}`)}, payloadDiagnostic ~= nil and (payloadDiagnostic.name == "ActionInputInvalid" or payloadDiagnostic.name == "RemotePayloadInvalid"))`);
		lines.push("\tend");
	}

	if (remote.actor != null) {
		lines.push("");
		lines.push("\tdo");
		lines.push("\t\tharness:clearDiagnostics()");
		lines.push(`\t\tlocal beforeCalls = harness:handlerCalls(${quote(remote.actionName)})`);
		lines.push(`\t\tharness:call(${quote(remote.remoteName)}, _missingActor, ${luaLiteral(validPayload, "\t\t")})`);
		lines.push("\t\tlocal actorDiagnostic = harness:lastDiagnostic()");
		lines.push(`\t\tcheck(${quote(`${contract.name}.${remote.remoteName} rejects missing actor`)}, harness:handlerCalls(${quote(remote.actionName)}) == beforeCalls)`);
		lines.push(`\t\tcheck(${quote(`${contract.name}.${remote.remoteName} records actor rejection`)}, actorDiagnostic ~= nil and string.find(actorDiagnostic.name, "Actor", 1, true) ~= nil)`);
		lines.push("\tend");
	}

	if (remote.lifecycle && remote.lifecycle.revision) {
		const stalePayload = cloneJson(validPayload);
		if (typeof remote.lifecycle.revision === "string") {
			stalePayload[remote.lifecycle.revision] = 99;
		}
		lines.push("");
		lines.push("\tdo");
		lines.push("\t\tharness:clearDiagnostics()");
		lines.push(`\t\tlocal beforeCalls = harness:handlerCalls(${quote(remote.actionName)})`);
		lines.push(`\t\tharness:call(${quote(remote.remoteName)}, validActor, ${luaLiteral(stalePayload, "\t\t")})`);
		lines.push("\t\tlocal revisionDiagnostic = harness:lastDiagnostic()");
		lines.push(`\t\tcheck(${quote(`${contract.name}.${remote.remoteName} rejects stale revision`)}, harness:handlerCalls(${quote(remote.actionName)}) == beforeCalls)`);
		lines.push(`\t\tcheck(${quote(`${contract.name}.${remote.remoteName} records stale revision`)}, revisionDiagnostic ~= nil and revisionDiagnostic.name == "LifecycleStaleRevision")`);
		lines.push("\tend");
	}

	if (remote.rateLimit && remote.rateLimit.maxRequests != null) {
		lines.push("");
		lines.push("\tdo");
		lines.push("\t\tharness:clearDiagnostics()");
		lines.push(`\t\tfor _ = 1, ${(remote.rateLimit.maxRequests || 1) + 1} do`);
		lines.push(`\t\t\tharness:call(${quote(remote.remoteName)}, validActor, ${luaLiteral(validPayload, "\t\t\t")})`);
		lines.push("\t\tend");
		lines.push("\t\tlocal rateLimitDiagnostic = harness:lastDiagnostic()");
		lines.push(`\t\tcheck(${quote(`${contract.name}.${remote.remoteName} rate limits spam`)}, rateLimitDiagnostic ~= nil and rateLimitDiagnostic.name == "RemoteRateLimited")`);
		lines.push("\tend");
	}

	lines.push("end");
	return lines.join("\n");
}

function generateSuite(contract, options) {
	const suitePath = path.join(options.outDir, `${sanitizeModuleName(contract.name, "RemoteAttackTests")}.luau`);
	const contractRequire = modulePathForRequire(suitePath, path.resolve(options.projectRoot, contract.path));
	const sdkRequire = options.sdkRequire || modulePathForRequire(suitePath, path.resolve(options.sdkRoot, "src/Contracts.lua"));
	const fingerprint = artifactFingerprint({
		kind: "remote-attack-tests",
		contract,
	});

	const blocks = contract.remotes.map((remote) => testRemoteBlock(contract, remote));
	const contents = [
		"--!strict",
		"-- <auto-generated by luau-contract. Do not edit by hand.>",
		`-- luau-contract:remote-attack-tests:v1:${fingerprint}`,
		"",
		`local Contracts = require(${quote(sdkRequire)})`,
		`local ContractModule = require(${quote(contractRequire)})`,
		"local Contract = ContractModule.Contract or ContractModule",
		"",
		"return function(check)",
		blocks.map((block) => block.split("\n").map((line) => `\t${line}`).join("\n")).join("\n\n"),
		"end",
		"",
	].join("\n");

	return {
		path: suitePath,
		contents,
	};
}

function generateRunFile(contracts, options) {
	const suiteNames = contracts
		.filter((contract) => contract.remotes.length > 0)
		.map((contract) => sanitizeModuleName(contract.name, "RemoteAttackTests"));
	const lines = [
		"--!strict",
		"-- <auto-generated by luau-contract. Do not edit by hand.>",
		"",
		"local suites: {((any) -> ())} = {",
		...suiteNames.map((name) => `\trequire(${quote(`./${name}`)}) :: any,`),
		"}",
		"",
		"local passed = 0",
		"local failed = 0",
		"",
		"local function check(name: string, condition: boolean)",
		"\tif condition then",
		"\t\tpassed += 1",
		"\telse",
		"\t\tfailed += 1",
		"\t\tprint(\"FAIL: \" .. name)",
		"\tend",
		"end",
		"",
		"for _, suite in ipairs(suites) do",
		"\tsuite(check)",
		"end",
		"",
		"print((\"%d generated remote attack checks passed, %d failed\"):format(passed, failed))",
		"if failed > 0 then",
		"\terror(\"generated remote attack checks failed\", 2)",
		"end",
		"",
	];

	return {
		path: path.join(options.outDir, "run.luau"),
		contents: lines.join("\n"),
	};
}

function generateRemoteAttackTestFiles(artifacts, options = {}) {
	const outDir = path.resolve(options.outDir);
	const contracts = artifacts.contracts.filter((contract) => contract.remotes.length > 0 && contract.path);
	const files = contracts.map((contract) => generateSuite(contract, {
		...options,
		outDir,
	}));
	if (files.length > 0) {
		files.push(generateRunFile(contracts, {
			...options,
			outDir,
		}));
	}
	return files;
}

module.exports = {
	generateRemoteAttackTestFiles,
	luaLiteral,
	validValue,
};
