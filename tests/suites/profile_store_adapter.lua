--!nonstrict

local Contracts = require("../../src/Contracts")
local ProfileStore = Contracts.Roblox.ProfileStore

-- Fake DataStore exposing the minimal UpdateAsync/GetAsync surface ProfileStore
-- needs, with REAL UpdateAsync semantics: the transform receives the current
-- value, and returning nil cancels the write (UpdateAsync then yields the
-- unchanged value). This lets the suite exercise the real adapter's session-lock
-- compare-and-set -- which the DurableStore fake in durable_effects.lua bypasses
-- entirely, and which is where a released-lock overwrite bug can hide.
local FakeDataStore = {}
FakeDataStore.__index = FakeDataStore

local function newDataStore()
	return setmetatable({ store = {} }, FakeDataStore)
end

function FakeDataStore.UpdateAsync(self, key, transform)
	local current = self.store[key]
	local updated = transform(current)
	if updated == nil then
		-- Roblox cancels the update and returns the unchanged value.
		return current
	end
	self.store[key] = updated
	return updated
end

function FakeDataStore.GetAsync(self, key)
	return self.store[key]
end

-- Model another server having held the lock, written a value, then released it:
-- the stored envelope keeps the value but clears lockId.
local function seedReleased(ds, key, value)
	ds.store[key] = { lockId = nil, lockedAt = nil, value = value }
end

-- Model another server currently holding the lock with a value.
local function seedLockedBy(ds, key, lockId, value)
	ds.store[key] = { lockId = lockId, lockedAt = 0, value = value }
end

return function(test)
	local function check(name, condition)
		test:check(name, condition)
	end

	test:section("ProfileStoreAdapter")

	-- new() rejects a non-DataStore with a clear message.
	test:expectError("new rejects a non-DataStore", "ProfileStore needs a DataStore", function()
		ProfileStore.new(nil)
	end)

	-- Round-trip: load claims the lock, save persists, release frees it.
	do
		local ds = newDataStore()
		seedReleased(ds, "Player_1", { coins = 5 })
		local server = ProfileStore.new(ds, { jobId = "A" })

		local loaded = server:load("Player_1")
		check("load claims the lock", loaded.ok == true and loaded.name == "DurableLoaded")
		check("load returns the stored value", loaded.value ~= nil and loaded.value.coins == 5)

		local saved = server:save("Player_1", { coins = 10 }, loaded.lock)
		check("save under a held lock succeeds", saved.ok == true)
		check("save persists the new value", ds.store.Player_1.value.coins == 10)

		local released = server:release("Player_1", loaded.lock)
		check("release succeeds", released.ok == true)
		check("release clears the stored lock", ds.store.Player_1.lockId == nil)
	end

	-- Two servers (vector a): the second cannot load while the first holds the lock.
	do
		local ds = newDataStore()
		seedReleased(ds, "Player_1", { coins = 5 })
		local serverA = ProfileStore.new(ds, { jobId = "A" })
		local serverB = ProfileStore.new(ds, { jobId = "B" })

		local a = serverA:load("Player_1")
		check("first server loads", a.ok == true)

		local b = serverB:load("Player_1")
		check("second server is refused while the lock is held", b.ok == false and b.name == "SessionLockUnavailable")

		serverA:release("Player_1", a.lock)
		local b2 = serverB:load("Player_1")
		check("second server loads after release", b2.ok == true)
	end

	-- MAJOR regression: a stalled server whose lock was released-then-reclaimed must
	-- FAIL CLOSED on save, never overwriting the other server's committed value.
	-- Pre-fix the CAS only refused on a *different non-nil* lockId, so a released
	-- lock (lockId nil) let the stale write clobber the data -- the exact dupe vector
	-- the feature exists to prevent. This test fails pre-fix, passes post-fix.
	do
		local ds = newDataStore()
		seedReleased(ds, "Player_1", { coins = 5 })
		local server = ProfileStore.new(ds, { jobId = "A" })

		local loaded = server:load("Player_1")
		check("stale-save setup loads", loaded.ok == true)

		-- Another server takes over, writes 999, and releases: the stored envelope
		-- now carries a value but no lock. Our in-memory lock still believes it owns
		-- the record (the very condition that hid the bug).
		seedReleased(ds, "Player_1", { coins = 999 })

		local saved = server:save("Player_1", { coins = 1 }, loaded.lock)
		check("stale save fails closed (SessionLockLost)", saved.ok == false and saved.name == "SessionLockLost")
		check("stale save does NOT overwrite the other server's value", ds.store.Player_1.value.coins == 999)
		check("stale save drops in-memory ownership", server:owns("Player_1", loaded.lock) == false)
	end

	-- Stolen lock (a different, non-nil lockId) also fails closed.
	do
		local ds = newDataStore()
		seedReleased(ds, "Player_1", { coins = 5 })
		local server = ProfileStore.new(ds, { jobId = "A" })
		local loaded = server:load("Player_1")

		seedLockedBy(ds, "Player_1", "ServerB-lock", { coins = 500 })

		local saved = server:save("Player_1", { coins = 1 }, loaded.lock)
		check("stolen-lock save fails closed", saved.ok == false and saved.name == "SessionLockLost")
		check("stolen-lock save preserves the holder's value", ds.store.Player_1.value.coins == 500)
	end

	-- Expired lock can be reclaimed by another server (lockTimeoutSeconds): an
	-- envelope locked "long ago" (lockedAt = 0) is treated as stale on load.
	do
		local ds = newDataStore()
		seedLockedBy(ds, "Player_1", "StaleServer", { coins = 7 })
		local server = ProfileStore.new(ds, { jobId = "A", lockTimeoutSeconds = 1 })

		local loaded = server:load("Player_1")
		check("expired lock is reclaimable", loaded.ok == true and loaded.value ~= nil and loaded.value.coins == 7)
	end
end
