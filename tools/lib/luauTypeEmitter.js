"use strict";

const { sanitizeIdentifier } = require("./contractArtifacts");

function sortedEntries(value) {
	return Object.entries(value || {}).sort(([left], [right]) => left.localeCompare(right));
}

function quoteString(value) {
	return JSON.stringify(String(value));
}

function isIdentifier(value) {
	return /^[A-Za-z_][A-Za-z0-9_]*$/.test(value);
}

function fieldKey(value) {
	return isIdentifier(value) ? value : `[${quoteString(value)}]`;
}

function literalType(value) {
	if (typeof value === "string") {
		return quoteString(value);
	}
	if (typeof value === "boolean") {
		return value ? "true" : "false";
	}
	if (typeof value === "number" && Number.isFinite(value)) {
		return String(value);
	}
	return "any";
}

function isOptionalSchema(schema) {
	return schema?.kind === "optional";
}

function emitObject(schema, options) {
	const lines = ["{"];
	for (const [key, childSchema] of sortedEntries(schema.shape)) {
		const optional = isOptionalSchema(childSchema);
		const childType = emitType(optional ? childSchema.schema : childSchema, options);
		lines.push(`\t${fieldKey(key)}${optional ? "?" : ""}: ${childType},`);
	}
	if (schema.allowExtra === true) {
		lines.push("\t[string]: any,");
	}
	lines.push("}");
	return lines.join("\n");
}

function emitType(schema, options = {}) {
	if (schema == null) {
		return "any";
	}

	if (schema.kind === "any" || schema.kind === "custom") {
		if (schema.kind === "custom" && options.customTypes && options.customTypes[schema.name]) {
			return options.customTypes[schema.name];
		}
		return "any";
	}
	if (schema.kind === "boolean") {
		return "boolean";
	}
	if (schema.kind === "number" || schema.kind === "integer") {
		return "number";
	}
	if (schema.kind === "string") {
		return "string";
	}
	if (schema.kind === "vector3") {
		return options.vector3Type || "any";
	}
	if (schema.kind === "oneOf") {
		const values = (schema.values || []).map(literalType);
		return values.length > 0 ? values.join(" | ") : "any";
	}
	if (schema.kind === "literal") {
		return literalType(schema.expected);
	}
	if (schema.kind === "optional") {
		return `${emitType(schema.schema, options)}?`;
	}
	if (schema.kind === "array") {
		return `{${emitType(schema.schema, options)}}`;
	}
	if (schema.kind === "object") {
		return emitObject(schema, options);
	}
	return "any";
}

function typeNameFor(systemName, remoteName, suffix) {
	return `${sanitizeIdentifier(systemName)}${sanitizeIdentifier(remoteName)}${suffix}`;
}

function emitRemoteTypes(contract, options = {}) {
	const blocks = [];
	for (const remote of contract.remotes) {
		blocks.push(`export type ${typeNameFor(contract.name, remote.remoteName, "Payload")} = ${emitType(remote.payload, options)}`);
		if (remote.response != null) {
			blocks.push(`export type ${typeNameFor(contract.name, remote.remoteName, "Response")} = ${emitType(remote.response, options)}`);
		}
	}
	return `${blocks.join("\n\n")}\n`;
}

module.exports = {
	emitRemoteTypes,
	emitType,
	typeNameFor,
};
