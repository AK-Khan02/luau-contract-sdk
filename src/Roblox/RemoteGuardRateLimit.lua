--!strict

local RateLimiter = require("../Core/RateLimiter")
local Result = require("../Core/Result")
local PlayersService = require("./PlayersService")

local RemoteGuardRateLimit = {}

local function playerBucketKey(player: any): any
	if type(player) == "table" and player.UserId ~= nil then
		return player.UserId
	end
	return player or "__anonymous"
end

local function resolvePlayersService(options: any): any
	if options.playersService ~= nil then
		return options.playersService
	end
	-- Auto-resolve the live Players service so eviction works without wiring;
	-- raw engine globals stay isolated in PlayersService.
	return PlayersService.resolve()
end

-- Config-time guard: the bucket key is chosen BEFORE payload validation, so it
-- must never be derived from client-controlled payload — that would let a
-- client mint unlimited buckets (each with a fresh budget) to bypass the limit
-- and grow memory without bound.
function RemoteGuardRateLimit.assertKey(rateLimit: any, remoteName: any)
	local key = rateLimit and rateLimit.key
	if key == nil or type(key) == "function" or key == "global" or key == "remote" then
		return
	end
	if type(key) == "string" and string.sub(key, 1, 8) == "payload." then
		error(
			"RemoteGuard rate limit for "
				.. tostring(remoteName)
				.. " cannot key on client payload ("
				.. key
				.. '); use the default actor key, "global", "remote", or a function',
			3
		)
	end
	error(
		"RemoteGuard rate limit for "
			.. tostring(remoteName)
			.. " has an invalid key "
			.. tostring(key)
			.. '; use the default actor key, "global", "remote", or a function',
		3
	)
end

function RemoteGuardRateLimit.create(rateLimit: any, clock: (() -> number)?): any
	return rateLimit and RateLimiter.new(rateLimit, clock) or nil
end

function RemoteGuardRateLimit.key(rateLimit: any, player: any, payload: any, remoteName: string): any
	local key = rateLimit and rateLimit.key
	if type(key) == "function" then
		local ok, value = pcall(key, player, payload, remoteName)
		if ok and value ~= nil then
			return value
		end
		return playerBucketKey(player)
	end
	if key == "global" then
		return "__global"
	end
	if key == "remote" then
		return remoteName
	end
	return playerBucketKey(player)
end

function RemoteGuardRateLimit.check(
	limiter: any,
	rateLimit: any,
	player: any,
	payload: any,
	remoteName: string,
	diagnostics: any,
	systemContract: any
): boolean
	if limiter == nil then
		return true
	end

	local key = RemoteGuardRateLimit.key(rateLimit, player, payload, remoteName)
	if limiter:check(key, remoteName, rateLimit) then
		return true
	end

	Result.record(diagnostics, {
		level = "error",
		category = "remote",
		system = systemContract:name(),
		name = "RemoteRateLimited",
		message = "remote rate limit exceeded: " .. tostring(remoteName),
		context = {
			player = player,
			remote = remoteName,
			key = key,
		},
	})
	return false
end

-- Evict a player's rate-limit bucket when they leave so per-player keys cannot
-- accumulate for the lifetime of the server.
function RemoteGuardRateLimit.connectPlayerEviction(limiter: any, options: any): any
	if limiter == nil then
		return nil
	end
	local players = resolvePlayersService(options)
	local removing = players and players.PlayerRemoving
	if removing == nil or type(removing.Connect) ~= "function" then
		return nil
	end
	local connect = removing.Connect :: (any, (any) -> ()) -> any
	return connect(removing, function(player: any) -- contracts-scan: ignore raw-remote-handler
		limiter:removeKey(playerBucketKey(player))
	end)
end

return RemoteGuardRateLimit
