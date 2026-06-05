"use strict";

const path = require("node:path");

function normalizePath(value) {
	return value.split(path.sep).join("/").replace(/^\.\//, "");
}

function escapeRegex(character) {
	return character.replace(/[|\\{}()[\]^$+?.]/g, "\\$&");
}

function normalizePattern(pattern) {
	const normalized = normalizePath(String(pattern || ""));
	if (normalized === "") {
		return "**";
	}
	if (!normalized.includes("/")) {
		return `**/${normalized}`;
	}
	return normalized;
}

function globToRegExp(pattern) {
	const source = normalizePattern(pattern);
	let expression = "^";

	for (let index = 0; index < source.length; index += 1) {
		const character = source[index];
		const next = source[index + 1];

		if (character === "*" && next === "*") {
			index += 1;
			if (source[index + 1] === "/") {
				expression += "(?:.*/)?";
				index += 1;
			} else {
				expression += ".*";
			}
		} else if (character === "*") {
			expression += "[^/]*";
		} else if (character === "?") {
			expression += "[^/]";
		} else {
			expression += escapeRegex(character);
		}
	}

	return new RegExp(`${expression}$`);
}

function compilePatterns(patterns) {
	return patterns.map((pattern) => globToRegExp(pattern));
}

function matchesAny(relativePath, matchers) {
	const normalized = normalizePath(relativePath);
	return matchers.some((matcher) => matcher.test(normalized));
}

module.exports = {
	compilePatterns,
	globToRegExp,
	matchesAny,
	normalizePath,
};
