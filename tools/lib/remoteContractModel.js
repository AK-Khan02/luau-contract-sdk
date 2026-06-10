"use strict";

const { sanitizeIdentifier, sanitizeModuleName } = require("./contractArtifacts");

function actionForRemote(contract, remote) {
	return contract.actions?.[remote.actionName] || null;
}

function actorPolicyForRemote(contract, remote) {
	if (remote.actor != null) {
		return remote.actor;
	}
	const policy = actionForRemote(contract, remote)?.policy || {};
	return policy.actor || policy.authorize || (policy.actorRequired === true ? "required" : null);
}

function outputSchemaForRemote(contract, remote) {
	return remote.response || remote.actionOutput || null;
}

function transportForRemote(remote) {
	return remote.usesRemoteFunction || remote.response != null ? "function" : "event";
}

function supportsClientCall(remote) {
	return remote.direction !== "client";
}

function supportsServerBind(remote) {
	return remote.direction !== "client";
}

function supportsServerFire(remote) {
	return remote.direction === "client" || remote.direction === "bidirectional";
}

function lifecyclePolicy(remote) {
	return remote.lifecycle || {};
}

function asyncPolicyForRemote(contract, remote) {
	const asyncPolicy = actionForRemote(contract, remote)?.async;
	return asyncPolicy && typeof asyncPolicy === "object" ? asyncPolicy : null;
}

function asyncTimeoutSeconds(asyncPolicy) {
	if (asyncPolicy == null || asyncPolicy.timeoutSeconds === false) {
		return null;
	}
	return asyncPolicy.timeoutSeconds != null ? asyncPolicy.timeoutSeconds : 10;
}

function asyncConcurrency(asyncPolicy, remote) {
	if (asyncPolicy.concurrency != null) {
		return asyncPolicy.concurrency;
	}
	return lifecyclePolicy(remote).session != null ? "serialize" : "reject";
}

function asyncAttackCases(contract, remote) {
	const asyncPolicy = asyncPolicyForRemote(contract, remote);
	if (asyncPolicy == null) {
		return [];
	}

	const lifecycle = lifecyclePolicy(remote);
	const cases = [{ kind: "async", name: "in-flight duplicate" }];
	if (asyncTimeoutSeconds(asyncPolicy) != null) {
		cases.push({ kind: "async", name: "handler timeout" });
	}
	if (lifecycle.session != null && typeof lifecycle.revision === "string" && !lifecycle.revision.includes(".")) {
		cases.push({ kind: "async", name: "stale revision after yield" });
	}
	return cases;
}

function payloadAttackCases(schema) {
	if (schema == null) {
		return [{ kind: "payload", name: "wrong payload type" }];
	}
	if (schema.kind !== "object") {
		return [{ kind: "payload", name: "wrong payload type" }];
	}

	const cases = [
		{ kind: "payload", name: "missing payload" },
		{ kind: "payload", name: "wrong payload type" },
	];
	for (const [fieldName, child] of Object.entries(schema.shape || {})) {
		if (child.kind !== "optional") {
			cases.push({ kind: "payload", name: `missing ${fieldName}` });
		}
		cases.push({ kind: "payload", name: `invalid ${fieldName}` });
		if (["string", "number", "integer", "array", "object", "vector3", "optional"].includes(child.kind)) {
			cases.push({ kind: "payload", name: `pathological ${fieldName}` });
		}
	}
	if (schema.allowExtra !== true) {
		cases.push({ kind: "payload", name: "extra field" });
	}
	return cases;
}

function actorAttackCase(actorPolicy, attackConfig) {
	if (actorPolicy == null) {
		return null;
	}
	if (typeof actorPolicy === "string") {
		const configuredActor = attackConfig?.actors?.[actorPolicy];
		if (configuredActor?.invalid !== undefined) {
			return { kind: "actor", name: `unauthorized ${actorPolicy}` };
		}
	}
	return { kind: "actor", name: "missing actor" };
}

function attackCasesForRemote(contract, remote, attackConfig = {}) {
	const lifecycle = lifecyclePolicy(remote);
	const cases = payloadAttackCases(remote.payload);
	const actorCase = actorAttackCase(actorPolicyForRemote(contract, remote), attackConfig);
	if (actorCase != null) {
		cases.push(actorCase);
	}
	if (lifecycle.revision != null) {
		cases.push({ kind: "lifecycle", name: "stale revision" });
	}
	if (remote.rateLimit?.maxRequests != null) {
		cases.push({ kind: "rateLimit", name: "spam" });
	}
	if (outputSchemaForRemote(contract, remote) != null) {
		cases.push({ kind: "response", name: "bad response shape" });
	}
	cases.push(...asyncAttackCases(contract, remote));
	return cases;
}

function remotePolicyGaps(contract, remote) {
	const gaps = [];
	if (actorPolicyForRemote(contract, remote) == null) {
		gaps.push("actor");
	}
	if (remote.rateLimit == null) {
		gaps.push("rateLimit");
	}
	if (outputSchemaForRemote(contract, remote) == null) {
		gaps.push("output");
	}
	return gaps;
}

function remoteModel(contract, remote, attackConfig = {}) {
	const action = actionForRemote(contract, remote);
	const actorPolicy = actorPolicyForRemote(contract, remote);
	const lifecycle = lifecyclePolicy(remote);
	const attackCases = attackCasesForRemote(contract, remote, attackConfig);

	return {
		contractName: contract.name,
		remoteName: remote.remoteName,
		remoteIdentifier: sanitizeIdentifier(remote.remoteName),
		actionName: remote.actionName,
		hasAction: action != null,
		direction: remote.direction,
		transport: transportForRemote(remote),
		inputSchema: remote.payload,
		outputSchema: outputSchemaForRemote(contract, remote),
		remoteResponseSchema: remote.response,
		actionOutputSchema: remote.actionOutput,
		clientCallable: supportsClientCall(remote),
		serverBindable: supportsServerBind(remote),
		serverCanFire: supportsServerFire(remote),
		actorPolicy,
		hasActorPolicy: actorPolicy != null,
		lifecycle,
		hasLifecycleSession: lifecycle.session != null,
		hasLifecycleRevision: lifecycle.revision != null,
		rateLimit: remote.rateLimit,
		hasRateLimit: remote.rateLimit != null,
		tags: remote.tags || [],
		attackCases,
		attackCaseCount: attackCases.length,
		policyGaps: remotePolicyGaps(contract, remote),
	};
}

function contractModel(contract, options = {}) {
	const remotes = (contract.remotes || []).map((remote) => remoteModel(contract, remote, options.attackConfig || {}));
	return {
		name: contract.name,
		identifier: contract.identifier || sanitizeIdentifier(contract.name, "Contract"),
		path: contract.path,
		typeModuleName: sanitizeModuleName(contract.name, "Types"),
		clientModuleName: sanitizeModuleName(contract.name, "Client"),
		serverModuleName: sanitizeModuleName(contract.name, "Server"),
		manifestModuleName: sanitizeModuleName(contract.name, "Manifest"),
		remotes,
	};
}

function remoteContractModels(artifacts, options = {}) {
	return (artifacts.contracts || []).map((contract) => contractModel(contract, options));
}

function remoteAttackSummary(artifacts, options = {}) {
	const remotes = [];
	for (const contract of remoteContractModels(artifacts, options)) {
		for (const remote of contract.remotes) {
			remotes.push({
				contract: contract.name,
				remote: remote.remoteName,
				caseCount: remote.attackCaseCount,
				cases: remote.attackCases,
			});
		}
	}
	return {
		remoteCount: remotes.length,
		caseCount: remotes.reduce((total, remote) => total + remote.caseCount, 0),
		remotes,
	};
}

function remoteSecuritySummary(artifacts, options = {}) {
	const remotes = [];
	for (const contract of remoteContractModels(artifacts, options)) {
		for (const remote of contract.remotes) {
			remotes.push({
				contract: contract.name,
				remote: remote.remoteName,
				transport: remote.transport,
				hasActorPolicy: remote.hasActorPolicy,
				hasRateLimit: remote.hasRateLimit,
				hasOutput: remote.outputSchema != null,
				hasLifecycleRevision: remote.hasLifecycleRevision,
				attackCaseCount: remote.attackCaseCount,
				policyGaps: remote.policyGaps,
			});
		}
	}
	return {
		remoteCount: remotes.length,
		fullyCoveredRemoteCount: remotes.filter((remote) => remote.policyGaps.length === 0).length,
		remotes,
	};
}

function manifestForContract(contract, options = {}) {
	const model = contractModel(contract, options);
	const remotes = {};
	for (const remote of model.remotes) {
		remotes[remote.remoteName] = {
			action: remote.hasAction ? remote.actionName : null,
			transport: remote.transport,
			direction: remote.direction,
			hasInput: remote.inputSchema != null,
			hasOutput: remote.outputSchema != null,
			hasActorPolicy: remote.hasActorPolicy,
			hasRateLimit: remote.hasRateLimit,
			hasLifecycleSession: remote.hasLifecycleSession,
			hasLifecycleRevision: remote.hasLifecycleRevision,
			attackCaseCount: remote.attackCaseCount,
			policyGaps: remote.policyGaps,
		};
	}
	return {
		system: model.name,
		remotes,
	};
}

module.exports = {
	actorPolicyForRemote,
	asyncConcurrency,
	asyncPolicyForRemote,
	asyncTimeoutSeconds,
	attackCasesForRemote,
	contractModel,
	manifestForContract,
	outputSchemaForRemote,
	remoteAttackSummary,
	remoteContractModels,
	remoteModel,
	remoteSecuritySummary,
	transportForRemote,
};
