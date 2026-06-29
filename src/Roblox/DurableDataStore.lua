--!strict

-- DurableDataStore is the Roblox adapter that implements the injected `DurableStore`
-- interface (load / save / release / owns) over a DataStore-like object. The
-- core modules (DurableEffect, DurableProfile) never see this file: they take an
-- injected store and duck-type it, and tests supply an in-memory fake. This
-- adapter is the one place that touches the real engine, so every engine call is
-- wrapped in `pcall` and a clear "pass a dataStore" error is raised when run
-- outside Roblox -- mirroring StudioBridgePublisher and Ownership.
--
-- Session locking uses a compare-and-set on a stored envelope:
--   { lockId = <opaque>, lockedAt = <number>, value = <data> }
-- `load` claims the lock through UpdateAsync (atomic on the DataStore), `save`
-- and `release` verify the in-memory lockId still matches the stored one before
-- mutating, and `owns` reports whether this adapter still believes it holds the
-- lock. The lock token handed back to the core is opaque: the core only passes
-- it back to save/release/owns and never inspects it.

local Result = require("../Core/Result")
local PlayersService = require("./PlayersService")

local DurableDataStore: any = {}
DurableDataStore.__index = DurableDataStore

local LOCK_UNAVAILABLE = "SessionLockUnavailable"
local LOCK_LOST = "SessionLockLost"
local COMMIT_FAILED = "DurableCommitFailed"

local function clock(): number
	if os and type(os.time) == "function" then
		local ok, value = pcall(function()
			return os.time()
		end)
		if ok and type(value) == "number" then
			return value
		end
	end
	return 0
end

local lockCounter = 0

local function newLockId(jobId: any): string
	local prefix = "lock"
	if jobId ~= nil then
		prefix = tostring(jobId)
	end
	lockCounter += 1
	-- jobId distinguishes servers; the process-local counter guarantees two locks
	-- minted in the same second on one server never collide even if math.random does.
	return prefix .. "-" .. tostring(clock()) .. "-" .. tostring(lockCounter) .. "-" .. tostring(math.random(1, 1e9))
end

local function isDataStore(dataStore: any): boolean
	return type(dataStore) == "table"
		and type(dataStore.UpdateAsync) == "function"
		and type(dataStore.GetAsync) == "function"
end

function DurableDataStore.new(dataStore: any, options: any?): any
	if not isDataStore(dataStore) then
		error(
			"DurableDataStore needs a DataStore; pass dataStore (a DataStore-like object with UpdateAsync/GetAsync)",
			2
		)
	end

	local config = options or {}

	return setmetatable({
		_dataStore = dataStore,
		_jobId = config.jobId or PlayersService.jobId(),
		_locks = {},
		_lockTimeoutSeconds = config.lockTimeoutSeconds or 0,
	}, DurableDataStore)
end

local function envelopeValue(envelope: any): any
	if type(envelope) == "table" then
		return envelope.value
	end
	return nil
end

local function lockHeld(envelope: any, now: number, timeout: number): boolean
	if type(envelope) ~= "table" or envelope.lockId == nil then
		return false
	end
	if timeout > 0 and type(envelope.lockedAt) == "number" and now - envelope.lockedAt >= timeout then
		return false
	end
	return true
end

function DurableDataStore.load(self: any, key: string): any
	local updateAsync = self._dataStore.UpdateAsync :: (any, string, (any) -> any) -> (any, any)
	local now = clock()
	local lockId = newLockId(self._jobId)

	local ok, updated = pcall(function()
		return updateAsync(self._dataStore, key, function(current: any): any
			if lockHeld(current, now, self._lockTimeoutSeconds) and current.lockId ~= lockId then
				-- Another live server holds the lock: refuse by returning nil so
				-- UpdateAsync aborts without writing.
				return nil
			end

			local envelope = {
				lockId = lockId,
				lockedAt = now,
				value = envelopeValue(current),
			}
			return envelope
		end)
	end)

	if not ok then
		return Result.fail(COMMIT_FAILED, tostring(updated), {
			key = key,
		})
	end

	if type(updated) ~= "table" or updated.lockId ~= lockId then
		return Result.fail(LOCK_UNAVAILABLE, "another server holds the session lock for " .. key, {
			key = key,
		})
	end

	local lock = {
		lockId = lockId,
		key = key,
	}
	self._locks[key] = lockId

	-- The loaded value must be Result.ok's first positional arg: Result.ok sets
	-- result.value = arg AFTER copying fields, so passing it inside `fields` would
	-- be clobbered back to nil (callers would see an empty profile).
	return Result.ok(updated.value, {
		name = "DurableLoaded",
		lock = lock,
	})
end

function DurableDataStore.owns(self: any, key: string, lock: any): boolean
	if type(lock) ~= "table" or lock.lockId == nil then
		return false
	end
	return self._locks[key] == lock.lockId
end

function DurableDataStore.save(self: any, key: string, value: any, lock: any): any
	if not self:owns(key, lock) then
		return Result.fail(LOCK_LOST, "session lock no longer held for " .. key, {
			key = key,
		})
	end

	local updateAsync = self._dataStore.UpdateAsync :: (any, string, (any) -> any) -> (any, any)
	local lockId = lock.lockId

	local ok, result = pcall(function()
		return updateAsync(self._dataStore, key, function(current: any): any
			if type(current) ~= "table" or current.lockId ~= lockId then
				-- The stored lock is no longer exactly ours (released -> lockId nil,
				-- expired and reclaimed, stolen, or reset under us): refuse so we
				-- never overwrite another server's committed data. The in-memory
				-- `owns` guard cannot see this; the stored envelope is the authority.
				return nil
			end
			return {
				lockId = lockId,
				lockedAt = clock(),
				value = value,
			}
		end)
	end)

	if not ok then
		return Result.fail(COMMIT_FAILED, tostring(result), {
			key = key,
		})
	end

	if type(result) ~= "table" or result.lockId ~= lockId then
		self._locks[key] = nil
		return Result.fail(LOCK_LOST, "session lock was taken during save for " .. key, {
			key = key,
		})
	end

	return Result.ok(nil, {
		name = "DurableSaved",
	})
end

function DurableDataStore.release(self: any, key: string, lock: any): any
	if not self:owns(key, lock) then
		-- Releasing a lock we no longer hold is a no-op success: the goal (we are
		-- not holding it) is already met.
		self._locks[key] = nil
		return Result.ok(nil, {
			name = "DurableReleased",
		})
	end

	local updateAsync = self._dataStore.UpdateAsync :: (any, string, (any) -> any) -> (any, any)
	local lockId = lock.lockId

	local ok, result = pcall(function()
		return updateAsync(self._dataStore, key, function(current: any): any
			if type(current) ~= "table" or current.lockId ~= lockId then
				return nil
			end
			return {
				lockId = nil,
				lockedAt = nil,
				value = current.value,
			}
		end)
	end)

	self._locks[key] = nil

	if not ok then
		return Result.fail(COMMIT_FAILED, tostring(result), {
			key = key,
		})
	end

	return Result.ok(nil, {
		name = "DurableReleased",
	})
end

return DurableDataStore
