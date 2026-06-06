"use strict";

const { renderGuardRemoteSuggestion } = require("./remoteMigrationSuggestions");

const EVENT_HANDLER = /([A-Za-z_][A-Za-z0-9_\.]*)\.OnServerEvent\s*:\s*Connect\s*\(\s*function\s*\(([^)]*)\)/g;
const FUNCTION_HANDLER = /([A-Za-z_][A-Za-z0-9_\.]*)\.OnServerInvoke\s*=\s*function\s*\(([^)]*)\)/g;

function escapeRegExp(value) {
	return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function locationForIndex(source, index) {
	const before = source.slice(0, index);
	const lines = before.split(/\r\n|\r|\n/);
	return {
		line: lines.length,
		column: lines[lines.length - 1].length + 1,
	};
}

function lineStart(source, index) {
	const start = source.lastIndexOf("\n", index);
	return start === -1 ? 0 : start + 1;
}

function leadingIndent(source, index) {
	const start = lineStart(source, index);
	const linePrefix = source.slice(start, index);
	const match = linePrefix.match(/^\s*/);
	return match ? match[0] : "";
}

function lineBounds(source, index) {
	const start = lineStart(source, index);
	const end = source.indexOf("\n", index);
	return {
		start,
		end: end === -1 ? source.length : end,
	};
}

function codeOnly(line) {
	return line.replace(/--.*$/, "");
}

function tokenMatches(line) {
	return codeOnly(line).match(/\b(function|then|do|repeat|end|until)\b/g) || [];
}

function findFunctionClose(source, openingEnd) {
	let depth = 1;
	let cursor = lineBounds(source, openingEnd).end + 1;

	while (cursor > 0 && cursor < source.length) {
		const bounds = lineBounds(source, cursor);
		const line = source.slice(bounds.start, bounds.end);
		const tokens = tokenMatches(line);
		for (const token of tokens) {
			if (token === "function" || token === "then" || token === "do" || token === "repeat") {
				depth += 1;
			} else if (token === "end" || token === "until") {
				depth -= 1;
				if (depth === 0 && token === "end") {
					const endOffset = line.indexOf("end");
					const endStart = bounds.start + endOffset;
					return {
						start: endStart,
						end: endStart + 3,
					};
				}
			}
		}
		cursor = bounds.end + 1;
	}
	return null;
}

function normalizeArgName(value) {
	const name = String(value || "").trim().split(":")[0].trim();
	return /^[A-Za-z_][A-Za-z0-9_]*$/.test(name) ? name : null;
}

function parseArgs(argsText) {
	return String(argsText || "")
		.split(",")
		.map(normalizeArgName)
		.filter(Boolean);
}

function remoteNameFromExpression(expression) {
	const parts = String(expression).split(".");
	return parts[parts.length - 1] || expression;
}

function firstFieldUse(source, payloadName, fieldName) {
	const escapedPayload = escapeRegExp(payloadName);
	const escapedField = escapeRegExp(fieldName);
	const dot = new RegExp(`${escapedPayload}\\s*\\.\\s*${escapedField}\\b`);
	const bracket = new RegExp(`${escapedPayload}\\s*\\[\\s*["']${escapedField}["']\\s*\\]`);
	const dotIndex = source.search(dot);
	const bracketIndex = source.search(bracket);
	if (dotIndex === -1) return bracketIndex;
	if (bracketIndex === -1) return dotIndex;
	return Math.min(dotIndex, bracketIndex);
}

function hasPattern(source, pattern) {
	return pattern.test(source);
}

function inferFieldKind(source, payloadName, fieldName) {
	const payload = escapeRegExp(payloadName);
	const field = escapeRegExp(fieldName);
	const access = `${payload}\\s*(?:\\.\\s*${field}|\\[\\s*["']${field}["']\\s*\\])`;

	if (hasPattern(source, new RegExp(`type\\s*\\(\\s*${access}\\s*\\)\\s*==\\s*["']boolean["']`))) {
		return "boolean";
	}
	if (hasPattern(source, new RegExp(`type\\s*\\(\\s*${access}\\s*\\)\\s*==\\s*["']number["']`))) {
		return fieldName.match(/(Amount|Count|Index|Level|Quantity|Revision)$/) ? "integer" : "number";
	}
	if (hasPattern(source, new RegExp(`type\\s*\\(\\s*${access}\\s*\\)\\s*==\\s*["']string["']`))) {
		return fieldName.match(/(Id|ID)$/) ? "stringId" : "string";
	}
	if (hasPattern(source, new RegExp(`type\\s*\\(\\s*${access}\\s*\\)\\s*==\\s*["']table["']`))) {
		return "table";
	}
	if (hasPattern(source, new RegExp(`typeof\\s*\\(\\s*${access}\\s*\\)\\s*==\\s*["']Vector3["']`))) {
		return "vector3";
	}
	if (hasPattern(source, new RegExp(`tonumber\\s*\\(\\s*${access}\\s*\\)`))) {
		return "number";
	}
	if (hasPattern(source, new RegExp(`${access}\\s*[+\\-*/%]`)) || hasPattern(source, new RegExp(`[+\\-*/%]\\s*${access}`))) {
		return "number";
	}
	if (fieldName.match(/(Id|ID)$/)) {
		return "stringId";
	}
	if (fieldName.match(/(Amount|Count|Index|Level|Quantity|Revision)$/)) {
		return "integer";
	}
	return "any";
}

function inferPayloadFields(source, payloadName) {
	if (!payloadName) {
		return [];
	}

	const fields = new Map();
	const payload = escapeRegExp(payloadName);
	const patterns = [
		new RegExp(`${payload}\\s*\\.\\s*([A-Za-z_][A-Za-z0-9_]*)`, "g"),
		new RegExp(`${payload}\\s*\\[\\s*["']([^"']+)["']\\s*\\]`, "g"),
	];

	for (const pattern of patterns) {
		let match;
		while ((match = pattern.exec(source)) !== null) {
			const name = match[1];
			if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) {
				continue;
			}
			if (!fields.has(name)) {
				fields.set(name, {
					name,
					firstUse: firstFieldUse(source, payloadName, name),
				});
			}
		}
	}

	return [...fields.values()]
		.sort((left, right) => left.firstUse - right.firstUse || left.name.localeCompare(right.name))
		.map((field) => ({
			name: field.name,
			kind: inferFieldKind(source, payloadName, field.name),
		}));
}

function buildFinding(script, match, handlerKind) {
	const remoteExpression = match[1];
	const argsText = match[2].trim();
	const args = parseArgs(argsText);
	const payloadName = args[1] || null;
	const location = locationForIndex(script.source, match.index);
	const finding = {
		ruleId: "raw-remote-migration",
		filePath: script.filePath,
		path: script.path,
		line: location.line,
		column: location.column,
		start: match.index,
		end: match.index + match[0].length,
		indent: leadingIndent(script.source, match.index),
		remoteExpression,
		remoteName: remoteNameFromExpression(remoteExpression),
		handlerKind,
		argsText,
		playerName: args[0] || null,
		payloadName,
		inferredFields: inferPayloadFields(script.source, payloadName),
		patchable: handlerKind === "event",
	};
	if (handlerKind === "function") {
		const close = findFunctionClose(script.source, finding.end);
		if (close != null) {
			finding.closeStart = close.start;
			finding.closeEnd = close.end;
			finding.patchable = true;
		}
	}
	finding.suggestedContract = renderGuardRemoteSuggestion(finding);
	return finding;
}

function scanScript(script) {
	const findings = [];
	for (const [pattern, handlerKind] of [
		[EVENT_HANDLER, "event"],
		[FUNCTION_HANDLER, "function"],
	]) {
		pattern.lastIndex = 0;
		let match;
		while ((match = pattern.exec(script.source)) !== null) {
			findings.push(buildFinding(script, match, handlerKind));
		}
	}
	return findings.sort((left, right) => left.start - right.start);
}

function scanRemoteMigrations(scripts) {
	const findings = [];
	for (const script of scripts) {
		findings.push(...scanScript(script));
	}

	return {
		summary: {
			findingCount: findings.length,
			patchableCount: findings.filter((finding) => finding.patchable).length,
		},
		findings,
	};
}

module.exports = {
	scanRemoteMigrations,
};
