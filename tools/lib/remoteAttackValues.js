"use strict";

const { luaExpression, luaLiteral: encodeLuaLiteral, quote } = require("./luaLiteral");

// Multiline, JSON-string, spaced-array encoding that also honors the
// { __luauExpression } raw-source escape hatch, with "nil" for unknown types.
function luaLiteral(value, indent = "") {
	return encodeLuaLiteral(value, indent, {
		onUnknown: "nil",
		allowExpression: true,
		stringStyle: "json",
		array: "spaced",
		object: "multiline",
	});
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

function invalidResponseValue(schema) {
	return invalidValue(schema || { kind: "object" });
}

function cloneJson(value) {
	return JSON.parse(JSON.stringify(value));
}

function cloneAttackValue(value) {
	if (value == null || typeof value !== "object") {
		return value;
	}
	if (value.__luauExpression != null) {
		return value;
	}
	if (Array.isArray(value)) {
		return value.map(cloneAttackValue);
	}
	const copy = {};
	for (const [key, child] of Object.entries(value)) {
		copy[key] = cloneAttackValue(child);
	}
	return copy;
}

function stringOverflowExpression(schema) {
	const length = schema.maxLength != null ? schema.maxLength + 1 : 10000;
	return luaExpression(`largeString(${Math.max(length, 1)})`);
}

function pathologicalValue(schema) {
	if (schema == null) return null;
	if (schema.kind === "string") return stringOverflowExpression(schema);
	if (schema.kind === "number" || schema.kind === "integer") return luaExpression("math.huge");
	if (schema.kind === "array") return luaExpression("largeArray(256)");
	if (schema.kind === "object") return luaExpression("deepTable(80)");
	if (schema.kind === "vector3") return luaExpression("{ X = math.huge, Y = 0, Z = 0 }");
	if (schema.kind === "optional") return pathologicalValue(schema.schema);
	return null;
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

	cases.push({
		name: "missing payload",
		payload: null,
	});
	cases.push({
		name: "wrong payload type",
		payload: invalidValue(schema),
	});

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

		const pathological = pathologicalValue(child);
		if (pathological != null) {
			const pathologicalPayload = cloneAttackValue(valid);
			pathologicalPayload[key] = pathological;
			cases.push({
				name: `pathological ${key}`,
				payload: pathologicalPayload,
			});
		}
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

module.exports = {
	cloneJson,
	invalidResponseValue,
	invalidValue,
	luaLiteral,
	payloadCases,
	quote,
	validValue,
};
