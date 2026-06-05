--!strict

export type Decision = {
	ok: boolean,
	exitCode: number,
	failOn: string,
	maxWarnings: number?,
	findingCount: number,
	newFindingCount: number,
	suppressedByBaseline: number,
	newErrors: number,
	newWarnings: number,
	exactErrors: number,
	reasons: {string},
}

local ReportPolicy = {}

local SEVERITY_ORDER: {[string]: number} = {
	info = 1,
	warn = 2,
	error = 3,
}

local function findingKey(finding: any): string
	return table.concat({
		tostring(finding.ruleId or "unknown"),
		tostring(finding.path or "<source>"),
		tostring(finding.line or 0),
		tostring(finding.column or 1),
		tostring(finding.snippet or ""),
	}, "|")
end

local function baselineSet(keys: {string}?): {[string]: boolean}
	local set = {}
	for _, key in ipairs(keys or {}) do
		set[tostring(key)] = true
	end
	return set
end

local function crossesThreshold(severity: string?, failOn: string): boolean
	local threshold = SEVERITY_ORDER[failOn] or SEVERITY_ORDER.error
	return (SEVERITY_ORDER[severity or "info"] or 0) >= threshold
end

function ReportPolicy.findingKey(finding: any): string
	return findingKey(finding)
end

function ReportPolicy.evaluate(report: any, options: any?): Decision
	local policyOptions = options or {}
	local failOn = tostring(policyOptions.failOn or "error")
	local maxWarnings = if type(policyOptions.maxWarnings) == "number" then policyOptions.maxWarnings else nil
	local baseline = baselineSet(policyOptions.baselineKeys)

	local findingCount = 0
	local newFindingCount = 0
	local suppressedByBaseline = 0
	local newErrors = 0
	local newWarnings = 0
	local thresholdFailures = 0

	for _, rawFinding in ipairs((report.scanner and report.scanner.findings) or {}) do
		local finding: any = rawFinding
		findingCount += 1
		if baseline[findingKey(finding)] then
			suppressedByBaseline += 1
		else
			newFindingCount += 1
			if finding.severity == "error" then
				newErrors += 1
			elseif finding.severity == "warn" then
				newWarnings += 1
			end
			if crossesThreshold(finding.severity, failOn) then
				thresholdFailures += 1
			end
		end
	end

	local exactErrors = #((report.exact and report.exact.errors) or {})
	local reasons = {}
	if thresholdFailures > 0 then
		table.insert(reasons, ("%d new finding(s) at or above %s"):format(thresholdFailures, failOn))
	end
	if maxWarnings ~= nil and newWarnings > maxWarnings then
		table.insert(reasons, ("%d new warning(s) exceed maxWarnings=%d"):format(newWarnings, maxWarnings))
	end
	if exactErrors > 0 then
		table.insert(reasons, ("%d exact contract load error(s)"):format(exactErrors))
	end

	return {
		ok = #reasons == 0,
		exitCode = #reasons == 0 and 0 or 1,
		failOn = failOn,
		maxWarnings = maxWarnings,
		findingCount = findingCount,
		newFindingCount = newFindingCount,
		suppressedByBaseline = suppressedByBaseline,
		newErrors = newErrors,
		newWarnings = newWarnings,
		exactErrors = exactErrors,
		reasons = reasons,
	}
end

return ReportPolicy
