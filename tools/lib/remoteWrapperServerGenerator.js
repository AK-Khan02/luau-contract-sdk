"use strict";

const path = require("node:path");
const { artifactFingerprint } = require("./contractArtifacts");
const { emitRemoteTypes, typeNameFor } = require("./luauTypeEmitter");
const { contractModel } = require("./remoteContractModel");
const { generatedHeader } = require("./remoteWrapperHeader");
const {
	serverAliasBlocks,
	serverClientRemoteAliasName,
} = require("./remoteWrapperTypes");

function remoteField(remoteName) {
	return /^[A-Za-z_][A-Za-z0-9_]*$/.test(remoteName)
		? `remotes.${remoteName}`
		: `remotes[${JSON.stringify(remoteName)}]`;
}

function serverFireFunction(contract, remote) {
	const payloadType = typeNameFor(contract.name, remote.remoteName, "Payload");

	if (!remote.serverCanFire) {
		return null;
	}
	return [
		`function Server.fire${remote.remoteIdentifier}(remote: ${serverClientRemoteAliasName(contract, remote)}, player: PlayerLike, payload: ${payloadType})`,
		`\tassertClientRemote(remote, ${JSON.stringify(remote.remoteName)})`,
		"\tremote:FireClient(player, payload)",
		"end",
	].join("\n");
}

function runtimeImplementationLines(remote) {
	if (!remote.hasAction) {
		return [];
	}
	return [
		`\t\tlocal handler = runtimeHandlerFor(handlers, ${JSON.stringify(remote.remoteName)}, ${JSON.stringify(remote.actionName)})`,
		"\t\tif handler ~= nil then",
		`\t\t\truntime:implement(${JSON.stringify(remote.actionName)}, handler, implementOptions)`,
		"\t\tend",
	];
}

function bindLine(remote) {
	const fieldName = remoteField(remote.remoteName);
	const remoteOptions = `bindOptions[${JSON.stringify(remote.remoteName)}] or bindOptions`;
	if (remote.hasAction) {
		return `\truntime:bindRemote(${JSON.stringify(remote.remoteName)}, ${fieldName}, ${remoteOptions})`;
	}
	return [
		"\tlocal legacyOptions = copyOptions(" + remoteOptions + ")",
		`\tlegacyOptions.handler = legacyOptions.handler or runtimeHandlerFor(handlers, ${JSON.stringify(remote.remoteName)}, ${JSON.stringify(remote.actionName)})`,
		`\truntime:bindRemote(${JSON.stringify(remote.remoteName)}, ${fieldName}, legacyOptions)`,
	].join("\n");
}

function guardLine(remote) {
	const fieldName = remoteField(remote.remoteName);
	return [
		`\tconnections[${JSON.stringify(remote.remoteName)}] = Contracts.Roblox.RemoteGuard.connect(Contract, ${JSON.stringify(remote.remoteName)}, ${fieldName}, requireGuardHandler(handlers, ${JSON.stringify(remote.remoteName)}, ${JSON.stringify(remote.actionName)}), guardOptions[${JSON.stringify(remote.remoteName)}] or guardOptions)`,
	].join("\n");
}

function handlerMapChecks(serverRemotes) {
	return serverRemotes.flatMap((remote) => [
		`\tif type(value[${JSON.stringify(remote.remoteName)}]) == "function" then`,
		"\t\treturn true",
		"\tend",
		`\tif type(value[${JSON.stringify(remote.actionName)}]) == "function" then`,
		"\t\treturn true",
		"\tend",
	]);
}

function legacyCopyOptionsBlock(hasLegacyRemotes) {
	return hasLegacyRemotes ? [
		"local function copyOptions(options: BindOptions?): BindOptions",
		"\tlocal copy = {}",
		"\tfor key, value in pairs(options or {}) do",
		"\t\tcopy[key] = value",
		"\tend",
		"\treturn copy",
		"end",
		"",
	] : [];
}

function clientRemoteAssertBlock(hasClientRemotes) {
	return hasClientRemotes ? [
		"local function assertClientRemote(remote: ClientRemoteEventLike, remoteName: string)",
		"\tif remote == nil or type(remote.FireClient) ~= \"function\" then",
		"\t\terror(remoteName .. \" expects a RemoteEvent-like value with FireClient\", 3)",
		"\tend",
		"end",
		"",
	] : [];
}

function generateServerModule(contract, options) {
	const model = contractModel(contract, options);
	const fingerprint = artifactFingerprint({
		kind: "remote-server",
		contract,
	});
	const fireFunctions = model.remotes
		.map((remote) => serverFireFunction(contract, remote))
		.filter(Boolean);
	const serverRemotes = model.remotes.filter((remote) => remote.serverBindable);
	const hasLegacyRemotes = serverRemotes.some((remote) => !remote.hasAction);
	const implementationLines = serverRemotes.flatMap(runtimeImplementationLines);
	const bindLines = serverRemotes.map(bindLine);
	const guardLines = serverRemotes.map(guardLine);
	const handlerChecks = handlerMapChecks(serverRemotes);

	const contents = [
		generatedHeader("remote-server", fingerprint),
		emitRemoteTypes(contract, options),
		...serverAliasBlocks(contract, model),
		"",
		"local Server = {}",
		"",
		...legacyCopyOptionsBlock(hasLegacyRemotes),
		"local function runtimeHandlerFor(handlers: RuntimeHandlers?, remoteName: string, actionName: string): RuntimeHandler?",
		"\tif type(handlers) ~= \"table\" then",
		"\t\treturn nil",
		"\tend",
		"\treturn handlers[remoteName] or handlers[actionName]",
		"end",
		"",
		"local function guardHandlerFor(handlers: GuardHandlers?, remoteName: string, actionName: string): GuardHandler?",
		"\tif type(handlers) ~= \"table\" then",
		"\t\treturn nil",
		"\tend",
		"\treturn handlers[remoteName] or handlers[actionName]",
		"end",
		"",
		"local function requireGuardHandler(handlers: GuardHandlers?, remoteName: string, actionName: string): GuardHandler",
		"\tlocal handler = guardHandlerFor(handlers, remoteName, actionName)",
		"\tif type(handler) ~= \"function\" then",
		"\t\terror(remoteName .. \" needs a generated server handler\", 3)",
		"\tend",
		"\treturn handler",
		"end",
		"",
		"local function looksLikeHandlerMap(value: any): boolean",
		"\tif type(value) ~= \"table\" then",
		"\t\treturn false",
		"\tend",
		handlerChecks.length > 0 ? handlerChecks.join("\n") : "\treturn false",
		handlerChecks.length > 0 ? "\treturn false" : "",
		"end",
		"",
		...clientRemoteAssertBlock(fireFunctions.length > 0),
		"function Server.bind(runtime: RuntimeLike, remotes: Remotes, handlersOrOptions: (RuntimeHandlers | BindOptions)?, options: BindOptions?)",
		"\tlocal handlers: RuntimeHandlers? = if options ~= nil or looksLikeHandlerMap(handlersOrOptions) then handlersOrOptions :: RuntimeHandlers else nil",
		"\tlocal bindOptions: BindOptions = if options ~= nil then options else if handlers ~= nil then {} else (handlersOrOptions :: BindOptions?) or {}",
		"\tlocal implementOptions = bindOptions.implementOptions or { overwrite = true }",
		implementationLines.length > 0 ? implementationLines.join("\n") : "\t-- No action implementations are generated for this contract.",
		bindLines.length > 0 ? bindLines.join("\n") : "\t-- No server-bindable remotes are declared on this contract.",
		"\treturn runtime",
		"end",
		"",
		"function Server.guard(Contracts: ContractsLike, Contract: any, remotes: Remotes, handlers: GuardHandlers, options: GuardOptions?)",
		"\tlocal guardOptions: GuardOptions = options or {}",
		"\tlocal connections = {}",
		guardLines.length > 0 ? guardLines.join("\n") : "\t-- No server-guardable remotes are declared on this contract.",
		"\treturn connections",
		"end",
		"",
		fireFunctions.length > 0 ? fireFunctions.join("\n\n") : "-- No client-directed remotes are declared on this contract.",
		"",
		"return Server",
		"",
	].join("\n");

	return {
		path: path.join(options.outDir, `${model.serverModuleName}.luau`),
		contents,
	};
}

module.exports = {
	generateServerModule,
};
