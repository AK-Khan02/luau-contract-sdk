"use strict";

const { renderInputSchema } = require("./remoteMigrationSuggestions");

function requireTarget(requirePath) {
	if (!requirePath) {
		return JSON.stringify("../src/Contracts");
	}
	const value = String(requirePath);
	if (value.startsWith("lua:")) {
		return value.slice(4);
	}
	return JSON.stringify(value);
}

function renderRemoteDefinition(finding, options = {}) {
	const lines = [
	`\t:remote(${JSON.stringify(finding.remoteName)}, {`,
	`\t\tinput = ${renderInputSchema(finding.inferredFields, {
		allowExtra: options.strictPayload === true ? false : true,
		indent: "\t\t",
	})},`,
	];
	if (finding.handlerKind === "function") {
		lines.push("\t\toutput = Contracts.any(),");
	}
	lines.push("\t})");
	return lines.join("\n");
}

function renderMigrationContract(findings, options = {}) {
	const systemName = options.systemName || "MigratedRemotes";
	const uniqueFindings = [];
	const seen = new Set();
	for (const finding of findings || []) {
		if (seen.has(finding.remoteName)) {
			continue;
		}
		seen.add(finding.remoteName);
		uniqueFindings.push(finding);
	}

	const lines = [
		`local Contracts = require(${requireTarget(options.contractsRequire)})`,
		"",
		`return Contracts.system(${JSON.stringify(systemName)})`,
	];
	if (uniqueFindings.length === 0) {
		lines.push("\t-- No raw remotes were discovered.");
	} else {
		lines.push(...uniqueFindings.map((finding) => renderRemoteDefinition(finding, options)));
	}
	return `${lines.join("\n")}\n`;
}

module.exports = {
	renderMigrationContract,
};
