"use strict";

const {
	actorPolicyForRemote,
	asyncConcurrency,
	asyncPolicyForRemote,
	asyncTimeoutSeconds,
	outputSchemaForRemote,
} = require("./remoteContractModel");
const {
	cloneJson,
	invalidResponseValue,
	luaLiteral,
	payloadCases,
	quote,
	validValue,
} = require("./remoteAttackValues");

function actorCase(contract, remote, attackConfig) {
	const actorPolicy = actorPolicyForRemote(contract, remote);
	if (actorPolicy == null) {
		return null;
	}
	if (typeof actorPolicy === "string") {
		const configuredActor = attackConfig?.actors?.[actorPolicy];
		if (configuredActor?.invalid !== undefined) {
			return {
				name: `unauthorized ${actorPolicy}`,
				actor: configuredActor.invalid,
			};
		}
	}
	return {
		name: "missing actor",
		actor: null,
	};
}

function defaultResponse(contract, remote) {
	return validValue(outputSchemaForRemote(contract, remote) || { kind: "object", shape: {}, allowExtra: false });
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
	const revisionField = typeof remote.lifecycle?.revision === "string" && !remote.lifecycle.revision.includes(".")
		? remote.lifecycle.revision
		: null;
	const revisionOptions = revisionField != null
		? `, { revision = ${luaLiteral(validValue(remote.payload)[revisionField] ?? 0)} }`
		: "";
	return {
		lines: [
			"local sessions = {",
			`\t[${quote(sessionName)}] = Contract:lifecycleSession(${luaLiteral(states, "\t")}${revisionOptions}),`,
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
		return literal.replace(/\n}$/, "\n\tsessions = sessions,\n}");
	}
	return literal;
}

function asyncHarnessLines(contract, remote, bindOptions, sessionsVariable) {
	const action = contract.actions[remote.actionName];
	const sessionName = remote.lifecycle && remote.lifecycle.session;
	const states = lifecycleStates(action);
	const revisionField = typeof remote.lifecycle?.revision === "string" && !remote.lifecycle.revision.includes(".")
		? remote.lifecycle.revision
		: null;
	const harnessLines = [
		"\t\tlocal scheduler = Contracts.Test.manualScheduler()",
	];
	if (sessionName) {
		const revisionOptions = revisionField != null
			? `, { revision = ${luaLiteral(validValue(remote.payload)[revisionField] ?? 0)} }`
			: "";
		harnessLines.push(`\t\tlocal ${sessionsVariable} = {`);
		harnessLines.push(`\t\t\t[${quote(sessionName)}] = Contract:lifecycleSession(${luaLiteral(states, "\t\t\t")}${revisionOptions}),`);
		harnessLines.push("\t\t}");
	}
	harnessLines.push(
		"\t\tlocal harness = Contracts.Test.remoteHarness(Contract, {",
		"\t\t\tdefaultResponses = defaultResponses,",
		"\t\t\tscheduler = scheduler,",
		"\t\t})",
		`\t\tharness:implementYielding(${quote(remote.actionName)})`
	);
	if (sessionName) {
		harnessLines.push(`\t\tharness:bind(${quote(remote.remoteName)}, { context = {}, sessions = ${sessionsVariable} })`);
	} else {
		harnessLines.push(`\t\tharness:bind(${quote(remote.remoteName)}, ${bindOptions.split("\n").join("\n\t\t")})`);
	}
	harnessLines.push("\t\tharness:clearDiagnostics()");
	return harnessLines;
}

function appendPayloadCases(lines, contract, remote, validActor, badCases) {
	for (const testCase of badCases) {
		lines.push("");
		lines.push("\tdo");
		lines.push("\t\tlocal harness = newHarness()");
		lines.push("\t\tharness:clearDiagnostics()");
		lines.push(`\t\tlocal beforeCalls = harness:handlerCalls(${quote(remote.actionName)})`);
		lines.push(`\t\tharness:call(${quote(remote.remoteName)}, ${validActor}, ${luaLiteral(testCase.payload, "\t\t")})`);
		lines.push("\t\tlocal payloadDiagnostic = harness:lastDiagnostic()");
		lines.push(`\t\tcheck(${quote(`${contract.name}.${remote.remoteName} rejects ${testCase.name}`)}, harness:handlerCalls(${quote(remote.actionName)}) == beforeCalls)`);
		lines.push(`\t\tcheck(${quote(`${contract.name}.${remote.remoteName} records invalid payload for ${testCase.name}`)}, payloadDiagnostic ~= nil and (payloadDiagnostic.name == "ActionInputInvalid" or payloadDiagnostic.name == "RemotePayloadInvalid"))`);
		lines.push("\tend");
	}
}

function appendActorCase(lines, contract, remote, attackConfig, validPayload) {
	const invalidActorCase = actorCase(contract, remote, attackConfig);
	if (invalidActorCase == null) {
		return;
	}

	lines.push("");
	lines.push("\tdo");
	lines.push("\t\tlocal harness = newHarness()");
	lines.push("\t\tharness:clearDiagnostics()");
	lines.push(`\t\tlocal beforeCalls = harness:handlerCalls(${quote(remote.actionName)})`);
	lines.push(`\t\tharness:call(${quote(remote.remoteName)}, ${luaLiteral(invalidActorCase.actor, "\t\t")}, ${luaLiteral(validPayload, "\t\t")})`);
	lines.push("\t\tlocal actorDiagnostic = harness:lastDiagnostic()");
	lines.push(`\t\tcheck(${quote(`${contract.name}.${remote.remoteName} rejects ${invalidActorCase.name}`)}, harness:handlerCalls(${quote(remote.actionName)}) == beforeCalls)`);
	lines.push(`\t\tcheck(${quote(`${contract.name}.${remote.remoteName} records actor rejection`)}, actorDiagnostic ~= nil and string.find(actorDiagnostic.name, "Actor", 1, true) ~= nil)`);
	lines.push("\tend");
}

function appendLifecycleCase(lines, contract, remote, validPayload) {
	if (!(remote.lifecycle && remote.lifecycle.revision)) {
		return;
	}

	const stalePayload = cloneJson(validPayload);
	if (typeof remote.lifecycle.revision === "string") {
		stalePayload[remote.lifecycle.revision] = 99;
	}
	lines.push("");
	lines.push("\tdo");
	lines.push("\t\tlocal harness = newHarness()");
	lines.push("\t\tharness:clearDiagnostics()");
	lines.push(`\t\tlocal beforeCalls = harness:handlerCalls(${quote(remote.actionName)})`);
	lines.push(`\t\tharness:call(${quote(remote.remoteName)}, validActor, ${luaLiteral(stalePayload, "\t\t")})`);
	lines.push("\t\tlocal revisionDiagnostic = harness:lastDiagnostic()");
	lines.push(`\t\tcheck(${quote(`${contract.name}.${remote.remoteName} rejects stale revision`)}, harness:handlerCalls(${quote(remote.actionName)}) == beforeCalls)`);
	lines.push(`\t\tcheck(${quote(`${contract.name}.${remote.remoteName} records stale revision`)}, revisionDiagnostic ~= nil and revisionDiagnostic.name == "LifecycleStaleRevision")`);
	lines.push("\tend");
}

function appendRateLimitCase(lines, contract, remote, validPayload) {
	if (!(remote.rateLimit && remote.rateLimit.maxRequests != null)) {
		return;
	}

	lines.push("");
	lines.push("\tdo");
	lines.push("\t\tlocal harness = newHarness()");
	lines.push("\t\tharness:clearDiagnostics()");
	lines.push(`\t\tfor _ = 1, ${(remote.rateLimit.maxRequests || 1) + 1} do`);
	lines.push(`\t\t\tharness:call(${quote(remote.remoteName)}, validActor, ${luaLiteral(validPayload, "\t\t\t")})`);
	lines.push("\t\tend");
	lines.push("\t\tlocal rateLimitDiagnostic = harness:lastDiagnostic()");
	lines.push(`\t\tcheck(${quote(`${contract.name}.${remote.remoteName} rate limits spam`)}, rateLimitDiagnostic ~= nil and rateLimitDiagnostic.name == "RemoteRateLimited")`);
	lines.push("\tend");
}

function appendAsyncCases(lines, contract, remote, bindOptions, validPayload) {
	const asyncPolicy = asyncPolicyForRemote(contract, remote);
	if (asyncPolicy == null) {
		return;
	}

	const subject = `${contract.name}.${remote.remoteName}`;
	const sessionName = remote.lifecycle && remote.lifecycle.session;
	const concurrency = asyncConcurrency(asyncPolicy, remote);
	const timeoutSeconds = asyncTimeoutSeconds(asyncPolicy);
	const revisionField = typeof remote.lifecycle?.revision === "string" && !remote.lifecycle.revision.includes(".")
		? remote.lifecycle.revision
		: null;

	lines.push("");
	lines.push("\tdo");
	lines.push(...asyncHarnessLines(contract, remote, bindOptions, "asyncSessions"));
	lines.push(`\t\tlocal first = harness:callAsync(${quote(remote.remoteName)}, validActor, ${luaLiteral(validPayload, "\t\t")})`);
	lines.push(`\t\tlocal second = harness:callAsync(${quote(remote.remoteName)}, validActor, ${luaLiteral(validPayload, "\t\t")})`);
	lines.push(`\t\tcheck(${quote(`${subject} never interleaves in-flight duplicates`)}, harness:handlerCalls(${quote(remote.actionName)}) == 1)`);
	if (concurrency === "reject") {
		lines.push("\t\tlocal busyDiagnostic = harness:lastDiagnostic()");
		lines.push(`\t\tcheck(${quote(`${subject} records ActionBusy for in-flight duplicate`)}, busyDiagnostic ~= nil and busyDiagnostic.name == "ActionBusy")`);
	}
	lines.push(`\t\twhile harness:pendingHandlerCount(${quote(remote.actionName)}) > 0 do`);
	lines.push(`\t\t\tharness:resume(${quote(remote.actionName)})`);
	lines.push("\t\tend");
	lines.push(`\t\tcheck(${quote(`${subject} settles every duplicate call`)}, first.settled == true and second.settled == true)`);
	lines.push("\tend");

	if (timeoutSeconds != null) {
		lines.push("");
		lines.push("\tdo");
		lines.push(...asyncHarnessLines(contract, remote, bindOptions, "timeoutSessions"));
		lines.push(`\t\tlocal pending = harness:callAsync(${quote(remote.remoteName)}, validActor, ${luaLiteral(validPayload, "\t\t")})`);
		lines.push(`\t\tcheck(${quote(`${subject} holds slow handler before deadline`)}, pending.settled == false)`);
		lines.push(`\t\tscheduler.advance(${timeoutSeconds})`);
		lines.push(`\t\tcheck(${quote(`${subject} times out stuck handler`)}, pending.settled == true)`);
		lines.push(`\t\tcheck(${quote(`${subject} records ActionTimeout`)}, #harness:diagnostics():findByName("ActionTimeout") >= 1)`);
		lines.push(`\t\twhile harness:pendingHandlerCount(${quote(remote.actionName)}) > 0 do`);
		lines.push(`\t\t\tharness:resume(${quote(remote.actionName)})`);
		lines.push("\t\tend");
		lines.push(`\t\tcheck(${quote(`${subject} blocks commits after timeout`)}, #harness:diagnostics():findByName("ActionCancelled") >= 1)`);
		lines.push("\tend");
	}

	if (sessionName && revisionField != null) {
		lines.push("");
		lines.push("\tdo");
		lines.push(...asyncHarnessLines(contract, remote, bindOptions, "staleSessions"));
		lines.push(`\t\tlocal pending = harness:callAsync(${quote(remote.remoteName)}, validActor, ${luaLiteral(validPayload, "\t\t")})`);
		lines.push(`\t\tcheck(${quote(`${subject} starts handler before revision moves`)}, harness:handlerCalls(${quote(remote.actionName)}) == 1)`);
		lines.push(`\t\tlocal staleSession = staleSessions[${quote(sessionName)}]`);
		lines.push("\t\tstaleSession:restore({");
		lines.push("\t\t\trevision = staleSession:revision() + 1,");
		lines.push("\t\t\tstates = staleSession:states(),");
		lines.push("\t\t})");
		lines.push(`\t\tharness:resume(${quote(remote.actionName)})`);
		lines.push(`\t\tcheck(${quote(`${subject} settles after stale revision`)}, pending.settled == true)`);
		lines.push(`\t\tcheck(${quote(`${subject} refuses stale revision after yield`)}, #harness:diagnostics():findByName("LifecycleStaleRevision") >= 1)`);
		lines.push("\tend");
	}
}

function appendResponseCase(lines, contract, remote, validPayload, badResponse, badResponseDiagnostic) {
	if (badResponse == null) {
		return;
	}

	lines.push("");
	lines.push("\tdo");
	lines.push(`\t\tlocal badResponses = ${luaLiteral({ [remote.actionName]: badResponse }, "\t\t")}`);
	lines.push("\t\tlocal harness = newHarness(badResponses)");
	lines.push("\t\tharness:clearDiagnostics()");
	lines.push(`\t\tlocal beforeCalls = harness:handlerCalls(${quote(remote.actionName)})`);
	lines.push(`\t\tharness:call(${quote(remote.remoteName)}, validActor, ${luaLiteral(validPayload, "\t\t")})`);
	lines.push("\t\tlocal responseDiagnostic = harness:lastDiagnostic()");
	lines.push(`\t\tcheck(${quote(`${contract.name}.${remote.remoteName} reaches handler for bad response shape`)}, harness:handlerCalls(${quote(remote.actionName)}) == beforeCalls + 1)`);
	lines.push(`\t\tcheck(${quote(`${contract.name}.${remote.remoteName} records bad response shape`)}, responseDiagnostic ~= nil and responseDiagnostic.name == ${quote(badResponseDiagnostic)})`);
	lines.push("\tend");
}

function testRemoteBlock(contract, remote, attackConfig) {
	const action = contract.actions[remote.actionName];
	const validPayload = validValue(remote.payload);
	const badCases = payloadCases(remote);
	const setup = sessionSetup(contract, remote);
	const defaultResponses = {
		[remote.actionName]: defaultResponse(contract, remote),
	};
	const bindOptions = bindOptionsLiteral(setup.bindOptions);
	const responseSchema = outputSchemaForRemote(contract, remote);
	const badResponse = responseSchema ? invalidResponseValue(responseSchema) : null;
	const badResponseDiagnostic = action?.output ? "ActionOutputInvalid" : "RemoteResponseInvalid";
	const lines = [
		`do -- ${contract.name}.${remote.remoteName}`,
		"\tlocal validActor = {",
		"\t\tName = \"ValidPlayer\",",
		"\t\tUserId = 1,",
		"\t}",
		`\tlocal defaultResponses = ${luaLiteral(defaultResponses, "\t")}`,
	];

	for (const setupLine of setup.lines) {
		lines.push(`\t${setupLine}`);
	}

	const harnessSchedulerLine = asyncPolicyForRemote(contract, remote) != null
		? "\t\t\tscheduler = Contracts.Test.manualScheduler(),"
		: null;
	lines.push(
		"\tlocal function newHarness(defaultResponsesOverride)",
		"\t\tlocal harness = Contracts.Test.remoteHarness(Contract, {",
		"\t\t\tdefaultResponses = defaultResponsesOverride or defaultResponses,",
		...(harnessSchedulerLine ? [harnessSchedulerLine] : []),
		"\t\t})",
		`\t\tharness:implement(${quote(remote.actionName)})`,
		`\t\tharness:bind(${quote(remote.remoteName)}, ${bindOptions})`,
		"\t\treturn harness",
		"\tend"
	);

	appendPayloadCases(lines, contract, remote, "validActor", badCases);
	appendActorCase(lines, contract, remote, attackConfig, validPayload);
	appendLifecycleCase(lines, contract, remote, validPayload);
	appendRateLimitCase(lines, contract, remote, validPayload);
	appendAsyncCases(lines, contract, remote, bindOptions, validPayload);
	appendResponseCase(lines, contract, remote, validPayload, badResponse, badResponseDiagnostic);

	lines.push("end");
	return lines.join("\n");
}

module.exports = {
	testRemoteBlock,
};
