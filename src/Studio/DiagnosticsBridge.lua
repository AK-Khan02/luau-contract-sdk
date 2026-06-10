--!strict

local JsonEncode = require("../Host/JsonEncode")

export type Config = {
	level: string?,
	replay: boolean?,
	maxBatchEntries: number?,
	flushIntervalSeconds: number?,
	maxContextDepth: number?,
	clock: (() -> number)?,
	onBatch: ((any, string) -> ())?,
}

local DiagnosticsBridge: any = {}
DiagnosticsBridge.__index = DiagnosticsBridge

local WIRE_VERSION = 1
local DEFAULT_MAX_BATCH_ENTRIES = 20
local DEFAULT_FLUSH_INTERVAL = 0.25
local DEFAULT_MAX_CONTEXT_DEPTH = 3

local LEVEL_RANKS: {[string]: number} = {
	info = 1,
	warn = 2,
	error = 3,
}

local function levelRank(level: any): number
	if type(level) == "string" and LEVEL_RANKS[level] ~= nil then
		return LEVEL_RANKS[level]
	end
	return LEVEL_RANKS.error
end

local function defaultClock(): number
	if os and os.clock then
		return os.clock()
	end
	return 0
end

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function actorSummary(value: any): any
	local ok, userId = pcall(function()
		return (value :: any).UserId
	end)
	if not ok or type(userId) ~= "number" then
		return nil
	end

	local okName, name = pcall(function()
		return (value :: any).Name
	end)

	return {
		userId = userId,
		name = okName and tostring(name) or nil,
	}
end

local function redactValue(value: any, depth: number, maxDepth: number): any
	local valueType = type(value)

	if value == nil or valueType == "boolean" or valueType == "string" then
		return value
	end
	if valueType == "number" then
		if isFiniteNumber(value) then
			return value
		end
		return tostring(value)
	end
	if valueType == "table" then
		local summary = actorSummary(value)
		if summary ~= nil then
			return summary
		end
		if depth >= maxDepth then
			return "<table>"
		end

		local copy = {}
		for key, child in pairs(value) do
			local keyType = type(key)
			if keyType == "string" or keyType == "number" then
				copy[key] = redactValue(child, depth + 1, maxDepth)
			end
		end
		return copy
	end

	local summary = actorSummary(value)
	if summary ~= nil then
		return summary
	end

	local ok, text = pcall(tostring, value)
	if ok then
		return text
	end
	return "<" .. valueType .. ">"
end

local function redactEntry(entry: any, maxDepth: number): any
	return {
		id = entry.id,
		time = isFiniteNumber(entry.time) and entry.time or nil,
		level = entry.level,
		category = entry.category,
		code = entry.code,
		system = entry.system ~= nil and tostring(entry.system) or nil,
		name = entry.name,
		message = entry.message ~= nil and tostring(entry.message) or nil,
		context = redactValue(entry.context or {}, 0, maxDepth),
	}
end

function DiagnosticsBridge.new(diagnostics: any, config: Config?): any
	if diagnostics == nil or type(diagnostics.subscribe) ~= "function" then
		error("DiagnosticsBridge.new expects a diagnostics instance with subscribe", 2)
	end

	local bridgeConfig: any = config or {}

	local bridge: any = setmetatable({
		_diagnostics = diagnostics,
		_minRank = levelRank(bridgeConfig.level or "info"),
		_maxBatchEntries = bridgeConfig.maxBatchEntries or DEFAULT_MAX_BATCH_ENTRIES,
		_flushInterval = bridgeConfig.flushIntervalSeconds or DEFAULT_FLUSH_INTERVAL,
		_maxContextDepth = bridgeConfig.maxContextDepth or DEFAULT_MAX_CONTEXT_DEPTH,
		_clock = bridgeConfig.clock or defaultClock,
		_onBatch = bridgeConfig.onBatch,
		_pending = {},
		_seq = 0,
		_lastFlush = nil,
		_destroyed = false,
		_unsubscribe = nil,
	}, DiagnosticsBridge)

	if bridge._maxBatchEntries < 1 then
		error("DiagnosticsBridge maxBatchEntries must be at least 1", 2)
	end

	local replay = bridgeConfig.replay
	if replay == nil then
		replay = true
	end

	local subscribeFn = diagnostics.subscribe :: (any, (any) -> (), any) -> () -> ()
	bridge._unsubscribe = subscribeFn(diagnostics, function(entry)
		bridge:_add(entry)
	end, {
		replay = replay,
	})

	return bridge
end

function DiagnosticsBridge._add(self: any, entry: any)
	if self._destroyed then
		return
	end
	if levelRank(entry.level) < self._minRank then
		return
	end

	table.insert(self._pending, redactEntry(entry, self._maxContextDepth))

	if #self._pending >= self._maxBatchEntries then
		self:flush()
	end
end

function DiagnosticsBridge.pendingCount(self: any): number
	return #self._pending
end

function DiagnosticsBridge.flush(self: any, now: number?): any
	if #self._pending == 0 then
		return nil
	end

	local flushTime = now or self._clock()
	self._seq += 1
	self._lastFlush = flushTime

	local dropped = nil
	local diagnostics: any = self._diagnostics
	if type(diagnostics.droppedCount) == "function" then
		local droppedCountFn = diagnostics.droppedCount :: (any) -> number
		dropped = droppedCountFn(diagnostics)
	end

	local batch = {
		v = WIRE_VERSION,
		seq = self._seq,
		time = flushTime,
		dropped = dropped,
		entries = self._pending,
	}
	self._pending = {}

	if self._onBatch ~= nil then
		local onBatch = self._onBatch :: (any, string) -> ()
		onBatch(batch, DiagnosticsBridge.encode(batch))
	end

	return batch
end

function DiagnosticsBridge.step(self: any, now: number?): any
	if #self._pending == 0 then
		return nil
	end

	local stepTime = now or self._clock()
	if self._lastFlush ~= nil and stepTime - self._lastFlush < self._flushInterval then
		return nil
	end

	return self:flush(stepTime)
end

function DiagnosticsBridge.encode(batch: any): string
	return JsonEncode.encode(batch)
end

function DiagnosticsBridge.wireVersion(): number
	return WIRE_VERSION
end

function DiagnosticsBridge.destroy(self: any)
	if self._destroyed then
		return
	end
	self._destroyed = true
	self._pending = {}

	local unsubscribe = self._unsubscribe
	if unsubscribe ~= nil then
		(unsubscribe :: () -> ())()
		self._unsubscribe = nil
	end
end

return DiagnosticsBridge
