--!strict

-- DurableProfile is a thin stateful handle for one session-locked record, held
-- for the duration of an action -- the persistence analogue of LifecycleSession.
-- `DurableProfile.load` acquires the session lock (yields via `store:load`) and
-- hands back a handle whose staged value is written with `scope:writeDurable`.
--
-- The store is injected and duck-typed, so DurableProfile never depends on
-- `DataStoreService` and is fully testable against a fake.
--
-- Reconcile / migration hook: `options.template` and `options.migrations` are
-- the seam for schema reconciliation. Feature 1 ships the plumbing inert -- the
-- guarded `Reconcile` require resolves to nothing until that module exists, so
-- the hook is a structural no-op now and becomes purely additive later. The
-- "release the freshly taken lock when load-time reconciliation fails" branch is
-- in place now too, so no lock can leak once reconciliation is real.

local Result = require("./Result")

local DurableProfile: any = {}
DurableProfile.__index = DurableProfile

local LOAD_FAILED = "SessionLockUnavailable"

-- Resolve the (optional) Reconcile module without a hard dependency. Feature 1
-- ships no such module, so this stays nil and the reconcile/migrate hook below
-- never fires. Feature 3 adds src/Core/Reconcile.lua and this require resolves.
local function resolveReconcile(): any?
	local ok, module = pcall(require, "./Reconcile")
	if ok then
		return module
	end
	return nil
end

local Reconcile: any? = resolveReconcile()

local function releaseLock(store: any, key: string, lock: any)
	if type(store.release) ~= "function" then
		return
	end
	local releaseFn = store.release :: (any, string, any) -> any
	pcall(releaseFn, store, key, lock)
end

-- reconcile applies the (inert in feature 1) template fill + migrations to the
-- freshly loaded value. On failure it releases the just-acquired lock so a
-- rejected migration never strands a session lock, then returns the failure.
local function reconcile(store: any, key: string, lock: any, value: any, options: any): any
	if options.template == nil and options.migrations == nil then
		return Result.ok(value)
	end

	local module: any = Reconcile
	if module == nil then
		-- No Reconcile module is shipped yet; options are accepted but inert.
		return Result.ok(value)
	end

	local reconciled = value
	if options.template ~= nil and type(module.fill) == "function" then
		local fill = module.fill :: (any, any) -> any
		reconciled = fill(reconciled, options.template)
	end

	if options.migrations ~= nil and type(module.migrate) == "function" then
		local migrate = module.migrate :: (any, any, any) -> any
		local migrated = migrate(reconciled, options.migrations, options)
		if type(migrated) == "table" then
			if migrated.ok == false then
				releaseLock(store, key, lock)
				return migrated
			end
			-- Take the migrated value even when it is falsy: a migration that
			-- legitimately resolves to nil/false must not be silently dropped.
			reconciled = migrated.value
		end
	end

	return Result.ok(reconciled)
end

function DurableProfile.load(store: any, key: string, options: any?): any
	if type(store) ~= "table" or type(store.load) ~= "function" then
		error("DurableProfile.load expects a store with a load(key) method", 2)
	end
	if type(key) ~= "string" or key == "" then
		error("DurableProfile.load expects a non-empty key", 2)
	end

	local config = options or {}

	local loadFn = store.load :: (any, string) -> any
	local loaded = loadFn(store, key) -- yields

	if type(loaded) ~= "table" or loaded.ok ~= true then
		local name = "SessionLockUnavailable"
		local reason = "could not load durable profile " .. key
		if type(loaded) == "table" then
			if type(loaded.name) == "string" then
				name = loaded.name
			end
			if loaded.reason ~= nil then
				reason = tostring(loaded.reason)
			end
		end
		return Result.fail(name, reason, {
			key = key,
		})
	end

	local reconciled = reconcile(store, key, loaded.lock, loaded.value, config)
	if reconciled.ok == false then
		return reconciled
	end

	local handle = setmetatable({
		_store = store,
		_key = key,
		_lock = loaded.lock,
		_value = reconciled.value,
		_released = false,
	}, DurableProfile)

	return Result.ok(nil, {
		name = "DurableProfileLoaded",
		profile = handle,
	})
end

function DurableProfile.key(self: any): string
	return self._key
end

function DurableProfile.value(self: any): any
	return self._value
end

function DurableProfile.lock(self: any): any
	return self._lock
end

function DurableProfile.store(self: any): any
	return self._store
end

function DurableProfile.set(self: any, value: any)
	self._value = value
end

function DurableProfile.released(self: any): boolean
	return self._released == true
end

function DurableProfile.release(self: any): any
	if self._released then
		return Result.ok(nil, {
			name = "DurableProfileReleased",
		})
	end

	self._released = true

	local store: any = self._store
	if type(store.release) ~= "function" then
		return Result.ok(nil, {
			name = "DurableProfileReleased",
		})
	end

	local releaseFn = store.release :: (any, string, any) -> any
	local ok, result = pcall(releaseFn, store, self._key, self._lock)
	if not ok then
		return Result.fail("DurableReleaseFailed", tostring(result), {
			key = self._key,
		})
	end

	if type(result) == "table" and result.ok == false then
		return result
	end

	return Result.ok(nil, {
		name = "DurableProfileReleased",
	})
end

-- Kept for symmetry with the load-failure path documented above; reused by
-- DurableTransaction (feature 2) when aborting after a partial set of loads.
DurableProfile.LOAD_FAILED = LOAD_FAILED

return DurableProfile
