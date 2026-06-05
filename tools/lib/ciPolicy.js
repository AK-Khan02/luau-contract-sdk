"use strict";

function findingKey(finding) {
	return [
		finding.ruleId || "unknown",
		finding.path || "<source>",
		finding.line || 0,
		finding.column || 1,
		finding.snippet || "",
	].join("|");
}

function baselineKeysFromReport(report) {
	const findings = report?.scanner?.findings || report?.findings || [];
	return findings.map((finding) => findingKey(finding));
}

function decisionText(policy) {
	if (!policy || policy.ok) {
		return "policy passed";
	}
	return `policy failed: ${(policy.reasons || []).join("; ")}`;
}

module.exports = {
	baselineKeysFromReport,
	decisionText,
	findingKey,
};
