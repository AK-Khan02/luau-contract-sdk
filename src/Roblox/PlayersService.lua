--!nocheck
--!nolint UnknownGlobal

-- Resolves the Players service from the engine global, isolated here so the
-- type-checked guard code never references `game` directly (mirrors
-- TaskScheduler.default for the `task` global).
local PlayersService = {}

function PlayersService.resolve()
	local ok, players = pcall(function()
		return game:GetService("Players")
	end)
	if ok then
		return players
	end
	return nil
end

return PlayersService
