--!strict

local ReportPolicy = require("./ReportPolicy")
local StaticScanner = require("../Core/StaticScanner")
local StudioReport = require("../Studio/StudioReport")

local ScanRunner = {}

local function contractObjects(entries: { any }?): { any }
	local contracts = {}
	for _, entry in ipairs(entries or {}) do
		if entry ~= nil then
			table.insert(contracts, entry)
		end
	end
	return contracts
end

local function exactReport(errors: { any }?): any
	return {
		errors = errors or {},
	}
end

function ScanRunner.run(input: any): any
	local scripts = input and input.scripts or {}
	local contracts = contractObjects(input and input.contracts or {})
	local report: any = StudioReport.fromScripts(
		scripts,
		{
			contracts = contracts,
		} :: any
	)

	local scanner: any = report.scanner
	scanner.rules = StaticScanner.ruleMetadata()
	report.exact = exactReport(input and input.exactErrors or {})
	report.host = {
		formatVersion = 1,
		scriptCount = #scripts,
		loadedContractCount = #contracts,
	}
	report.policy = ReportPolicy.evaluate(report, input and input.policy or {})

	return report
end

return ScanRunner
