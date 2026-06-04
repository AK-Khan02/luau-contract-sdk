--!strict

export type ScriptInfo = {
	path: string,
	name: string,
	className: string,
	source: string,
}

export type SummaryCard = {
	label: string,
	value: any,
	tone: string,
}

export type SystemRow = {
	summary: string,
	path: string,
}

export type FindingRow = {
	title: string,
	message: string,
	tone: string,
}

export type DiagnosticRow = {
	text: string,
}

local PluginModel = {}

local SCRIPT_CLASSES: {[string]: boolean} = {
	Script = true,
	LocalScript = true,
	ModuleScript = true,
}

function PluginModel.isScriptClass(className: string): boolean
	return SCRIPT_CLASSES[className] == true
end

function PluginModel.scriptPath(instance: any): string
	if instance and type(instance.GetFullName) == "function" then
		local getFullName = instance.GetFullName :: (any) -> any
		local ok, fullName = pcall(getFullName, instance)
		if ok and type(fullName) == "string" then
			return fullName
		end
	end

	return tostring(instance and instance.Name or "<script>")
end

function PluginModel.collectScripts(root: any): {ScriptInfo}
	local scripts: {ScriptInfo} = {}
	if not root or type(root.GetDescendants) ~= "function" then
		return scripts
	end

	local getDescendants = root.GetDescendants :: (any) -> {any}
	for _, rawInstance in ipairs(getDescendants(root)) do
		local instance: any = rawInstance
		if PluginModel.isScriptClass(tostring(instance.ClassName)) then
			local ok, source = pcall(function()
				return instance.Source
			end)

			if ok and type(source) == "string" then
				table.insert(scripts, {
					path = PluginModel.scriptPath(instance),
					name = tostring(instance.Name or ""),
					className = tostring(instance.ClassName),
					source = source,
				})
			end
		end
	end

	return scripts
end

function PluginModel.summaryCards(report: any): {SummaryCard}
	local summary = report.summary or {}

	return {
		{
			label = "Systems",
			value = summary.systemCount or 0,
			tone = "ok",
		},
		{
			label = "Findings",
			value = summary.scannerFindingCount or 0,
			tone = (summary.scannerErrors or 0) > 0 and "error" or "text",
		},
		{
			label = "Errors",
			value = summary.scannerErrors or 0,
			tone = (summary.scannerErrors or 0) > 0 and "error" or "muted",
		},
		{
			label = "Warnings",
			value = summary.scannerWarnings or 0,
			tone = (summary.scannerWarnings or 0) > 0 and "warn" or "muted",
		},
	}
end

function PluginModel.systemRows(report: any, formatSystem: (any) -> string): {SystemRow}
	local rows: {SystemRow} = {}
	for _, rawSystem in ipairs(report.systems or {}) do
		local system: any = rawSystem
		table.insert(rows, {
			summary = formatSystem(system),
			path = tostring(system.path or ""),
		})
	end
	return rows
end

function PluginModel.findingTone(finding: any): string
	if finding.severity == "error" then
		return "error"
	end
	if finding.severity == "warn" then
		return "warn"
	end
	return "muted"
end

function PluginModel.findingRows(report: any): {FindingRow}
	local rows: {FindingRow} = {}
	for _, rawFinding in ipairs((report.scanner and report.scanner.findings) or {}) do
		local finding: any = rawFinding
		table.insert(rows, {
			title = tostring(finding.ruleId) .. "  " .. tostring(finding.path) .. ":" .. tostring(finding.line),
			message = tostring(finding.message or ""),
			tone = PluginModel.findingTone(finding),
		})
	end
	return rows
end

function PluginModel.diagnosticRows(report: any, formatDiagnostic: (any) -> string): {DiagnosticRow}
	local rows: {DiagnosticRow} = {}
	for _, rawRow in ipairs(report.diagnostics or {}) do
		local row: any = rawRow
		table.insert(rows, {
			text = formatDiagnostic(row),
		})
	end
	return rows
end

return PluginModel
