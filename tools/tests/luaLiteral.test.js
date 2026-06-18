"use strict";

const assert = require("node:assert");
const test = require("node:test");
const { luaLiteral, luaExpression, luaBracketString, quote } = require("../lib/luaLiteral");

// Option presets mirroring the three original call sites.
const wrapperOptions = {
	onUnknown: "nil",
	stringStyle: "json",
	array: "spaced",
	object: "multiline",
};
const attackOptions = { ...wrapperOptions, allowExpression: true };
const runnerOptions = {
	onUnknown: "throw",
	stringStyle: "bracket",
	array: "compact",
	object: "compactSorted",
	finiteNumbers: true,
};

test("defaults encode nil for null and undefined", () => {
	assert.equal(luaLiteral(null), "nil");
	assert.equal(luaLiteral(undefined), "nil");
});

test("json string style escapes quotes, newlines, and backslashes", () => {
	assert.equal(luaLiteral("plain", "", wrapperOptions), "\"plain\"");
	assert.equal(luaLiteral("with \"quotes\"", "", wrapperOptions), "\"with \\\"quotes\\\"\"");
	assert.equal(luaLiteral("line\nbreak", "", wrapperOptions), "\"line\\nbreak\"");
	assert.equal(luaLiteral("back\\slash", "", wrapperOptions), "\"back\\\\slash\"");
});

test("bracket string style uses escalating long-bracket delimiters", () => {
	assert.equal(luaLiteral("hello", "", runnerOptions), "[[hello]]");
	// A payload containing ]] forces the next bracket level.
	assert.equal(luaLiteral("has ]] inside", "", runnerOptions), "[=[has ]] inside]=]");
	assert.equal(luaBracketString("plain"), "[[plain]]");
	// Newlines and quotes pass through verbatim in long-bracket form.
	assert.equal(luaLiteral("a\nb\"c", "", runnerOptions), "[[a\nb\"c]]");
});

test("numbers render directly and respect the finite guard", () => {
	assert.equal(luaLiteral(42, "", wrapperOptions), "42");
	assert.equal(luaLiteral(-3.5, "", wrapperOptions), "-3.5");
	assert.equal(luaLiteral(0, "", runnerOptions), "0");
	// Without the guard, non-finite numbers stringify (legacy wrapper/attack behavior).
	assert.equal(luaLiteral(Infinity, "", wrapperOptions), "Infinity");
	assert.equal(luaLiteral(NaN, "", wrapperOptions), "NaN");
	// With the guard, they throw (legacy runner behavior).
	assert.throws(() => luaLiteral(Infinity, "", runnerOptions), /non-finite number/);
	assert.throws(() => luaLiteral(NaN, "", runnerOptions), /non-finite number/);
});

test("booleans render as Luau keywords", () => {
	assert.equal(luaLiteral(true, "", wrapperOptions), "true");
	assert.equal(luaLiteral(false, "", wrapperOptions), "false");
	assert.equal(luaLiteral(true, "", runnerOptions), "true");
	assert.equal(luaLiteral(false, "", runnerOptions), "false");
});

test("spaced arrays add interior spacing, compact arrays do not", () => {
	assert.equal(luaLiteral([1, 2, 3], "", wrapperOptions), "{ 1, 2, 3 }");
	assert.equal(luaLiteral([], "", wrapperOptions), "{  }");
	assert.equal(luaLiteral([1, 2, 3], "", runnerOptions), "{1,2,3}");
	assert.equal(luaLiteral([], "", runnerOptions), "{}");
});

test("multiline objects indent with tabs and keep insertion order", () => {
	const out = luaLiteral({ b: 1, a: "x" }, "", wrapperOptions);
	assert.equal(out, "{\n\tb = 1,\n\ta = \"x\",\n}");
	// Empty objects collapse to {}.
	assert.equal(luaLiteral({}, "", wrapperOptions), "{}");
	// Non-identifier keys are bracket-quoted.
	assert.equal(luaLiteral({ "weird key": 1 }, "", wrapperOptions), "{\n\t[\"weird key\"] = 1,\n}");
});

test("multiline objects nest with the running indent", () => {
	const out = luaLiteral({ outer: { inner: 1 } }, "", wrapperOptions);
	assert.equal(out, "{\n\touter = {\n\t\tinner = 1,\n\t},\n}");
});

test("compactSorted objects sort keys, drop undefined, and bracket-quote keys", () => {
	const out = luaLiteral({ b: 1, a: 2 }, "", runnerOptions);
	assert.equal(out, "{[ [[a]] ]=2,[ [[b]] ]=1}");
	// undefined children are dropped entirely.
	assert.equal(luaLiteral({ keep: 1, skip: undefined }, "", runnerOptions), "{[ [[keep]] ]=1}");
});

test("allowExpression honors the __luauExpression escape hatch", () => {
	assert.equal(luaLiteral(luaExpression("math.huge"), "", attackOptions), "math.huge");
	assert.equal(
		luaLiteral({ value: luaExpression("largeString(10)") }, "", attackOptions),
		"{\n\tvalue = largeString(10),\n}",
	);
	// Arrays still render as arrays even though they are objects.
	assert.equal(luaLiteral([luaExpression("x")], "", attackOptions), "{ x }");
});

test("without allowExpression the escape object is treated as a plain table", () => {
	assert.equal(
		luaLiteral({ __luauExpression: "math.huge" }, "", wrapperOptions),
		"{\n\t__luauExpression = \"math.huge\",\n}",
	);
});

test("onUnknown nil returns nil for functions and symbols", () => {
	assert.equal(luaLiteral(() => {}, "", wrapperOptions), "nil");
	assert.equal(luaLiteral(Symbol("s"), "", wrapperOptions), "nil");
});

test("onUnknown throw raises for functions and other unencodable types", () => {
	assert.throws(() => luaLiteral(() => {}, "", runnerOptions), /Cannot encode function/);
	assert.throws(() => luaLiteral(Symbol("s"), "", runnerOptions), /Cannot encode symbol/);
});

test("quote helper stringifies via JSON", () => {
	assert.equal(quote("a\"b"), "\"a\\\"b\"");
	assert.equal(quote(7), "\"7\"");
});
