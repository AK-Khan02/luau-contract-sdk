local StaticScanner = require("../Core/StaticScanner")

local StudioReport = {}

local function copyMap(value)
	if type(value) ~= "table" then
		return value
	end

	local copy = {}
	for key, child in pairs(value) do
		copy[key] = child
	end
	return copy
end

local function increment(counts, key)
	local safeKey = key or "unknown"
	counts[safeKey] = (counts[safeKey] or 0) + 1
end

local function countPattern(source, pattern)
	local count = 0
	for _ in string.gmatch(source or "", pattern) do
		count += 1
	end
	return count
end

local function extractSystemNames(source)
	local names = {}

	for name in string.gmatch(source or "", "Contracts%.system%s*%(%s*\"([^\"]+)\"%s*%)") do
		table.insert(names, name)
	end
	for name in string.gmatch(source or "", "Contracts%.system%s*%(%s*'([^']+)'%s*%)") do
		table.insert(names, name)
	end

	return names
end

local function scriptPath(scriptInfo)
	return scriptInfo.path or scriptInfo.name or "<script>"
end

local function addSystems(systems, scriptInfo)
	local source = scriptInfo.source or ""
	local systemNames = extractSystemNames(source)

	for _, name in ipairs(systemNames) do
		table.insert(systems, {
			name = name,
			path = scriptPath(scriptInfo),
			ownedTags = countPattern(source, ":ownsTag%s*%("),
			ownedFolders = countPattern(source, ":ownsFolder%s*%("),
			actions = countPattern(source, ":action%s*%("),
			remotes = countPattern(source, ":remote%s*%("),
			postconditions = countPattern(source, ":postcondition%s*%("),
			lifecycles = countPattern(source, ":lifecycle%s*%("),
		})
	end
end

local function addScannerFindings(findings, scriptInfo)
	local scan = StaticScanner.scanSource(scriptInfo.source or "", {
		path = scriptPath(scriptInfo),
	})

	for _, finding in ipairs(scan.findings) do
		table.insert(findings, finding)
	end
end

local function diagnosticRowsFromReport(diagnosticsReport)
	local rows = {}
	if not diagnosticsReport then
		return rows
	end

	for _, entry in ipairs(diagnosticsReport.recent or {}) do
		table.insert(rows, {
			id = entry.id,
			level = entry.level,
			category = entry.category,
			system = entry.system,
			name = entry.name,
			message = entry.message,
			context = copyMap(entry.context or {}),
		})
	end

	return rows
end

local function scannerSummary(findings)
	local bySeverity = {}
	local byRule = {}
	local byCategory = {}

	for _, finding in ipairs(findings) do
		increment(bySeverity, finding.severity)
		increment(byRule, finding.ruleId)
		increment(byCategory, finding.category)
	end

	return {
		total = #findings,
		bySeverity = bySeverity,
		byRule = byRule,
		byCategory = byCategory,
	}
end

local function countScriptsByClass(scripts)
	local counts = {}
	for _, scriptInfo in ipairs(scripts) do
		increment(counts, scriptInfo.className)
	end
	return counts
end

function StudioReport.fromScripts(scripts, options)
	options = options or {}

	local systems = {}
	local scannerFindings = {}

	for _, scriptInfo in ipairs(scripts or {}) do
		addSystems(systems, scriptInfo)
		addScannerFindings(scannerFindings, scriptInfo)
	end

	local diagnosticsReport = options.diagnosticsReport
	local diagnosticRows = diagnosticRowsFromReport(diagnosticsReport)
	local scanner = scannerSummary(scannerFindings)

	return {
		summary = {
			scriptCount = #(scripts or {}),
			scriptsByClass = countScriptsByClass(scripts or {}),
			systemCount = #systems,
			diagnosticCount = diagnosticsReport and diagnosticsReport.total or 0,
			scannerFindingCount = scanner.total,
			scannerErrors = scanner.bySeverity.error or 0,
			scannerWarnings = scanner.bySeverity.warn or 0,
		},
		systems = systems,
		diagnostics = diagnosticRows,
		scanner = {
			findings = scannerFindings,
			summary = scanner,
		},
	}
end

function StudioReport.formatSystem(system)
	return ("%s  tags=%d folders=%d actions=%d remotes=%d post=%d"):format(
		system.name,
		system.ownedTags or 0,
		system.ownedFolders or 0,
		system.actions or 0,
		system.remotes or 0,
		system.postconditions or 0
	)
end

function StudioReport.formatDiagnostic(row)
	return ("[%s] %s %s"):format(tostring(row.level or "info"), tostring(row.name or "Diagnostic"), tostring(row.message or ""))
end

function StudioReport.formatFinding(finding)
	return StaticScanner.formatFinding(finding)
end

return StudioReport
