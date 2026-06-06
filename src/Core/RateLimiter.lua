--!strict

export type Config = {
	maxRequests: number?,
	windowSeconds: number?,
}

export type Entry = {
	windowStart: number,
	count: number,
}

local RateLimiter: any = {}
RateLimiter.__index = RateLimiter
local NIL_KEY = {}

local function defaultClock(): number
	if os and os.clock then
		return os.clock()
	end
	return 0
end

function RateLimiter.new(config: Config?, clock: (() -> number)?): any
	local limiterConfig: any = config or {}

	return setmetatable({
		_defaultMaxRequests = limiterConfig.maxRequests or 10,
		_defaultWindowSeconds = limiterConfig.windowSeconds or 1,
		_clock = clock or defaultClock,
		_entries = {},
	}, RateLimiter)
end

function RateLimiter._entry(self: any, key: any, action: string): Entry
	local normalizedKey = if key == nil then NIL_KEY else key
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
		}
		keyEntries[action] = entry
	end

	return entry
end

function RateLimiter.check(self: any, key: any, action: string?, override: Config?): boolean
	local overrideConfig: any = override or {}

	local maxRequests = overrideConfig.maxRequests or self._defaultMaxRequests
	local windowSeconds = overrideConfig.windowSeconds or self._defaultWindowSeconds
	local now = self._clock()
	local entry = self:_entry(key, action or "default")

	if now - entry.windowStart >= windowSeconds then
		entry.windowStart = now
		entry.count = 0
	end

	entry.count += 1
	return entry.count <= maxRequests
end

function RateLimiter.removeKey(self: any, key: any)
	self._entries[key] = nil
end

function RateLimiter.reset(self: any)
	self._entries = {}
end

return RateLimiter
