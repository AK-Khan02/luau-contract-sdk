--!nonstrict

local Contracts = require("../../src/Contracts")
local ProfileSessionStore = Contracts.Roblox.ProfileSessionStore

-- Fake profile-session library shaped like the newer ProfileStore:
-- store:StartSessionAsync(key) -> profile; profile.Data; profile:IsActive(); profile:EndSession().
local FakeProfile = {}
FakeProfile.__index = FakeProfile
function FakeProfile.new(data)
	return setmetatable({ Data = data, _active = true }, FakeProfile)
end
function FakeProfile.IsActive(self)
	return self._active
end
function FakeProfile.EndSession(self)
	self._active = false
end

local FakeLib = {}
FakeLib.__index = FakeLib
function FakeLib.new()
	return setmetatable({ _data = {}, _sessions = {} }, FakeLib)
end
function FakeLib.seed(self, key, data)
	self._data[key] = data
end
function FakeLib.StartSessionAsync(self, key)
	local existing = self._sessions[key]
	if existing ~= nil and existing._active then
		return nil -- another live session already holds it
	end
	local profile = FakeProfile.new(self._data[key] or {})
	self._sessions[key] = profile
	return profile
end

-- Second fake shaped like classic ProfileService:
-- store:LoadProfileAsync(key, handler) -> profile; profile:Release(); profile:IsActive().
local LegacyProfile = {}
LegacyProfile.__index = LegacyProfile
function LegacyProfile.new(data)
	return setmetatable({ Data = data, _active = true }, LegacyProfile)
end
function LegacyProfile.IsActive(self)
	return self._active
end
function LegacyProfile.Release(self)
	self._active = false
end

local LegacyLib = {}
LegacyLib.__index = LegacyLib
function LegacyLib.new()
	return setmetatable({ _sessions = {} }, LegacyLib)
end
function LegacyLib.LoadProfileAsync(self, key, _handler)
	local existing = self._sessions[key]
	if existing ~= nil and existing._active then
		return nil
	end
	local profile = LegacyProfile.new({})
	self._sessions[key] = profile
	return profile
end

local Output = Contracts.object({ ok = Contracts.boolean() }, { allowExtra = false })

return function(test)
	local function check(name, condition, detail)
		test:check(name, condition, detail)
	end

	test:section("ProfileSessionStore")

	-- new() rejects a non-profile-store object.
	test:expectError("new rejects a non-profile-store object", "ProfileSessionStore needs", function()
		ProfileSessionStore.new({})
	end)

	-- Delegation round-trip over the StartSessionAsync (ProfileStore) shape.
	do
		local lib = FakeLib.new()
		lib:seed("Player_1", { coins = 5 })
		local store = ProfileSessionStore.new(lib)

		local loaded = store:load("Player_1")
		check("load delegates to StartSessionAsync", loaded.ok == true and loaded.name == "DurableLoaded", loaded.name)
		check("load returns the session's data", loaded.value ~= nil and loaded.value.coins == 5)
		-- Detached: mutating the loaded value must NOT touch the live session yet.
		loaded.value.coins = 999
		check("load hands back a detached copy (deferred, not eager)", lib._sessions.Player_1.Data.coins == 5)

		local saved = store:save("Player_1", { coins = 10 }, loaded.lock)
		check(
			"save applies the staged value to the held profile's Data",
			saved.ok == true and lib._sessions.Player_1.Data.coins == 10
		)

		local released = store:release("Player_1", loaded.lock)
		check("release ends the session", released.ok == true and lib._sessions.Player_1:IsActive() == false)
	end

	-- Contention: a second session while the first is active is refused.
	do
		local lib = FakeLib.new()
		local store = ProfileSessionStore.new(lib)
		local a = store:load("Player_2")
		check("first session acquires", a.ok == true)
		local b = store:load("Player_2")
		check(
			"second session refused (SessionLockUnavailable)",
			b.ok == false and b.name == "SessionLockUnavailable",
			b.name
		)
	end

	-- Fail-closed: a save against an ended session is refused (SessionLockLost).
	do
		local lib = FakeLib.new()
		local store = ProfileSessionStore.new(lib)
		local loaded = store:load("Player_3")
		lib._sessions.Player_3:EndSession() -- the library released the session under us
		local saved = store:save("Player_3", { coins = 1 }, loaded.lock)
		check("save on a dead session fails closed", saved.ok == false and saved.name == "SessionLockLost", saved.name)
		check("owns reflects the ended session", store:owns("Player_3", loaded.lock) == false)
	end

	-- Works with the classic ProfileService shape too (LoadProfileAsync / Release).
	do
		local lib = LegacyLib.new()
		local store = ProfileSessionStore.new(lib)
		local loaded = store:load("Player_4")
		check("load delegates to LoadProfileAsync", loaded.ok == true, loaded.name)
		local saved = store:save("Player_4", { coins = 3 }, loaded.lock)
		check("save works over the legacy shape", saved.ok == true and lib._sessions.Player_4.Data.coins == 3)
		store:release("Player_4", loaded.lock)
		check("release uses Release() on the legacy shape", lib._sessions.Player_4:IsActive() == false)
	end

	-- End-to-end: a durable write through a runtime action commits to the session.
	do
		local lib = FakeLib.new()
		lib:seed("Player_5", { coins = 0 })
		local store = ProfileSessionStore.new(lib)
		local system = Contracts.system("ProfileSessionDurable")
			:strictPermissions()
			:mayWrite("Player.Profile")
			:action("Grant", { output = Output, writes = { "Player.Profile" } })

		local loaded = Contracts.loadProfile(store, "Player_5")
		check("end-to-end loadProfile succeeds", loaded.ok == true, loaded.name)
		local result = system:runAction("Grant", { context = {} }, function(scope)
			scope:writeDurable("Player.Profile", loaded.profile, function(data)
				data.coins = data.coins + 50
				return data
			end)
			return { ok = true }
		end)
		check("durable action through ProfileSessionStore succeeds", result.ok == true, result.name)
		check("commit applied to the held session's Data", lib._sessions.Player_5.Data.coins == 50)
		loaded.profile:release()
	end
end
