--!strict

local Source = require("./StaticScannerSource")

export type Finding = {
	[string]: any,
	ruleId: string,
	severity: string,
	category: string,
	path: string,
	line: number,
	column: number,
	message: string,
	snippet: string,
}

export type Summary = {
	total: number,
	highestSeverity: string?,
	byRule: { [string]: number },
	bySeverity: { [string]: number },
	byCategory: { [string]: number },
}

export type Report = {
	findings: { Finding },
	summary: Summary,
}

export type Rule = {
	id: string,
	title: string?,
	severity: string?,
	category: string?,
	remediation: string?,
	docs: string?,
	scan: ({ Finding }, { Source.Line }, string) -> (),
}

export type Options = {
	path: string?,
}

local StaticScanner: any = {}

local SEVERITY_ORDER: { [string]: number } = {
	error = 3,
	warn = 2,
	info = 1,
}

local function addFinding(findings: { Finding }, fields: any)
	if Source.isCommentOnly(fields.snippet) or Source.hasInlineAllow(fields.snippet, fields.ruleId) then
		return
	end

	local finding: Finding = {
		ruleId = tostring(fields.ruleId),
		severity = tostring(fields.severity or "warn"),
		category = tostring(fields.category or "static"),
		path = tostring(fields.path),
		line = fields.line or 0,
		column = fields.column or 1,
		message = tostring(fields.message or ""),
		snippet = Source.trim(fields.snippet),
	}

	table.insert(findings, finding)
end

local function scanRawRemoteHandlers(findings: { Finding }, lines: { Source.Line }, path: string)
	local ruleId = "raw-remote-handler"

	for lineNumber, line in ipairs(lines) do
		local column = string.find(line.code, "OnServerEvent%s*:%s*Connect")
		if
			column
			and not Source.contextHasAllow(lines, lineNumber, lineNumber + 1, ruleId)
			and not Source.contextContainsText(lines, lineNumber - 3, lineNumber + 1, "RemoteGuard.connect")
		then
			addFinding(findings, {
				ruleId = ruleId,
				severity = "error",
				category = "remote",
				path = path,
				line = lineNumber,
				column = column,
				message = "RemoteEvent server handlers should be wrapped with RemoteGuard.connect so payload validation and rate limiting run first.",
				snippet = line.raw,
			})
		end
	end
end

local function scanRawRemoteFires(findings: { Finding }, lines: { Source.Line }, path: string)
	local ruleId = "raw-remote-fire"
	local patterns = {
		":FireServer%s*%(",
		":FireClient%s*%(",
		":FireAllClients%s*%(",
	}

	for lineNumber, line in ipairs(lines) do
		for _, pattern in ipairs(patterns) do
			local column = string.find(line.code, pattern)
			if
				column
				and not Source.contextHasAllow(lines, lineNumber, lineNumber + 1, ruleId)
				and not Source.contextContainsText(lines, lineNumber - 2, lineNumber + 1, "RemoteGuard")
			then
				addFinding(findings, {
					ruleId = ruleId,
					severity = "warn",
					category = "remote",
					path = path,
					line = lineNumber,
					column = column,
					message = "Raw remote firing should be paired with an explicit contract boundary and documented payload schema.",
					snippet = line.raw,
				})
			end
		end
	end
end

local function scanBroadCleanup(findings: { Finding }, lines: { Source.Line }, path: string)
	local ruleId = "broad-cleanup"

	for lineNumber, line in ipairs(lines) do
		local clearColumn = string.find(line.code, ":ClearAllChildren%s*%(")
		if clearColumn and not Source.contextHasAllow(lines, lineNumber, lineNumber + 1, ruleId) then
			local hasLocalOwnerClue = string.find(line.code, "Folder", 1, true)
				or string.find(line.code, "folder", 1, true)
				or Source.contextContainsText(lines, lineNumber - 2, lineNumber, "ownsFolder")
				or Source.contextContainsText(lines, lineNumber - 2, lineNumber, "ContractOwner")

			if not hasLocalOwnerClue then
				addFinding(findings, {
					ruleId = ruleId,
					severity = "error",
					category = "ownership",
					path = path,
					line = lineNumber,
					column = clearColumn,
					message = "Broad cleanup must be scoped to an owned/namespaced folder.",
					snippet = line.raw,
				})
			end
		end

		local workspaceColumn = string.find(line.code, "Workspace%s*:%s*ClearAllChildren%s*%(")
			or string.find(line.code, "workspace%s*:%s*ClearAllChildren%s*%(")
		if workspaceColumn and not Source.contextHasAllow(lines, lineNumber, lineNumber + 1, "workspace-clear-all") then
			addFinding(findings, {
				ruleId = "workspace-clear-all",
				severity = "error",
				category = "ownership",
				path = path,
				line = lineNumber,
				column = workspaceColumn,
				message = "Never clear all Workspace children from gameplay code.",
				snippet = line.raw,
			})
		end
	end
end

local function scanUnsafeDestroy(findings: { Finding }, lines: { Source.Line }, path: string)
	local ruleId = "unowned-destroy"

	for lineNumber, line in ipairs(lines) do
		local column = string.find(line.code, ":Destroy%s*%(")
		if column and not Source.contextHasAllow(lines, lineNumber, lineNumber + 1, ruleId) then
			local hasOwnerGuard = Source.contextContainsText(
				lines,
				lineNumber - 4,
				lineNumber + 1,
				"Ownership.destroyOwned"
			) or Source.contextContainsText(lines, lineNumber - 4, lineNumber + 1, "Ownership.assertOwned") or Source.contextContainsText(
				lines,
				lineNumber - 4,
				lineNumber + 1,
				'GetAttribute("ContractOwner")'
			) or Source.contextContainsText(lines, lineNumber - 4, lineNumber + 1, "GetAttribute('ContractOwner')") or Source.contextContainsText(
				lines,
				lineNumber - 4,
				lineNumber + 1,
				"ownsFolder"
			)

			if not hasOwnerGuard then
				addFinding(findings, {
					ruleId = ruleId,
					severity = "warn",
					category = "ownership",
					path = path,
					line = lineNumber,
					column = column,
					message = "Destroy calls should prove the system owns the instance or be scoped to an owned folder.",
					snippet = line.raw,
				})
			end
		end
	end
end

local function scanAsyncWithoutToken(findings: { Finding }, lines: { Source.Line }, path: string)
	local ruleId = "async-without-token"

	for lineNumber, line in ipairs(lines) do
		local hasAsync = string.find(line.code, "task%.delay%s*%(")
			or string.find(line.code, "task%.spawn%s*%(")
			or string.find(line.code, "task%.defer%s*%(")

		if hasAsync and not Source.contextHasAllow(lines, lineNumber, lineNumber + 1, ruleId) then
			local hasStaleGuard = Source.contextContains(lines, lineNumber - 5, lineNumber + 12, "[Tt]oken")
				or Source.contextContains(lines, lineNumber - 5, lineNumber + 12, "[Rr]unId")
				or Source.contextContains(lines, lineNumber - 5, lineNumber + 12, "[Gg]eneration")
				or Source.contextContains(lines, lineNumber - 5, lineNumber + 12, "[Rr]equestId")
				or Source.contextContainsText(lines, lineNumber - 5, lineNumber + 12, "IsRoundActive")

			if not hasStaleGuard then
				addFinding(findings, {
					ruleId = ruleId,
					severity = "warn",
					category = "lifecycle",
					path = path,
					line = lineNumber,
					column = hasAsync,
					message = "Async callbacks should check a token, run id, generation id, request id, or owner before mutating state.",
					snippet = line.raw,
				})
			end
		end
	end
end

local RULES: { Rule } = {
	{
		id = "raw-remote-handler",
		title = "Raw remote server handler",
		severity = "error",
		category = "remote",
		remediation = "Wrap server remote handlers with RemoteGuard.connect or Runtime:bindRemote so payload validation, actor policy, lifecycle checks, and rate limits run before game code.",
		docs = "docs/API.md#remote-contracts",
		scan = scanRawRemoteHandlers,
	},
	{
		id = "raw-remote-fire",
		title = "Raw remote fire",
		severity = "warn",
		category = "remote",
		remediation = "Pair remote firing with an explicit contract boundary and documented payload schema.",
		docs = "docs/API.md#remote-contracts",
		scan = scanRawRemoteFires,
	},
	{
		id = "broad-cleanup",
		title = "Broad cleanup without ownership clue",
		severity = "error",
		category = "ownership",
		remediation = "Scope cleanup to a contract-owned folder or prove ownership before clearing descendants.",
		docs = "docs/API.md#permission-capabilities",
		scan = scanBroadCleanup,
	},
	{
		id = "unowned-destroy",
		title = "Destroy without ownership proof",
		severity = "warn",
		category = "ownership",
		remediation = "Use Ownership.destroyOwned, Ownership.assertOwned, an owned folder, or a ContractOwner attribute check before destroying instances.",
		docs = "docs/INTEGRATION.md#runtime-boundary",
		scan = scanUnsafeDestroy,
	},
	{
		id = "async-without-token",
		title = "Async callback without stale guard",
		severity = "warn",
		category = "lifecycle",
		remediation = "Check a token, run id, generation id, request id, or lifecycle state before async callbacks mutate state.",
		docs = "docs/API.md#lifecycle-sessions",
		scan = scanAsyncWithoutToken,
	},
}

local EMITTED_RULE_METADATA = {
	{
		id = "workspace-clear-all",
		title = "Workspace clear all",
		severity = "error",
		category = "ownership",
		remediation = "Never call Workspace:ClearAllChildren from gameplay code; scope cleanup to a contract-owned folder.",
		docs = "docs/API.md#permission-capabilities",
	},
}

local function countByKey(findings: { Finding }, key: string): { [string]: number }
	local counts = {}
	for _, finding in ipairs(findings) do
		local value = finding[key] or "unknown"
		local stringValue = tostring(value)
		counts[stringValue] = (counts[stringValue] or 0) + 1
	end
	return counts
end

local function summarize(findings: { Finding }): Summary
	local highest = "info"
	for _, finding in ipairs(findings) do
		if (SEVERITY_ORDER[finding.severity] or 0) > (SEVERITY_ORDER[highest] or 0) then
			highest = finding.severity
		end
	end

	return {
		total = #findings,
		highestSeverity = #findings > 0 and highest or nil,
		byRule = countByKey(findings, "ruleId"),
		bySeverity = countByKey(findings, "severity"),
		byCategory = countByKey(findings, "category"),
	}
end

function StaticScanner.summarize(findings: { Finding }?): Summary
	return summarize(findings or {})
end

function StaticScanner.rules(): { Rule }
	local copy: { Rule } = {}
	for index, rule in ipairs(RULES) do
		copy[index] = rule
	end
	return copy
end

function StaticScanner.ruleMetadata(): { [string]: any }
	local metadata = {}
	for _, rule in ipairs(RULES) do
		metadata[rule.id] = {
			id = rule.id,
			title = rule.title,
			severity = rule.severity,
			category = rule.category,
			remediation = rule.remediation,
			docs = rule.docs,
		}
	end
	for _, rule in ipairs(EMITTED_RULE_METADATA) do
		metadata[rule.id] = {
			id = rule.id,
			title = rule.title,
			severity = rule.severity,
			category = rule.category,
			remediation = rule.remediation,
			docs = rule.docs,
		}
	end
	return metadata
end

function StaticScanner.scanSource(source: string?, options: Options?): Report
	local scanOptions: any = options or {}

	local path = scanOptions.path or "<source>"
	local lines = Source.splitLines(source)
	local findings: { Finding } = {}

	for _, rule in ipairs(RULES) do
		rule.scan(findings, lines, path)
	end

	return {
		findings = findings,
		summary = StaticScanner.summarize(findings),
	}
end

function StaticScanner.formatFinding(finding: Finding): string
	return ("%s:%d:%d [%s] %s %s"):format(
		tostring(finding.path or "<source>"),
		finding.line or 0,
		finding.column or 1,
		tostring(finding.severity or "warn"),
		tostring(finding.ruleId or "unknown"),
		tostring(finding.message or "")
	)
end

function StaticScanner.formatReport(report: Report): string
	local lines: { string } = {
		("static scan: findings=%d highest=%s"):format(
			report.summary.total,
			tostring(report.summary.highestSeverity or "none")
		),
	}

	for _, finding in ipairs(report.findings) do
		table.insert(lines, tostring(StaticScanner.formatFinding(finding)))
	end

	return table.concat(lines, "\n")
end

return StaticScanner
