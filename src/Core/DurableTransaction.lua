--!strict

-- DurableTransaction is a load coordinator for an action that touches more than
-- one session-locked profile -- a trade is the canonical case: move an item from
-- player A's inventory to player B's, all-or-nothing.
--
-- It is built ENTIRELY on feature 1 and deliberately owns NO commit/rollback of
-- its own. Each loaded profile is written with `scope:writeDurable`, which stages
-- an ordinary `kind = "write"` effect; EffectPlan commits those staged effects in
-- registration order and, on any later failure, compensates the already-committed
-- ones in reverse. That is the saga: A is saved, then B; if B's save fails, A's
-- durable rollback restores it. The atomicity is inherited from EffectPlan, not
-- re-implemented here.
--
-- What this coordinator DOES add is the bookkeeping around partial acquisition:
-- loading N profiles means acquiring N session locks, one yielding `store:load`
-- at a time. If the second lock is unavailable, the first is already held. The
-- transaction remembers every acquired handle and the first failure, so the
-- handler can detect the failure (`:ok()` / `:firstFailure()`) and `:release()`
-- every lock it did grab -- a half-acquired trade must not strand a lock.

local DurableProfile = require("./DurableProfile")
local Result = require("./Result")

local DurableTransaction: any = {}
DurableTransaction.__index = DurableTransaction

local ABORTED = "DurableTransactionAborted"

function DurableTransaction.new(store: any): any
	if type(store) ~= "table" or type(store.load) ~= "function" then
		error("DurableTransaction.new expects a store with a load(key) method", 2)
	end

	return setmetatable({
		_store = store,
		_profiles = {},
		_firstFailure = nil,
		_abortRecorded = false,
	}, DurableTransaction)
end

-- load acquires one more session-locked profile and remembers it. On the first
-- failure it records the failure (kept verbatim for `:firstFailure()`) and stops
-- recording further handles; subsequent `load` calls short-circuit so a trade
-- does not keep grabbing locks once it is already doomed to abort. The Result is
-- returned either way so a caller may inspect each load individually.
--
-- NOTE: once the transaction has aborted, `load` returns the FIRST failure
-- verbatim for every later call (it does not attempt the load). A caller that
-- inspects the Result of, say, the second `load` after the first already failed
-- will see that first failure's name/reason, not a fresh result for this key.
function DurableTransaction.load(self: any, key: string, options: any?): any
	-- Once the transaction has failed, do not acquire any further locks: the
	-- handler is going to abort, and another `store:load` would only take a lock
	-- we would immediately have to release. We hand back the FIRST failure
	-- verbatim (see the note above) so the abort guard stays simple.
	if self._firstFailure ~= nil then
		return self._firstFailure
	end

	local loaded = DurableProfile.load(self._store, key, options) -- yields

	if type(loaded) ~= "table" or loaded.ok ~= true then
		self._firstFailure = loaded
		return loaded
	end

	table.insert(self._profiles, loaded.profile)
	return loaded
end

-- ok reports whether every load so far succeeded. The canonical guard is
-- `if not txn:ok() then error(txn:firstFailure()) end` right after the loads.
function DurableTransaction.ok(self: any): boolean
	return self._firstFailure == nil
end

-- firstFailure returns the first failing load Result (verbatim, e.g. a
-- SessionLockUnavailable), or nil when every load succeeded.
function DurableTransaction.firstFailure(self: any): any?
	return self._firstFailure
end

-- profiles returns the loaded handles in load order. Callers normally hold their
-- own references; this is for inspection and symmetry.
function DurableTransaction.profiles(self: any): { any }
	local out = {}
	for _, profile in ipairs(self._profiles) do
		table.insert(out, profile)
	end
	return out
end

-- release frees every lock this transaction acquired. It is the abort handler:
-- when a later load fails, the earlier loads still hold their locks, and calling
-- release frees them so a half-acquired trade strands nothing. It is idempotent
-- (DurableProfile.release no-ops once released) and aggregates per-handle release
-- failures rather than stopping at the first.
--
-- When the transaction is in a failed state, release also records the
-- `DurableTransactionAborted` rollup at warn level (if a diagnostics sink is
-- given), giving the abort path a single clean diagnostic to assert on -- the
-- multi-profile analogue of `ActionEagerEffectsNotRolledBack`. The rollup is
-- recorded at most once even if `release` is called repeatedly (an `_abortRecorded`
-- latch), so a defensive double-release does not double-count the abort.
function DurableTransaction.release(self: any, diagnostics: any?): any
	local failures = {}
	local released = 0

	for _, entry in ipairs(self._profiles) do
		local profile: any = entry
		if type(profile) == "table" and type(profile.release) == "function" then
			-- Skip handles already released so a second `release()` reports zero
			-- freed locks rather than re-counting; release stays idempotent.
			local alreadyReleased = false
			if type(profile.released) == "function" then
				local releasedFn = profile.released :: (any) -> any
				alreadyReleased = releasedFn(profile) == true
			end

			if not alreadyReleased then
				local releaseFn = profile.release :: (any) -> any
				local result = releaseFn(profile)
				if type(result) == "table" and result.ok == false then
					table.insert(failures, result)
				else
					released += 1
				end
			end
		end
	end

	if self._firstFailure ~= nil and not self._abortRecorded then
		self._abortRecorded = true
		local failureName = "the durable transaction"
		if type(self._firstFailure) == "table" and type(self._firstFailure.name) == "string" then
			failureName = self._firstFailure.name
		end
		Result.record(diagnostics, {
			level = "warn",
			category = "effect",
			name = ABORTED,
			message = "durable transaction aborted after "
				.. failureName
				.. "; released "
				.. tostring(released)
				.. " already-acquired lock(s)",
			context = {
				released = released,
				acquired = #self._profiles,
			},
		})
	end

	if #failures > 0 then
		return Result.fail("DurableReleaseFailed", "one or more profile locks failed to release", {
			released = released,
			failures = failures,
		})
	end

	return Result.ok(nil, {
		name = "DurableTransactionReleased",
		released = released,
	})
end

DurableTransaction.ABORTED = ABORTED

return DurableTransaction
