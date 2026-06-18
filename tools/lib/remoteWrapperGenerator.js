"use strict";

const path = require("node:path");
const { artifactFingerprint } = require("./contractArtifacts");
const { luaLiteral: encodeLuaLiteral } = require("./luaLiteral");
const { emitRemoteTypes } = require("./luauTypeEmitter");
const { contractModel, manifestForContract } = require("./remoteContractModel");
const { generateClientModule } = require("./remoteWrapperClientGenerator");
const { GENERATED_HEADER, generatedHeader } = require("./remoteWrapperHeader");
const { generateServerModule } = require("./remoteWrapperServerGenerator");

// Multiline, JSON-string, spaced-array encoding with "nil" for unknown types.
function luaLiteral(value, indent = "") {
	return encodeLuaLiteral(value, indent, {
		onUnknown: "nil",
		stringStyle: "json",
		array: "spaced",
		object: "multiline",
	});
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
