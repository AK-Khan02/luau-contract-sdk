"use strict";

function quote(value) {
	return JSON.stringify(String(value));
}

function fieldSchemaExpression(field) {
	if (field.kind === "boolean") return "Contracts.boolean()";
	if (field.kind === "integer") return "Contracts.integer()";
	if (field.kind === "number") return "Contracts.number()";
	if (field.kind === "string") return "Contracts.string()";
	if (field.kind === "stringId") return "Contracts.stringId()";
	if (field.kind === "table") return "Contracts.object({}, { allowExtra = true })";
	if (field.kind === "vector3") return "Contracts.vector3()";
	return "Contracts.any()";
}

function renderInputSchema(fields, options = {}) {
	const allowExtra = options.allowExtra === true;
	const indent = options.indent || "";
	const shapeIndent = `${indent}\t`;
	const children = fields || [];

	if (children.length === 0) {
		return "Contracts.any()";
	}

	const lines = [
		"Contracts.object({",
		...children.map((field) => `${shapeIndent}${field.name} = ${fieldSchemaExpression(field)},`),
		`${indent}}, {`,
		`${shapeIndent}allowExtra = ${allowExtra ? "true" : "false"},`,
		`${indent}})`,
	];
	return lines.join("\n");
}

function renderOptionsTable(finding, options = {}) {
	const indent = options.indent || "";
	const childIndent = `${indent}\t`;
	const allowExtra = options.allowExtra === true;
	const input = renderInputSchema(finding.inferredFields, {
		allowExtra,
		indent: childIndent,
	});
	const lines = [
		"{",
		`${childIndent}name = ${quote(finding.remoteName)},`,
		`${childIndent}input = ${input},`,
	];

	if (finding.handlerKind === "function") {
		lines.push(`${childIndent}kind = "function",`);
		lines.push(`${childIndent}output = Contracts.any(),`);
	}

	lines.push(`${indent}}`);
	return lines.join("\n");
}

function renderGuardRemoteSuggestion(finding) {
	const indent = "";
	return [
		`Contracts.guardRemote(${finding.remoteExpression}, ${renderOptionsTable(finding, {
			allowExtra: false,
			indent,
		})}, function(${finding.argsText})`,
		"\t-- move the existing handler body here",
		finding.handlerKind === "function" ? "end)" : "end)",
	].join("\n");
}

function renderPatchOpening(finding, options = {}) {
	const indent = finding.indent || "";
	return `${indent}Contracts.guardRemote(${finding.remoteExpression}, ${renderOptionsTable(finding, {
		allowExtra: options.strictPayload !== true,
		indent,
	})}, function(${finding.argsText})`;
}

function textReport(report) {
	const lines = [
		`Remote migration scan`,
		`findings=${report.summary.findingCount} patchable=${report.summary.patchableCount || 0}`,
	];

	for (const finding of report.findings || []) {
		lines.push(`${finding.filePath}:${finding.line}:${finding.column} ${finding.remoteName}.${finding.handlerKind} payload=${finding.payloadName || "_none_"}`);
		if (report.mode !== "scan" && finding.suggestedContract) {
			lines.push(finding.suggestedContract);
		}
	}

	for (const patch of report.patches || []) {
		lines.push(`${patch.status} ${patch.filePath}:${patch.line || 1} ${patch.reason || ""}`.trim());
	}

	return `${lines.join("\n")}\n`;
}

function markdownCell(value) {
	return String(value ?? "")
		.replace(/\\/g, "\\\\")
		.replace(/\|/g, "\\|")
		.replace(/\r?\n/g, " ");
}

function markdownReport(report) {
	const lines = [
		"# Remote Migration Report",
		"",
		"## Summary",
		"",
		`- Findings: ${report.summary.findingCount}`,
		`- Patchable: ${report.summary.patchableCount || 0}`,
		`- Patched: ${report.summary.patchedCount || 0}`,
		"",
		"## Raw Remote Handlers",
		"",
	];

	if ((report.findings || []).length === 0) {
		lines.push("_No raw remote handlers found._", "");
	} else {
		lines.push("| Location | Remote | Kind | Inferred payload fields | Patchable |");
		lines.push("| --- | --- | --- | --- | --- |");
		for (const finding of report.findings) {
			const fields = finding.inferredFields.map((field) => `${field.name}:${field.kind}`).join(", ") || "_none_";
			lines.push(`| ${markdownCell(`${finding.filePath}:${finding.line}`)} | ${markdownCell(finding.remoteName)} | ${markdownCell(finding.handlerKind)} | ${markdownCell(fields)} | ${finding.patchable ? "yes" : "no"} |`);
		}
		lines.push("");
	}

	if (report.mode !== "scan" && (report.findings || []).some((finding) => finding.suggestedContract)) {
		lines.push("## Suggested Wrappers", "");
		for (const finding of report.findings) {
			if (!finding.suggestedContract) continue;
			lines.push(`### ${finding.remoteName}`, "");
			lines.push("```lua");
			lines.push(finding.suggestedContract);
			lines.push("```", "");
		}
	}

	if ((report.patches || []).length > 0) {
		lines.push("## Patches", "");
		lines.push("| Status | Location | Reason |");
		lines.push("| --- | --- | --- |");
		for (const patch of report.patches) {
			lines.push(`| ${markdownCell(patch.status)} | ${markdownCell(`${patch.filePath}:${patch.line || 1}`)} | ${markdownCell(patch.reason || "")} |`);
		}
		lines.push("");
	}

	return `${lines.join("\n")}\n`;
}

function renderMigrationReport(report, format) {
	if (format === "json") {
		return `${JSON.stringify(report, null, 2)}\n`;
	}
	if (format === "markdown" || format === "md") {
		return markdownReport(report);
	}
	if (format === "text") {
		return textReport(report);
	}
	throw new Error(`Unknown migration report format: ${format}`);
}

module.exports = {
	renderGuardRemoteSuggestion,
	renderMigrationReport,
	renderOptionsTable,
	renderPatchOpening,
};
