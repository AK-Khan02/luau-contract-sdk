--!strict

local DiagnosticReport = require("./DiagnosticReport")

export type DiagnosticEntry = DiagnosticReport.DiagnosticEntry
export type Report = DiagnosticReport.Report

export type Config = {
	capacity: number?,
	clock: (() -> number)?,
}

export type Query = {
	limit: number?,
	[string]: any,
}

export type Fields = DiagnosticEntry

local Diagnostics: any = {}
Diagnostics.__index = Diagnostics

local DEFAULT_CAPACITY = 100

local function defaultClock(): number
	if os and os.clock then
		return os.clock()
	end
	return 0
end

local function copyMap(value: any): any
	if type(value) ~= "table" then
		return value
	end

	local copy = {}
	for key, child in pairs(value) do
		copy[key] = child
	end
	return copy
end

local function copyEntry(entry: DiagnosticEntry): DiagnosticEntry
	local copy = copyMap(entry)
	copy.context = copyMap(entry.context or {})
	return copy
end

local function copyList(values: { DiagnosticEntry }): { DiagnosticEntry }
	local copy = {}
	for index, value in ipairs(values) do
		copy[index] = copyEntry(value)
	end
	return copy
end

local function matchesQuery(entry: DiagnosticEntry, query: Query): boolean
	for key, expected in pairs(query) do
		if key ~= "limit" and entry[key] ~= expected then
			return false
		end
	end
	return true
end

function Diagnostics.new(config: Config?): any
	local diagnosticsConfig: any = config or {}

	local capacity = diagnosticsConfig.capacity or DEFAULT_CAPACITY
	if capacity < 1 then
		error("Diagnostics capacity must be at least 1", 2)
	end

	return setmetatable({
		_capacity = capacity,
		_clock = diagnosticsConfig.clock or defaultClock,
		_records = {},
		_dropped = 0,
		_nextId = 1,
		_subscribers = {},
	}, Diagnostics)
end

function Diagnostics.record(self: any, fields: Fields?): DiagnosticEntry
	local recordFields: any = fields or {}

	if #self._records >= self._capacity then
		table.remove(self._records, 1)
		self._dropped += 1
	end

	local id = recordFields.id or self._nextId
	if recordFields.id == nil then
		self._nextId += 1
	end

	local entry: DiagnosticEntry = {
		id = id,
		time = recordFields.time or self._clock(),
		level = recordFields.level or "error",
		category = recordFields.category or "contract",
		code = recordFields.code or recordFields.name or "ContractViolation",
		system = recordFields.system,
		name = recordFields.name or "ContractViolation",
		message = recordFields.message or recordFields.reason or "contract violation",
		context = copyMap(recordFields.context or recordFields.details or {}),
	}

	table.insert(self._records, entry)
	self:_notify(entry)
	return copyEntry(entry)
end

function Diagnostics._notify(self: any, entry: DiagnosticEntry)
	for token, listener in pairs(self._subscribers) do
		local ok = pcall(listener, copyEntry(entry))
		if not ok then
			self._subscribers[token] = nil
		end
	end
end

function Diagnostics.subscribe(self: any, listener: (DiagnosticEntry) -> (), options: any?): () -> ()
	if type(listener) ~= "function" then
		error("Diagnostics.subscribe expects a listener function", 2)
	end

	local token = {}
	self._subscribers[token] = listener

	if options and options.replay then
		for _, entry in ipairs(self._records) do
			local ok = pcall(listener, copyEntry(entry))
			if not ok then
				self._subscribers[token] = nil
				break
			end
		end
	end

	return function()
		self._subscribers[token] = nil
	end
end

function Diagnostics.list(self: any): { DiagnosticEntry }
	return copyList(self._records)
end

function Diagnostics.last(self: any): DiagnosticEntry?
	local entry = self._records[#self._records]
	if not entry then
		return nil
	end
	return copyEntry(entry)
end

function Diagnostics.clear(self: any)
	self._records = {}
	self._dropped = 0
end

function Diagnostics.count(self: any): number
	return #self._records
end

function Diagnostics.droppedCount(self: any): number
	return self._dropped
end

function Diagnostics.hasFailures(self: any): boolean
	for _, entry in ipairs(self._records) do
		if entry.level == "error" then
			return true
		end
	end
	return false
end

function Diagnostics.find(self: any, query: Query?): { DiagnosticEntry }
	query = query or {}

	local matches = {}
	local limit = query.limit

	for index = #self._records, 1, -1 do
		local entry = self._records[index]
		if matchesQuery(entry, query) then
			table.insert(matches, copyEntry(entry))
			if limit ~= nil and #matches >= limit then
				break
			end
		end
	end

	return matches
end

function Diagnostics.findByName(self: any, name: string): { DiagnosticEntry }
	return self:find({
		name = name,
	})
end

function Diagnostics.report(self: any, options: any?): Report
	return DiagnosticReport.summarize(self._records, {
		capacity = self._capacity,
		dropped = self._dropped,
	}, options)
end

function Diagnostics.formatEntry(_self: any, entry: DiagnosticEntry): string
	return DiagnosticReport.formatEntry(entry)
end

function Diagnostics.formatReport(self: any, options: any?): string
	return DiagnosticReport.formatReport(self:report(options))
end

return Diagnostics
