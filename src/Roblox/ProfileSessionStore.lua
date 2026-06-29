--!strict

-- ProfileSessionStore is the RECOMMENDED durable adapter. Instead of reimplementing
-- session locking over DataStore (that is DurableDataStore, the zero-dependency
-- fallback), it DELEGATES to a battle-tested profile-session library -- ProfileService
-- (LoadProfileAsync / profile:Release) or its successor ProfileStore
-- (StartSessionAsync / profile:EndSession). The injected store is duck-typed, so the
-- SDK depends on neither library directly and the adapter is testable against a fake.
--
-- The point: the SDK's value sits ON TOP of the data layer you already trust. It uses
-- that library's session as the lock -- so there is nothing to "swap" -- and layers
-- the transactional / multi-profile-trade / contract envelope over it. `load` hands
-- back a DETACHED copy of `profile.Data`; `save` applies the staged value to
-- `profile.Data` only at the commit boundary (durable writes stay deferred, never
-- eager); and ownership is the library's own `profile:IsActive()`, so if the session
-- ended (e.g. the player left and the library released it) a durable write fails
-- closed with SessionLockLost instead of writing to a dead session. The library --
-- not this adapter -- owns the actual disk writes, so saves are batched and
-- rate-limit-safe rather than one DataStore request per action.

local Result = require("../Core/Result")
local TableUtil = require("../Core/TableUtil")

local ProfileSessionStore: any = {}
ProfileSessionStore.__index = ProfileSessionStore

local LOCK_UNAVAILABLE = "SessionLockUnavailable"
local LOCK_LOST = "SessionLockLost"

local function isProfileStoreLike(store: any): boolean
	return type(store) == "table"
		and (type(store.StartSessionAsync) == "function" or type(store.LoadProfileAsync) == "function")
end

function ProfileSessionStore.new(profileStore: any, options: any?): any
	if not isProfileStoreLike(profileStore) then
		error(
			"ProfileSessionStore needs a ProfileService/ProfileStore-like object "
				.. "(with StartSessionAsync or LoadProfileAsync)",
			2
		)
	end

	local config = options or {}

	return setmetatable({
		_store = profileStore,
		-- ProfileService's LoadProfileAsync wants a not-released handler; default to
		-- failing closed ("Cancel") rather than stealing another server's live session.
		_notReleasedHandler = config.notReleasedHandler or function()
			return "Cancel"
		end,
		-- ProfileStore's StartSessionAsync takes an optional params table.
		_sessionParams = config.sessionParams,
	}, ProfileSessionStore)
end

function ProfileSessionStore.load(self: any, key: string): any
	local store = self._store
	local profile: any
	if type(store.StartSessionAsync) == "function" then
		local startSession = store.StartSessionAsync :: (any, string, any) -> any
		profile = startSession(store, key, self._sessionParams)
	else
		local loadProfile = store.LoadProfileAsync :: (any, string, any) -> any
		profile = loadProfile(store, key, self._notReleasedHandler)
	end

	if profile == nil then
		return Result.fail(LOCK_UNAVAILABLE, "another live session holds " .. key, {
			key = key,
		})
	end

	-- Detached copy: the handler mutates this freely; the live session is only
	-- touched at commit (via save), keeping durable writes deferred, not eager.
	return Result.ok(TableUtil.deepCopy(profile.Data), {
		name = "DurableLoaded",
		lock = profile,
	})
end

function ProfileSessionStore.owns(_self: any, _key: string, lock: any): boolean
	if type(lock) ~= "table" or type(lock.IsActive) ~= "function" then
		return false
	end
	local isActive = lock.IsActive :: (any) -> any
	return isActive(lock) == true
end

function ProfileSessionStore.save(self: any, key: string, value: any, lock: any): any
	if not self:owns(key, lock) then
		return Result.fail(LOCK_LOST, "profile session is no longer active for " .. key, {
			key = key,
		})
	end
	-- Apply the staged value to the held profile; the library persists it on its own
	-- batched autosave / on release. Copy so a later mutation of `value` cannot
	-- alias the committed data.
	lock.Data = TableUtil.deepCopy(value)
	return Result.ok(nil, {
		name = "DurableSaved",
	})
end

function ProfileSessionStore.release(_self: any, _key: string, lock: any): any
	if type(lock) == "table" then
		if type(lock.EndSession) == "function" then
			local endSession = lock.EndSession :: (any) -> any
			endSession(lock)
		elseif type(lock.Release) == "function" then
			local release = lock.Release :: (any) -> any
			release(lock)
		end
	end
	return Result.ok(nil, {
		name = "DurableReleased",
	})
end

return ProfileSessionStore
