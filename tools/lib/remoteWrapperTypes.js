"use strict";

const { typeNameFor } = require("./luauTypeEmitter");

function typeField(remoteName, typeName) {
	return /^[A-Za-z_][A-Za-z0-9_]*$/.test(remoteName)
		? `\t${remoteName}: ${typeName},`
		: `\t[${JSON.stringify(remoteName)}]: ${typeName},`;
}

function remoteTypeName(contract, remote, suffix) {
	return typeNameFor(contract.name, remote.remoteName, suffix);
}

function responseType(contract, remote) {
	return remote.outputSchema != null
		? typeNameFor(contract.name, remote.remoteName, "Response")
		: "any";
}

function clientRemoteAliasName(contract, remote) {
	return remoteTypeName(contract, remote, remote.transport === "function" ? "RemoteFunction" : "RemoteEvent");
}

function clientRemoteAlias(contract, remote) {
	const payloadType = typeNameFor(contract.name, remote.remoteName, "Payload");
	const aliasName = clientRemoteAliasName(contract, remote);
	if (remote.transport === "function") {
		return [
			`type ${aliasName} = {`,
			`\tInvokeServer: (${aliasName}, ${payloadType}) -> ${responseType(contract, remote)}?,`,
			"}",
		].join("\n");
	}
	return [
		`type ${aliasName} = {`,
		`\tFireServer: (${aliasName}, ${payloadType}) -> (),`,
		"}",
	].join("\n");
}

function serverRemoteAliasName(contract, remote) {
	return remoteTypeName(contract, remote, "ServerRemote");
}

function serverClientRemoteAliasName(contract, remote) {
	return remoteTypeName(contract, remote, "ClientRemoteEvent");
}

function runtimeHandlerAliasName(contract, remote) {
	return remoteTypeName(contract, remote, "RuntimeHandler");
}

function guardHandlerAliasName(contract, remote) {
	return remoteTypeName(contract, remote, "GuardHandler");
}

function serverRemoteAlias(remote) {
	return remote.transport === "function"
		? "ServerRemoteFunctionLike"
		: "ServerRemoteEventLike";
}

function serverAliasBlocks(contract, model) {
	const serverRemotes = model.remotes.filter((remote) => remote.serverBindable);
	const clientRemotes = model.remotes.filter((remote) => remote.serverCanFire);
	const lines = [
		"type PlayerLike = any",
		"type ConnectionLike = { Disconnect: (ConnectionLike) -> () }",
		"type ServerSignalLike = { Connect: (ServerSignalLike, (...any) -> any) -> ConnectionLike }",
		"type ServerRemoteEventLike = { OnServerEvent: ServerSignalLike }",
		"type ServerRemoteFunctionLike = { OnServerInvoke: any }",
		"type ServerRemote = ServerRemoteEventLike | ServerRemoteFunctionLike",
		"type ClientRemoteEventLike = { FireClient: (ClientRemoteEventLike, PlayerLike, any) -> () }",
		"type BindOptions = { handler: RuntimeHandler?, implementOptions: any?, [string]: any }",
		"type GuardOptions = { [string]: any }",
		"type RuntimeHandler = (...any) -> any",
		"type GuardHandler = (...any) -> any",
	];

	for (const remote of serverRemotes) {
		lines.push(`type ${serverRemoteAliasName(contract, remote)} = ${serverRemoteAlias(remote)}`);
		lines.push(`type ${runtimeHandlerAliasName(contract, remote)} = (any, any?) -> ${responseType(contract, remote)}?`);
		lines.push(`type ${guardHandlerAliasName(contract, remote)} = (PlayerLike, ${typeNameFor(contract.name, remote.remoteName, "Payload")}, any?) -> ${responseType(contract, remote)}?`);
	}
	for (const remote of clientRemotes) {
		const aliasName = serverClientRemoteAliasName(contract, remote);
		lines.push([
			`type ${aliasName} = {`,
			`\tFireClient: (${aliasName}, PlayerLike, ${typeNameFor(contract.name, remote.remoteName, "Payload")}) -> (),`,
			"}",
		].join("\n"));
	}

	lines.push("type Remotes = {");
	for (const remote of serverRemotes) {
		lines.push(typeField(remote.remoteName, serverRemoteAliasName(contract, remote)));
	}
	lines.push("}");

	lines.push("type RuntimeHandlers = {");
	for (const remote of serverRemotes) {
		lines.push(typeField(remote.remoteName, `${runtimeHandlerAliasName(contract, remote)}?`));
		if (remote.actionName !== remote.remoteName) {
			lines.push(typeField(remote.actionName, `${runtimeHandlerAliasName(contract, remote)}?`));
		}
	}
	lines.push("\t[string]: RuntimeHandler?,");
	lines.push("}");

	lines.push("type GuardHandlers = {");
	for (const remote of serverRemotes) {
		lines.push(typeField(remote.remoteName, `${guardHandlerAliasName(contract, remote)}?`));
		if (remote.actionName !== remote.remoteName) {
			lines.push(typeField(remote.actionName, `${guardHandlerAliasName(contract, remote)}?`));
		}
	}
	lines.push("\t[string]: GuardHandler?,");
	lines.push("}");

	lines.push("type RuntimeLike = {");
	lines.push("\timplement: (RuntimeLike, string, RuntimeHandler, BindOptions?) -> any,");
	lines.push("\tbindRemote: (RuntimeLike, string, ServerRemote, BindOptions?) -> any,");
	lines.push("}");
	lines.push("type RemoteGuardLike = { connect: (any, string, ServerRemote, GuardHandler, GuardOptions?) -> any }");
	lines.push("type ContractsLike = { Roblox: { RemoteGuard: RemoteGuardLike } }");

	return lines;
}

module.exports = {
	clientRemoteAlias,
	clientRemoteAliasName,
	guardHandlerAliasName,
	responseType,
	runtimeHandlerAliasName,
	serverAliasBlocks,
	serverClientRemoteAliasName,
};
