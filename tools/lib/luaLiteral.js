"use strict";

// Canonical JS-value -> Luau-source-literal encoder.
//
// Three call sites historically carried their own copy of this logic with
// subtly different output. This module unifies them behind one function whose
// `options` reproduce each prior behavior byte-for-byte:
//
//   * remoteWrapperGenerator.js  -> { stringStyle: "json",   array: "spaced",  object: "multiline", onUnknown: "nil" }
//   * remoteAttackValues.js      -> { stringStyle: "json",   array: "spaced",  object: "multiline", onUnknown: "nil", allowExpression: true }
//   * luauRunner.js              -> { stringStyle: "bracket", array: "compact", object: "compactSorted", onUnknown: "throw", finiteNumbers: true }
//
// Options:
//   onUnknown        "nil" | "throw"  – how to render functions/symbols/bigints (default "nil")
//   allowExpression  boolean          – honor the { __luauExpression } raw-source escape hatch (default false)
//   stringStyle      "json" | "bracket" – string encoding (default "json")
//   array            "spaced" | "compact" – array brace spacing (default "spaced")
//   object           "multiline" | "compactSorted" – table layout (default "multiline")
//   finiteNumbers    boolean          – throw on non-finite numbers (default false)

const DEFAULT_OPTIONS = {
	onUnknown: "nil",
	allowExpression: false,
	stringStyle: "json",
	array: "spaced",
	object: "multiline",
	finiteNumbers: false,
};

function isIdentifier(value) {
	return /^[A-Za-z_][A-Za-z0-9_]*$/.test(value);
}

function quote(value) {
	return JSON.stringify(String(value));
}

// Long-bracket string form: [[text]], escalating the `=` level until the
// closing delimiter does not appear inside the payload.
function luaBracketString(value) {
	const text = String(value);
	let level = 0;
	while (text.includes(`]${"=".repeat(level)}]`)) {
		level += 1;
	}
	return `[${"=".repeat(level)}[${text}]${"=".repeat(level)}]`;
}

function encodeString(value, options) {
	return options.stringStyle === "bracket" ? luaBracketString(value) : quote(value);
}

function encodeNumber(value, options) {
	if (options.finiteNumbers && !Number.isFinite(value)) {
		throw new Error("Cannot encode non-finite number as Luau literal");
	}
	return String(value);
}

function encodeArray(value, indent, options) {
	const children = value.map((child) => luaLiteral(child, indent, options));
	if (options.array === "compact") {
		return `{${children.join(",")}}`;
	}
	return `{ ${children.join(", ")} }`;
}

// Single-line table with sorted keys and dropped `undefined` values, rendered
// as `[ <string-key> ]=<value>` (matches the historical luauRunner output).
function encodeCompactSortedObject(value, indent, options) {
	const entries = Object.entries(value)
		.filter(([, child]) => child !== undefined)
		.sort(([left], [right]) => left.localeCompare(right))
		.map(([key, child]) => `[ ${encodeString(key, options)} ]=${luaLiteral(child, indent, options)}`);
	return `{${entries.join(",")}}`;
}

// Multi-line, tab-indented table preserving insertion order and keeping
// `undefined` entries (matches the historical wrapper/attack output).
function encodeMultilineObject(value, indent, options) {
	const entries = Object.entries(value);
	if (entries.length === 0) {
		return "{}";
	}
	const childIndent = `${indent}\t`;
	const lines = ["{"];
	for (const [key, child] of entries) {
		const keyText = isIdentifier(key) ? key : `[${quote(key)}]`;
		lines.push(`${childIndent}${keyText} = ${luaLiteral(child, childIndent, options)},`);
	}
	lines.push(`${indent}}`);
	return lines.join("\n");
}

function encodeObject(value, indent, options) {
	return options.object === "compactSorted"
		? encodeCompactSortedObject(value, indent, options)
		: encodeMultilineObject(value, indent, options);
}

function luaLiteral(value, indent = "", options) {
	const opts = options ? { ...DEFAULT_OPTIONS, ...options } : DEFAULT_OPTIONS;

	if (value == null) {
		return "nil";
	}
	if (opts.allowExpression && typeof value === "object" && value.__luauExpression != null) {
		return value.__luauExpression;
	}
	if (typeof value === "string") {
		return encodeString(value, opts);
	}
	if (typeof value === "number") {
		return encodeNumber(value, opts);
	}
	if (typeof value === "boolean") {
		return value ? "true" : "false";
	}
	if (Array.isArray(value)) {
		return encodeArray(value, indent, opts);
	}
	if (typeof value === "object") {
		return encodeObject(value, indent, opts);
	}
	if (opts.onUnknown === "throw") {
		throw new Error(`Cannot encode ${typeof value} as Luau literal`);
	}
	return "nil";
}

// Wrap raw Luau source so it is emitted verbatim by encoders that opt into
// `allowExpression`.
function luaExpression(source) {
	return {
		__luauExpression: source,
	};
}

module.exports = {
	luaLiteral,
	luaExpression,
	luaBracketString,
	isIdentifier,
	quote,
};
