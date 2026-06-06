"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { renderPatchOpening } = require("./remoteMigrationSuggestions");

function hasContractsBinding(source) {
	return /\blocal\s+Contracts\s*=\s*require\b/.test(source);
}

function insertionIndex(source) {
	const strictMatch = source.match(/^--!(?:strict|nocheck|nonstrict)[^\n]*(?:\r?\n|$)/);
	return strictMatch ? strictMatch[0].length : 0;
}

function requireTarget(requirePath) {
	const value = String(requirePath);
	if (value.startsWith("lua:")) {
		return value.slice(4);
	}
	return JSON.stringify(value);
}

function contractsRequireLine(requirePath) {
	return `local Contracts = require(${requireTarget(requirePath)})\n`;
}

function insertContractsRequire(source, requirePath) {
	if (hasContractsBinding(source)) {
		return source;
	}
	const index = insertionIndex(source);
	return `${source.slice(0, index)}${contractsRequireLine(requirePath)}${source.slice(index)}`;
}

function editsForFinding(finding, options) {
	const edits = [{
		start: finding.start,
		end: finding.end,
		replacement: renderPatchOpening(finding, options),
	}];
	if (finding.handlerKind === "function" && finding.closeStart != null && finding.closeEnd != null) {
		edits.push({
			start: finding.closeStart,
			end: finding.closeEnd,
			replacement: "end)",
		});
	}
	return edits.sort((left, right) => right.start - left.start);
}

function applyEdits(source, edits) {
	let patched = source;
	for (const edit of edits) {
		patched = `${patched.slice(0, edit.start)}${edit.replacement}${patched.slice(edit.end)}`;
	}
	return patched;
}

function patchFinding(source, finding, options) {
	return applyEdits(source, editsForFinding(finding, options));
}

function canPatchFinding(source, finding, options) {
	if (!finding.patchable) {
		return "handler shape is not safely auto-patchable";
	}
	if (!hasContractsBinding(source) && !options.contractsRequire) {
		return "pass --contracts-require so the patcher can insert a Contracts require";
	}
	return null;
}

function applyFilePatches(projectRoot, filePath, findings, options) {
	const absolutePath = path.resolve(projectRoot, filePath);
	const original = fs.readFileSync(absolutePath, "utf8");
	let source = original;
	const patches = [];

	const sortedFindings = findings.slice().sort((left, right) => right.start - left.start);
	for (const finding of sortedFindings) {
		const reason = canPatchFinding(original, finding, options);
		if (reason) {
			patches.push({
				status: "skipped",
				filePath,
				line: finding.line,
				remoteName: finding.remoteName,
				reason,
			});
			continue;
		}

		source = patchFinding(source, finding, options);
		patches.push({
			status: options.write ? "patched" : "would-patch",
			filePath,
			line: finding.line,
			remoteName: finding.remoteName,
		});
	}

	if (source !== original && options.contractsRequire) {
		source = insertContractsRequire(source, options.contractsRequire);
	}
	if (source !== original && options.write) {
		fs.writeFileSync(absolutePath, source);
	}

	return patches.reverse();
}

function applyMigrationPatches(projectRoot, findings, options = {}) {
	const grouped = new Map();
	for (const finding of findings || []) {
		if (!grouped.has(finding.filePath)) {
			grouped.set(finding.filePath, []);
		}
		grouped.get(finding.filePath).push(finding);
	}

	const patches = [];
	for (const [filePath, fileFindings] of grouped.entries()) {
		patches.push(...applyFilePatches(projectRoot, filePath, fileFindings, options));
	}

	return patches;
}

module.exports = {
	applyMigrationPatches,
	hasContractsBinding,
};
