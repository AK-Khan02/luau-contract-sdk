--!strict
--!nolint UnknownGlobal

-- Isolates raw Roblox globals so type-checked modules never reference `game`,
-- `task`, or `Instance` directly.
local PlayersService = {}

local function robloxGlobal(name: string): any?
	local ok, env = pcall(getfenv, 0)
	if not ok or type(env) ~= "table" then
		return nil
	end
	return (env :: any)[name]
end

function PlayersService.resolve(): any?
	return PlayersService.resolveService("Players")
end

function PlayersService.resolveService(name: string): any?
	local robloxGame = robloxGlobal("game")
	if robloxGame == nil or type(robloxGame.GetService) ~= "function" then
		return nil
	end
	local getService = robloxGame.GetService :: (any, string) -> any
	local ok, players = pcall(function()
		return getService(robloxGame, name)
	end)
	if ok then
		return players
	end
	return nil
end

function PlayersService.resolveTaskLibrary(): any?
	return robloxGlobal("task")
end

function PlayersService.createInstance(className: string): any
	local instance = robloxGlobal("Instance")
	if instance == nil or type(instance.new) ~= "function" then
		error("PlayersService.createInstance needs Roblox Instance.new", 2)
	end
	local create = instance.new :: (string) -> any
	return create(className)
end

function PlayersService.jobId(): any?
	local robloxGame = robloxGlobal("game")
	if robloxGame == nil then
		return nil
	end
	local ok, jobId = pcall(function()
		return robloxGame.JobId
	end)
	if ok then
		return jobId
	end
	return nil
end

function PlayersService.placeVersion(): any?
	local robloxGame = robloxGlobal("game")
	if robloxGame == nil then
		return nil
	end
	local ok, placeVersion = pcall(function()
		return robloxGame.PlaceVersion
	end)
	if ok then
		return placeVersion
	end
	return nil
end

return PlayersService
