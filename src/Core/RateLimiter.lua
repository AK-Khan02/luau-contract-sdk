--!strict

export type Config = {
	maxRequests: number?,
	windowSeconds: number?,
	sweepIntervalSeconds: number?,
}

export type Entry = {
	windowStart: number,
	count: number,
	windowSeconds: number,
}

local RateLimiter: any = {}
RateLimiter.__index = RateLimiter
local NIL_KEY = {}
local DEFAULT_SWEEP_INTERVAL = 30

local function defaultClock(): number
	-- Wall-clock seconds. os.clock() reports process CPU time, which advances
	-- slower than real time and drifts under load, so it must never gate
	-- rate-limit windows.
	if os and os.time then
		return os.time()
	end
	return 0
end

local function normalizeKey(key: any): any
	if key == nil then
		return NIL_KEY
	end
	return key
end

function RateLimiter.new(config: Config?, clock: (() -> number)?): any
	local limiterConfig: any = config or {}

	return setmetatable({
		_defaultMaxRequests = limiterConfig.maxRequests or 10,
		_defaultWindowSeconds = limiterConfig.windowSeconds or 1,
		_sweepInterval = limiterConfig.sweepIntervalSeconds or DEFAULT_SWEEP_INTERVAL,
		_clock = clock or defaultClock,
		_entries = {},
		_lastSweep = nil,
	}, RateLimiter)
end

function RateLimiter._entry(self: any, key: any, action: string): Entry
	local normalizedKey = normalizeKey(key)
	local keyEntries = self._entries[normalizedKey]
	if not keyEntries then
		keyEntries = {}
		self._entries[normalizedKey] = keyEntries
	end

	local entry = keyEntries[action]
	if not entry then
		entry = {
			windowStart = self._clock(),
			count = 0,
			windowSeconds = self._defaultWindowSeconds,
		}
		keyEntries[action] = entry
	end

	return entry
end

-- Drop keys whose every action window has fully elapsed. Such an entry would
-- reset its count on its next check anyway, so eviction never changes a
-- rate-limit decision — it only reclaims memory from keys (e.g. departed
-- players) that may never be checked again.
function RateLimiter._maybeSweep(self: any, now: number)
	if self._lastSweep == nil then
		self._lastSweep = now
		return
	end
	if now - self._lastSweep < self._sweepInterval then
		return
	end
	self._lastSweep = now

	for key, keyEntries in pairs(self._entries) do
		local active = false
		for _, entry in pairs(keyEntries) do
			if now - entry.windowStart < entry.windowSeconds then
				active = true
				break
			end
		end
		if not active then
			self._entries[key] = nil
		end
	end
end

function RateLimiter.check(self: any, key: any, action: string?, override: Config?): boolean
	local overrideConfig: any = override or {}

	local maxRequests = overrideConfig.maxRequests or self._defaultMaxRequests
	local windowSeconds = overrideConfig.windowSeconds or self._defaultWindowSeconds
	local now = self._clock()
	local entry = self:_entry(key, action or "default")
	entry.windowSeconds = windowSeconds

	if now - entry.windowStart >= windowSeconds then
		entry.windowStart = now
		entry.count = 0
	end

	entry.count += 1
	self:_maybeSweep(now)
	return entry.count <= maxRequests
end

function RateLimiter.removeKey(self: any, key: any)
	self._entries[normalizeKey(key)] = nil
end

function RateLimiter.keyCount(self: any): number
	local count = 0
	for _ in pairs(self._entries) do
		count += 1
	end
	return count
end

function RateLimiter.reset(self: any)
	self._entries = {}
	self._lastSweep = nil
end

return RateLimiter
