"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { decisionText } = require("./ciPolicy");

function findingRules(report) {
	return report?.scanner?.rules || {};
}

function textReport(report) {
	const summary = report.summary || {};
	const policy = report.policy || {};
	const lines = [
		`Luau Contract scan`,
		`scripts=${summary.scriptCount || 0} systems=${summary.systemCount || 0} contracts=${summary.contractCount || 0}`,
		`findings=${summary.scannerFindingCount || 0} errors=${summary.scannerErrors || 0} warnings=${summary.scannerWarnings || 0}`,
		`newFindings=${policy.newFindingCount || 0} baselineSuppressed=${policy.suppressedByBaseline || 0}`,
		decisionText(policy),
	];

	for (const error of report?.exact?.errors || []) {
		lines.push(`exact-error ${error.path}: ${error.message}`);
	}

	for (const finding of report?.scanner?.findings || []) {
		lines.push(`${finding.path}:${finding.line}:${finding.column} [${finding.severity}] ${finding.ruleId} ${finding.message}`);
	}

	return `${lines.join("\n")}\n`;
}

function sarifReport(report) {
	const rules = findingRules(report);
	const toolRules = Object.values(rules).map((rule) => {
		return {
			id: rule.id,
			name: rule.title || rule.id,
			shortDescription: { text: rule.title || rule.id },
			fullDescription: { text: rule.remediation || rule.title || rule.id },
			helpUri: rule.docs || undefined,
			properties: {
				category: rule.category,
				defaultSeverity: rule.severity,
			},
		};
	});

	const findingResults = (report?.scanner?.findings || []).map((finding) => {
		return {
			ruleId: finding.ruleId,
			level: finding.severity === "error" ? "error" : finding.severity === "warn" ? "warning" : "note",
			message: { text: finding.message },
			locations: [
				{
					physicalLocation: {
						artifactLocation: { uri: finding.path },
						region: {
							startLine: finding.line || 1,
							startColumn: finding.column || 1,
							snippet: { text: finding.snippet || "" },
						},
					},
				},
			],
		};
	});

	const exactResults = (report?.exact?.errors || []).map((error) => {
		return {
			ruleId: "exact-contract-load-error",
			level: "error",
			message: { text: error.message },
			locations: [
				{
					physicalLocation: {
						artifactLocation: { uri: error.path },
						region: { startLine: 1, startColumn: 1 },
					},
				},
			],
		};
	});

	return JSON.stringify({
		version: "2.1.0",
		$schema: "https://json.schemastore.org/sarif-2.1.0.json",
		runs: [
			{
				tool: {
					driver: {
						name: "Luau Contract SDK",
						informationUri: "https://create.roblox.com/docs",
						rules: toolRules.concat([
							{
								id: "exact-contract-load-error",
								name: "Exact contract load error",
								shortDescription: { text: "Exact contract load error" },
							},
						]),
					},
				},
				results: findingResults.concat(exactResults),
			},
		],
	}, null, 2);
}

function markdownList(values) {
	return (values || []).length > 0 ? values.join(", ") : "_none_";
}

function markdownCell(value) {
	return String(value ?? "")
		.replace(/\\/g, "\\\\")
		.replace(/\|/g, "\\|")
		.replace(/\r?\n/g, " ");
}

function markdownReport(report) {
	const summary = report.summary || {};
	const lines = [
		"# Luau Contract Report",
		"",
		"## Summary",
		"",
		`- Scripts: ${summary.scriptCount || 0}`,
		`- Systems: ${summary.systemCount || 0}`,
		`- Exact contracts: ${summary.contractCount || 0}`,
		`- Findings: ${summary.scannerFindingCount || 0}`,
		`- Policy: ${report.policy?.ok ? "passed" : "failed"}`,
		"",
		"## Findings",
		"",
	];

	if ((report.scanner?.findings || []).length === 0) {
		lines.push("_No static findings._", "");
	} else {
		lines.push("| Severity | Rule | Location | Message |", "| --- | --- | --- | --- |");
		for (const finding of report.scanner.findings) {
			lines.push(`| ${markdownCell(finding.severity)} | ${markdownCell(finding.ruleId)} | ${markdownCell(`${finding.path}:${finding.line}`)} | ${markdownCell(finding.message)} |`);
		}
		lines.push("");
	}

	lines.push("## Exact Contracts", "");
	if ((report.contracts || []).length === 0) {
		lines.push("_No exact contract reports loaded._", "");
	} else {
		for (const contract of report.contracts) {
			lines.push(`### ${contract.name}`, "");
			if (contract.path) {
				lines.push(`Path: \`${contract.path}\``, "");
			}
			lines.push(`- Actions: ${markdownList(Object.keys(contract.actions || {}))}`);
			lines.push(`- Remotes: ${markdownList(Object.keys(contract.remotes || {}))}`);
			lines.push(`- Lifecycles: ${markdownList(Object.keys(contract.lifecycles || {}))}`);
			lines.push(`- Strict permissions: ${contract.permissions?.strict === true ? "yes" : "no"}`, "");
		}
	}

	return `${lines.join("\n")}\n`;
}

function renderReport(report, format) {
	if (format === "text") {
		return textReport(report);
	}
	if (format === "json") {
		return `${JSON.stringify(report, null, 2)}\n`;
	}
	if (format === "sarif") {
		return `${sarifReport(report)}\n`;
	}
	if (format === "markdown" || format === "md") {
		return markdownReport(report);
	}
	throw new Error(`Unknown report format: ${format}`);
}

function extensionForFormat(format) {
	if (format === "text") {
		return "txt";
	}
	if (format === "markdown") {
		return "md";
	}
	return format;
}

function writeOutput(filePath, contents) {
	fs.mkdirSync(path.dirname(filePath), { recursive: true });
	fs.writeFileSync(filePath, contents);
}

function writeReports(report, options) {
	const formats = options.formats;
	if (formats.length > 1 && !options.outDir) {
		throw new Error("Multiple report formats require --out-dir");
	}
	if (options.out && formats.length !== 1) {
		throw new Error("--out can only be used with one --format value");
	}

	const written = [];
	for (const format of formats) {
		const contents = renderReport(report, format);
		if (options.out) {
			writeOutput(options.out, contents);
			written.push(options.out);
		} else if (options.outDir) {
			const target = path.join(options.outDir, `contracts.${extensionForFormat(format)}`);
			writeOutput(target, contents);
			written.push(target);
		} else {
			process.stdout.write(contents);
		}
	}
	return written;
}

module.exports = {
	markdownReport,
	renderReport,
	sarifReport,
	textReport,
	writeReports,
};
