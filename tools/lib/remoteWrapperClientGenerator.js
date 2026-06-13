"use strict";

const path = require("node:path");
const { artifactFingerprint } = require("./contractArtifacts");
const { emitRemoteTypes, typeNameFor } = require("./luauTypeEmitter");
const { contractModel } = require("./remoteContractModel");
const { generatedHeader } = require("./remoteWrapperHeader");
const {
	clientRemoteAlias,
	clientRemoteAliasName,
	responseType,
} = require("./remoteWrapperTypes");

function clientFunction(contract, remote) {
	const payloadType = typeNameFor(contract.name, remote.remoteName, "Payload");
	const responseTypeName = responseType(contract, remote);
	const remoteType = clientRemoteAliasName(contract, remote);

	if (!remote.clientCallable) {
		return null;
	}
	if (remote.transport === "function") {
		return [
			`function Client.${remote.remoteIdentifier}(remote: ${remoteType}, payload: ${payloadType}): ${responseTypeName}?`,
			`\tassertRemoteFunction(remote, ${JSON.stringify(remote.remoteName)})`,
			"\treturn remote:InvokeServer(payload)",
			"end",
		].join("\n");
	}
	return [
		`function Client.${remote.remoteIdentifier}(remote: ${remoteType}, payload: ${payloadType})`,
		`\tassertRemoteEvent(remote, ${JSON.stringify(remote.remoteName)})`,
		"\tremote:FireServer(payload)",
		"end",
	].join("\n");
}

function clientAliases(contract, model) {
	const aliases = [];
	for (const remote of model.remotes.filter((remote) => remote.clientCallable)) {
		aliases.push(clientRemoteAlias(contract, remote));
	}
	if (model.remotes.some((remote) => remote.clientCallable && remote.transport === "event")) {
		aliases.push("type RemoteEventLike = { FireServer: (RemoteEventLike, any) -> any }");
	}
	if (model.remotes.some((remote) => remote.clientCallable && remote.transport === "function")) {
		aliases.push("type RemoteFunctionLike = { InvokeServer: (RemoteFunctionLike, any) -> any }");
	}
	return aliases;
}

function clientAssertHelpers(model) {
	const needsEventAssert = model.remotes.some((remote) => remote.clientCallable && remote.transport === "event");
	const needsFunctionAssert = model.remotes.some((remote) => remote.clientCallable && remote.transport === "function");
	const helperLines = [];

	if (needsEventAssert) {
		helperLines.push(
			"local function assertRemoteEvent(remote: RemoteEventLike, remoteName: string)",
			"\tif remote == nil or type(remote.FireServer) ~= \"function\" then",
			"\t\terror(remoteName .. \" expects a RemoteEvent-like value with FireServer\", 3)",
			"\tend",
			"end",
			""
		);
	}
	if (needsFunctionAssert) {
		helperLines.push(
			"local function assertRemoteFunction(remote: RemoteFunctionLike, remoteName: string)",
			"\tif remote == nil or type(remote.InvokeServer) ~= \"function\" then",
			"\t\terror(remoteName .. \" expects a RemoteFunction-like value with InvokeServer\", 3)",
			"\tend",
			"end",
			""
		);
	}
	return helperLines;
}

function generateClientModule(contract, options) {
	const model = contractModel(contract, options);
	const fingerprint = artifactFingerprint({
		kind: "remote-client",
		contract,
	});
	const functions = model.remotes
		.map((remote) => clientFunction(contract, remote))
		.filter(Boolean);
	const aliases = clientAliases(contract, model);

	const contents = [
		generatedHeader("remote-client", fingerprint),
		emitRemoteTypes(contract, options),
		aliases.length > 0 ? aliases.join("\n") : "",
		aliases.length > 0 ? "" : "",
		"local Client = {}",
		"",
		...clientAssertHelpers(model),
		functions.length > 0 ? functions.join("\n\n") : "-- No server-directed remotes are declared on this contract.",
		"",
		"return Client",
		"",
	].join("\n");

	return {
		path: path.join(options.outDir, `${model.clientModuleName}.luau`),
		contents,
	};
}

module.exports = {
	generateClientModule,
};
