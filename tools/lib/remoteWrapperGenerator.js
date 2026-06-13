"use strict";

const path = require("node:path");
const { artifactFingerprint } = require("./contractArtifacts");
const { emitRemoteTypes } = require("./luauTypeEmitter");
const { contractModel, manifestForContract } = require("./remoteContractModel");
const { generateClientModule } = require("./remoteWrapperClientGenerator");
const { GENERATED_HEADER, generatedHeader } = require("./remoteWrapperHeader");
const { generateServerModule } = require("./remoteWrapperServerGenerator");

function luaLiteral(value, indent = "") {
	if (value == null) {
		return "nil";
	}
	if (typeof value === "string") {
		return JSON.stringify(value);
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
			const keyText = /^[A-Za-z_][A-Za-z0-9_]*$/.test(key) ? key : `[${JSON.stringify(key)}]`;
			lines.push(`${childIndent}${keyText} = ${luaLiteral(child, childIndent)},`);
		}
		lines.push(`${indent}}`);
		return lines.join("\n");
	}
	return "nil";
}

function generateTypesModule(contract, options) {
	const model = contractModel(contract, options);
	const fingerprint = artifactFingerprint({
		kind: "remote-types",
		contract,
	});
	const contents = [
		generatedHeader("remote-types", fingerprint),
		emitRemoteTypes(contract, options),
		"return {}",
		"",
	].join("\n");

	return {
		path: path.join(options.outDir, `${model.typeModuleName}.luau`),
		contents,
	};
}

function generateManifestModule(contract, options) {
	const model = contractModel(contract, options);
	const fingerprint = artifactFingerprint({
		kind: "remote-manifest",
		contract,
	});
	const contents = [
		generatedHeader("remote-manifest", fingerprint),
		`return ${luaLiteral(manifestForContract(contract, options))}`,
		"",
	].join("\n");

	return {
		path: path.join(options.outDir, `${model.manifestModuleName}.luau`),
		contents,
	};
}

function wrapperOptions(options, outDir) {
	return {
		attackConfig: options.attackConfig || {},
		customTypes: options.customTypes || {},
		vector3Type: options.vector3Type || "any",
		outDir,
	};
}

function generateRemoteWrapperFiles(artifacts, options = {}) {
	const outDir = path.resolve(options.outDir);
	const typeOptions = wrapperOptions(options, outDir);
	const files = [];

	for (const contract of artifacts.contracts) {
		if (contract.remotes.length === 0) {
			continue;
		}
		files.push(generateTypesModule(contract, typeOptions));
		files.push(generateClientModule(contract, typeOptions));
		files.push(generateServerModule(contract, typeOptions));
		files.push(generateManifestModule(contract, typeOptions));
	}

	return files;
}

module.exports = {
	GENERATED_HEADER,
	generateRemoteWrapperFiles,
};
