--!strict

-- DurableEffect turns a durable write request into the staged
-- `{ commit, rollback, metadata }` table that `EffectPlan.stage` understands.
--
-- It performs NO I/O itself and never requires `DataStoreService`: the durable
-- store is injected and duck-typed, so the builder is unit-testable against a
-- fake. The staged operation runs at the action's commit boundary and is undone
-- by its rollback if a later step fails, so a durable write is transactional in
-- exactly the same way `scope:write` is -- it is never eager.
--
-- Concurrency: a DataStore save yields, and another server could have stolen the
-- session lock during the action. The commit re-verifies ownership both before
-- the save (pre-yield guard) and via `store:save`, and fails closed with
-- `SessionLockLost` rather than double-committing. The compensating value is
-- captured at STAGE time so rollback never has to re-read (which would yield
-- again across an even wider window).

local DurableEffect = {}

local LOCK_LOST = "SessionLockLost"
local COMMIT_FAILED = "DurableCommitFailed"

-- The post-commit scan in ActionRunnerCompletion reads the durable failure name
-- from `effect.error`, which EffectPlan records as `tostring(thrown)`. Encoding
-- the diagnostic name as a stable prefix keeps a single source of truth: the
-- thrown message is both the human-readable error and the machine-readable name.
local DIAGNOSTIC_SEPARATOR = ": "

local function owns(store: any, key: string, lock: any): boolean
	if type(store.owns) ~= "function" then
		-- A store that cannot prove ownership is treated as having lost it; fail
		-- closed rather than committing a write we cannot vouch for.
		return false
	end
	local ownsFn = store.owns :: (any, string, any) -> any
	return ownsFn(store, key, lock) == true
end

local function failureName(result: any): string
	if type(result) == "table" and type(result.name) == "string" then
		return result.name
	end
	return COMMIT_FAILED
end

local function failureReason(result: any): string
	if type(result) == "table" and result.reason ~= nil then
		return tostring(result.reason)
	end
	if type(result) == "table" and type(result.name) == "string" then
		return result.name
	end
	return "durable save failed"
end

-- DurableEffect.tagged formats a thrown durable error so the recorded
-- `effect.error` carries the diagnostic name as a stable prefix.
function DurableEffect.tagged(name: string, reason: string): string
	return name .. DIAGNOSTIC_SEPARATOR .. reason
end

-- DurableEffect.diagnosticName extracts the durable diagnostic name from a
-- recorded `effect.error`. The tagged name appears as a prefix; it is matched
-- anywhere in the string so a wrapper that prepends position info (e.g. a
-- "file:line: " prefix) still resolves correctly. Defaults to DurableCommitFailed.
function DurableEffect.diagnosticName(errorText: any): string
	if type(errorText) ~= "string" then
		return COMMIT_FAILED
	end
	if string.find(errorText, LOCK_LOST .. DIAGNOSTIC_SEPARATOR, 1, true) ~= nil then
		return LOCK_LOST
	end
	if string.find(errorText, COMMIT_FAILED .. DIAGNOSTIC_SEPARATOR, 1, true) ~= nil then
		return COMMIT_FAILED
	end
	return COMMIT_FAILED
end

function DurableEffect.operation(spec: any): any
	if type(spec) ~= "table" then
		error("DurableEffect.operation expects a spec table", 2)
	end

	local store = spec.store
	if type(store) ~= "table" then
		error("DurableEffect.operation requires spec.store", 2)
	end

	local key = spec.key
	if type(key) ~= "string" or key == "" then
		error("DurableEffect.operation requires a non-empty spec.key", 2)
	end

	if type(store.save) ~= "function" then
		error("DurableEffect store must implement save(key, value, lock)", 2)
	end

	local lock = spec.lock
	local previous = spec.previous
	local saveFn = store.save :: (any, string, any, any) -> any

	-- Resolve the value to persist once, eagerly at stage time. A `transform`
	-- runs against the value captured when the effect was staged so the commit
	-- closure does not depend on mutable handler state.
	local newValue: any = spec.value
	if newValue == nil and type(spec.transform) == "function" then
		local transform = spec.transform :: (any) -> any
		newValue = transform(previous)
	end

	-- `diagnostic` is a presence marker: it tells the post-commit scan that this
	-- effect is durable and its failure (if any) should be surfaced. The concrete
	-- name (SessionLockLost vs DurableCommitFailed) travels in `effect.error`.
	local metadata = {
		kind = "durable",
		key = key,
		diagnostic = "durable",
	}

	local function commit(_context: any): any
		-- Pre-yield ownership guard: bail before the save if the lock is already
		-- gone, so we never even attempt a write we cannot own.
		if not owns(store, key, lock) then
			error(DurableEffect.tagged(LOCK_LOST, "session lock lost before durable save for " .. key))
		end

		local result = saveFn(store, key, newValue, lock)
		if type(result) == "table" and result.ok == false then
			error(DurableEffect.tagged(failureName(result), failureReason(result)))
		end

		return {
			key = key,
			saved = newValue,
		}
	end

	local function rollback(_context: any): any
		-- Compensating write: restore the value captured at stage time. If the
		-- lock is already lost we cannot safely restore, so fail closed and let
		-- EffectPlan record ActionRollbackFailed.
		if not owns(store, key, lock) then
			error(DurableEffect.tagged(LOCK_LOST, "session lock lost before durable rollback for " .. key))
		end

		local result = saveFn(store, key, previous, lock)
		if type(result) == "table" and result.ok == false then
			error(DurableEffect.tagged(failureName(result), failureReason(result)))
		end

		return {
			key = key,
			restored = previous,
		}
	end

	return {
		commit = commit,
		rollback = rollback,
		metadata = metadata,
	}
end

return DurableEffect
