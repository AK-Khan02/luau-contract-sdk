"use strict";

function stableValue(value) {
	if (value == null || typeof value !== "object") {
		return value;
	}
	if (Array.isArray(value)) {
		return value.map((child) => stableValue(child));
	}

	const output = {};
	for (const key of Object.keys(value).sort()) {
		const child = value[key];
		if (child !== undefined) {
			output[key] = stableValue(child);
		}
	}
	return output;
}

function stableStringify(value) {
	return JSON.stringify(stableValue(value));
}

module.exports = {
	stableStringify,
	stableValue,
};
