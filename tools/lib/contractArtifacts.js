"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { stableStringify } = require("./stableStringify");

const GENERATOR_VERSION = 1;

function asObject(value) {
	return value && typeof value === "object" && !Array.isArray(value) ? value : {};
}

function asArray(value) {
	return Array.isArray(value) ? value : [];
}

function sanitizeIdentifier(value, fallback = "Generated") {
	const text = String(value || fallback).replace(/[^A-Za-z0-9_]/g, "_");
	const withoutLeadingDigits = text.replace(/^[0-9_]+/, "");
	return withoutLeadingDigits || fallback;
}

function sanitizeModuleName(value, suffix = "") {
	return `${sanitizeIdentifier(value)}${suffix}`;
}

// Tracks the original inputs that map onto each sanitized identifier so that
// two distinct names collapsing to the same identifier (e.g. "My-System" and
// "My_System" both -> "My_System") fail loudly instead of silently
// overwriting each other's generated files. `scope` only shapes the error
// message; pass a different guard per independent namespace.
function createCollisionGuard(scope) {
	const seen = new Map();
	return function register(original, sanitized) {
		const previous = seen.get(sanitized);
		if (previous !== undefined && previous !== original) {
			throw new Error(
				`${scope} name collision: "${previous}" and "${original}" both sanitize to "${sanitized}". ` +
				"Rename one so generated identifiers stay unique.",
			);
		}
		if (previous === undefined) {
			seen.set(sanitized, original);
		}
		return sanitized;
	};
}

function schemaFingerprint(value) {
	return crypto.createHash("sha256").update(stableStringify(value)).digest("hex").slice(0, 16);
}

function artifactFingerprint(value) {
	return crypto
		.createHash("sha256")
		.update(stableStringify({
			generatorVersion: GENERATOR_VERSION,
			value,
		}))
		.digest("hex");
}

function realpathWithExistingParent(targetPath) {
	let current = path.resolve(targetPath);
	const missingParts = [];
	while (!fs.existsSync(current)) {
		const parent = path.dirname(current);
		if (parent === current) {
			return path.resolve(targetPath);
		}
		missingParts.unshift(path.basename(current));
		current = parent;
	}
	return path.join(fs.realpathSync(current), ...missingParts);
}

function actionForRemote(contract, remoteName, remote) {
	const actionName = remote.action || remoteName;
	const actions = asObject(contract.actions);
	return actions[actionName] || null;
}

function normalizeLifecycle(value) {
	return asObject(value);
}

function normalizeRemote(contract, remoteName, remote, registerRemoteIdentifier) {
	const action = actionForRemote(contract, remoteName, remote);
	const payload = remote.payload || remote.input || action?.input || { kind: "any" };
	const response = remote.response || null;

	return {
		systemName: contract.name,
		remoteName,
		remoteIdentifier: registerRemoteIdentifier(remoteName, sanitizeIdentifier(remoteName)),
		actionName: remote.action || action?.name || remoteName,
		direction: remote.direction || "server",
		payload,
		response,
		actionInput: action?.input || null,
		actionOutput: action?.output || null,
		actor: remote.actor,
		lifecycle: normalizeLifecycle(remote.lifecycle),
		rateLimit: remote.rateLimit || null,
		tags: asArray(remote.tags),
		usesRemoteFunction: response != null,
	};
}

function normalizeContract(contract, registerContractIdentifier = (original, sanitized) => sanitized) {
	const registerRemoteIdentifier = createCollisionGuard(
		`Remote (${contract.name}) identifier`,
	);
	const remotes = Object.entries(asObject(contract.remotes)).map(([remoteName, remote]) => {
		return normalizeRemote(contract, remoteName, asObject(remote), registerRemoteIdentifier);
	});

	const artifact = {
		name: contract.name,
		identifier: registerContractIdentifier(
			contract.name,
			sanitizeIdentifier(contract.name, "Contract"),
		),
		path: contract.path || null,
		actions: asObject(contract.actions),
		remotes,
		lifecycles: asObject(contract.lifecycles),
		permissions: asObject(contract.permissions),
		preconditions: asArray(contract.preconditions),
		postconditions: asArray(contract.postconditions),
		actorPolicies: asArray(contract.actorPolicies),
	};

	return {
		...artifact,
		fingerprint: artifactFingerprint(artifact),
	};
}

function fromReport(report) {
	const registerContractIdentifier = createCollisionGuard("Contract module");
	const contracts = asArray(report?.contracts).map((contract) => {
		return normalizeContract(contract, registerContractIdentifier);
	});
	const warnings = [];

	for (const contract of contracts) {
		if (contract.remotes.length === 0) {
			warnings.push({
				level: "warn",
				code: "ContractHasNoRemotes",
				message: `${contract.name} has no remote declarations to generate.`,
				contract: contract.name,
			});
		}
		for (const remote of contract.remotes) {
			if (remote.response == null && remote.actionOutput != null) {
				warnings.push({
					level: "info",
					code: "ActionOutputWithoutRemoteResponse",
					message: `${contract.name}.${remote.remoteName} has an action output but no remote response schema; generated client uses FireServer.`,
					contract: contract.name,
					remote: remote.remoteName,
				});
			}
		}
	}

	return {
		formatVersion: 1,
		generatorVersion: GENERATOR_VERSION,
		contracts,
		warnings,
		fingerprint: artifactFingerprint(contracts),
	};
}

function modulePathForRequire(fromFile, targetFile) {
	const fromDir = realpathWithExistingParent(path.dirname(fromFile));
	const resolvedTarget = realpathWithExistingParent(targetFile);
	const relative = path.relative(fromDir, resolvedTarget)
		.replace(/\\/g, "/")
		.replace(/\.luau?$/, "");
	return relative.startsWith(".") ? relative : `./${relative}`;
}

module.exports = {
	GENERATOR_VERSION,
	artifactFingerprint,
	fromReport,
	modulePathForRequire,
	sanitizeIdentifier,
	sanitizeModuleName,
	schemaFingerprint,
};
