--!strict

local TableUtil = require("./TableUtil")

export type DiagnosticEntry = {
	[string]: any,
	id: number?,
	time: number?,
	level: string?,
	category: string?,
	code: string?,
	system: any?,
	name: string?,
	message: string?,
	reason: string?,
	context: { [any]: any }?,
	details: { [any]: any }?,
}

export type Report = {
	total: number,
	capacity: number?,
	dropped: number,
	hasFailures: boolean,
	counts: {
		byLevel: { [any]: number },
		bySystem: { [any]: number },
		byName: { [any]: number },
		byCategory: { [any]: number },
	},
	keys: {
		levels: { any },
		systems: { any },
		names: { any },
		categories: { any },
	},
	recent: { DiagnosticEntry },
}

local DiagnosticReport: any = {}

local copyMap = TableUtil.copyMap

local function copyEntry(entry: DiagnosticEntry): DiagnosticEntry
	local copy = copyMap(entry)
	copy.context = copyMap(entry.context or {})
	return copy
end

local function increment(counts: { [any]: number }, key: any)
	local safeKey = key or "unknown"
	counts[safeKey] = (counts[safeKey] or 0) + 1
end

local function sortedKeys(counts: { [any]: number }): { any }
	local keys = {}
	for key in pairs(counts) do
		table.insert(keys, key)
	end
	table.sort(keys, function(left, right)
		return tostring(left) < tostring(right)
	end)
	return keys
end

local function recentRecords(records: { DiagnosticEntry }, limit: number): { DiagnosticEntry }
	local recent = {}
	local startIndex = math.max(1, #records - limit + 1)

	for index = startIndex, #records do
		table.insert(recent, copyEntry(records[index]))
	end

	return recent
end

function DiagnosticReport.formatEntry(entry: DiagnosticEntry): string
	local parts = {
		"[" .. tostring(entry.level or "info") .. "]",
		tostring(entry.name or "Diagnostic"),
	}

	if entry.system ~= nil then
		table.insert(parts, "system=" .. tostring(entry.system))
	end
	if entry.category ~= nil then
		table.insert(parts, "category=" .. tostring(entry.category))
	end
	if entry.message ~= nil then
		table.insert(parts, tostring(entry.message))
	end

	return table.concat(parts, " ")
end

function DiagnosticReport.summarize(records: { DiagnosticEntry }, meta: any?, options: any?): Report
	options = options or {}
	meta = meta or {}

	local countsByLevel = {}
	local countsBySystem = {}
	local countsByName = {}
	local countsByCategory = {}
	local hasFailures = false

	for _, entry in ipairs(records) do
		increment(countsByLevel, entry.level)
		increment(countsBySystem, entry.system)
		increment(countsByName, entry.name)
		increment(countsByCategory, entry.category)
		if entry.level == "error" then
			hasFailures = true
		end
	end

	local recentLimit = options.recentLimit or 10

	return {
		total = #records,
		capacity = meta.capacity,
		dropped = meta.dropped or 0,
		hasFailures = hasFailures,
		counts = {
			byLevel = countsByLevel,
			bySystem = countsBySystem,
			byName = countsByName,
			byCategory = countsByCategory,
		},
		keys = {
			levels = sortedKeys(countsByLevel),
			systems = sortedKeys(countsBySystem),
			names = sortedKeys(countsByName),
			categories = sortedKeys(countsByCategory),
		},
		recent = recentRecords(records, recentLimit),
	}
end

function DiagnosticReport.formatReport(report: Report): string
	local lines: { string } = {
		("diagnostics: total=%d dropped=%d failures=%s"):format(
			report.total or 0,
			report.dropped or 0,
			tostring(report.hasFailures == true)
		),
	}

	for _, entry in ipairs(report.recent or {}) do
		table.insert(lines, tostring(DiagnosticReport.formatEntry(entry)))
	end

	return table.concat(lines, "\n")
end

return DiagnosticReport
