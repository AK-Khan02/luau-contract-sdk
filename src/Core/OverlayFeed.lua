--!strict

local DiagnosticReport = require("./DiagnosticReport")

export type Row = {
	[string]: any,
	id: number?,
	time: number?,
	level: string?,
	system: any?,
	name: string?,
	category: string?,
	message: string?,
	text: string,
}

export type Config = {
	maxRows: number?,
	formatter: ((DiagnosticReport.DiagnosticEntry) -> string)?,
}

local OverlayFeed: any = {}
OverlayFeed.__index = OverlayFeed

local DEFAULT_MAX_ROWS = 8

local function copyRow(row: Row): Row
	local copy = {}
	for key, value in pairs(row) do
		copy[key] = value
	end
	return copy
end

local function copyRows(rows: { Row }): { Row }
	local copy = {}
	for index, row in ipairs(rows) do
		copy[index] = copyRow(row)
	end
	return copy
end

local function toRow(
	entry: DiagnosticReport.DiagnosticEntry,
	formatter: (DiagnosticReport.DiagnosticEntry) -> string
): Row
	return {
		id = entry.id,
		time = entry.time,
		level = entry.level,
		system = entry.system,
		name = entry.name,
		category = entry.category,
		message = entry.message,
		text = formatter(entry),
	}
end

function OverlayFeed.new(diagnostics: any, config: Config?): any
	local feedConfig: any = config or {}

	local feed: any = setmetatable({
		_maxRows = feedConfig.maxRows or DEFAULT_MAX_ROWS,
		_formatter = feedConfig.formatter or DiagnosticReport.formatEntry,
		_rows = {},
		_disconnect = nil,
	}, OverlayFeed)

	local diagnosticsSource: any = diagnostics
	if diagnosticsSource and type(diagnosticsSource.list) == "function" then
		local listFn = diagnosticsSource.list :: (any) -> { DiagnosticReport.DiagnosticEntry }
		for _, entry in ipairs(listFn(diagnosticsSource)) do
			feed:_add(entry)
		end
	end

	if diagnosticsSource and type(diagnosticsSource.subscribe) == "function" then
		local subscribeFn = diagnosticsSource.subscribe :: (any, (DiagnosticReport.DiagnosticEntry) -> ()) -> () -> ()
		feed._disconnect = subscribeFn(diagnosticsSource, function(entry)
			feed:_add(entry)
		end)
	end

	return feed
end

function OverlayFeed._add(self: any, entry: DiagnosticReport.DiagnosticEntry)
	table.insert(self._rows, toRow(entry, self._formatter))

	while #self._rows > self._maxRows do
		table.remove(self._rows, 1)
	end
end

function OverlayFeed.rows(self: any): { Row }
	return copyRows(self._rows)
end

function OverlayFeed.latest(self: any): Row?
	local row = self._rows[#self._rows]
	if not row then
		return nil
	end
	return copyRow(row)
end

function OverlayFeed.text(self: any): string
	local lines: { string } = {}
	for _, row in ipairs(self._rows) do
		table.insert(lines, row.text)
	end
	return table.concat(lines, "\n")
end

function OverlayFeed.clear(self: any)
	self._rows = {}
end

function OverlayFeed.destroy(self: any)
	local disconnect: any = self._disconnect
	if disconnect then
		(disconnect :: () -> ())()
		self._disconnect = nil
	end
end

return OverlayFeed
