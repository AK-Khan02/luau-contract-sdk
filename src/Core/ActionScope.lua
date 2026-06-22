--!strict

local DurableEffect = require("./DurableEffect")
local EffectPlan = require("./EffectPlan")

-- Snapshot a value so a later in-place mutation cannot corrupt the captured copy.
-- Inlined (rather than TableUtil.deepCopy) so the analyzer resolves a precise
-- return type at the writeDurable call site.
local function snapshotValue(value: any, seen: any?): any
	if type(value) ~= "table" then
		return value
	end

	local visited = seen or {}
	if visited[value] ~= nil then
		return visited[value]
	end

	local copy = {}
	visited[value] = copy
	for key, child in pairs(value) do
		copy[snapshotValue(key, visited)] = snapshotValue(child, visited)
	end
	return copy
end

export type Effect = {
	kind: string,
	target: string,
	status: string?,
	metadata: any?,
}

-- The subset of a DurableProfile handle that writeDurable depends on. Casting the
-- injected handle to this structural type lets the analyzer resolve precise
-- result types for the method calls below.
type DurableProfileHandle = {
	value: (DurableProfileHandle) -> any,
	set: (DurableProfileHandle, any) -> (),
	key: (DurableProfileHandle) -> string,
	lock: (DurableProfileHandle) -> any,
	store: (DurableProfileHandle) -> any,
}

local ActionScope: any = {}
ActionScope.__index = ActionScope

local VIOLATION_MARKER = "__luauContractActionScopeViolation"

local function raiseViolation(result: any)
	error({
		[VIOLATION_MARKER] = true,
		result = result,
	}, 2)
end

local function runIfNeeded(valueOrRunner: any, context: any): any
	if type(valueOrRunner) == "function" then
		local runner = valueOrRunner :: (any) -> any
		return runner(context)
	end
	return valueOrRunner
end

function ActionScope.isViolation(value: any): boolean
	return type(value) == "table" and value[VIOLATION_MARKER] == true
end

function ActionScope.violationResult(value: any): any
	if ActionScope.isViolation(value) then
		return value.result
	end
	return nil
end

function ActionScope.new(systemContract: any, actionName: string, context: any, diagnostics: any?): any
	return setmetatable({
		_system = systemContract,
		_actionName = actionName,
		_context = context,
		_diagnostics = diagnostics,
		_effectPlan = EffectPlan.new(),
	}, ActionScope)
end

function ActionScope.action(self: any): string
	return self._actionName
end

function ActionScope.actor(self: any): any
	return self._context.actor
end

function ActionScope.context(self: any): any
	return self._context
end

function ActionScope.diagnostics(self: any): any?
	return self._diagnostics
end

function ActionScope.effects(self: any): { Effect }
	return self._effectPlan:effects()
end

function ActionScope.eagerMutations(self: any): { any }
	return self._effectPlan:eagerMutations()
end

function ActionScope.effectView(self: any): any
	return self._effectPlan:view()
end

function ActionScope.input(self: any): any
	return self._context.input
end

function ActionScope.payload(self: any): any
	return self._context.payload
end

function ActionScope.system(self: any): any
	return self._system
end

function ActionScope.cancelToken(self: any): any
	return self._context.cancelToken
end

function ActionScope.cancelled(self: any): boolean
	local token: any = self._context.cancelToken
	if token == nil or type(token.isCancelled) ~= "function" then
		return false
	end
	local isCancelledFn = token.isCancelled :: (any) -> any
	return isCancelledFn(token) == true
end

function ActionScope.onCancel(self: any, callback: (any) -> ())
	local token: any = self._context.cancelToken
	if token == nil or type(token.onCancel) ~= "function" then
		return
	end
	local onCancelFn = token.onCancel :: (any, (any) -> ()) -> ()
	onCancelFn(token, callback)
end

function ActionScope._rememberEffect(self: any, kind: string, targetPath: string)
	local status = kind == "read" and "observed" or "committed"
	self._effectPlan:record(kind, targetPath, status)
end

function ActionScope._checkEffect(self: any, kind: string, targetPath: string): any
	return self._system:checkActionEffect(self._actionName, {
		kind = kind,
		target = targetPath,
	}, self._diagnostics, self._context)
end

function ActionScope.checkEffect(self: any, kind: string, targetPath: string): any
	local result = self:_checkEffect(kind, targetPath)
	if result.ok then
		self:_rememberEffect(kind, targetPath)
	end
	return result
end

function ActionScope.checkRead(self: any, targetPath: string): any
	return self:checkEffect("read", targetPath)
end

function ActionScope.checkWrite(self: any, targetPath: string): any
	return self:checkEffect("write", targetPath)
end

function ActionScope.read(self: any, targetPath: string, valueOrReader: any): any
	local result = self:checkRead(targetPath)
	if not result.ok then
		raiseViolation(result)
	end
	return runIfNeeded(valueOrReader, self._context)
end

-- EFFECT MODEL -- transactional is the default.
--
-- scope:write / create / destroy / touch STAGE a mutation. The operation runs at
-- commit time (after output validation, postconditions, and lifecycle checks pass)
-- and is undone via its rollback if a later step fails. Pass a value, a
-- `function(context)` commit, or a `{ commit = fn, rollback = fn? }` table. This is
-- the safe default: a failed action never leaves a staged write applied.
--
-- scope:writeEager / createEager / destroyEager / touchEager are the NON-transactional
-- escape hatch. They run their writer IMMEDIATELY and cannot be rolled back, so a
-- later failure leaves the mutation applied (surfaced as an
-- ActionEagerEffectsNotRolledBack diagnostic). Reach for these only when the write
-- genuinely cannot be deferred. See docs/API.md and EffectPlan.eagerMutations.

function ActionScope._stageMutation(self: any, kind: string, targetPath: string, operation: any): any
	local result = self:_checkEffect(kind, targetPath)
	if not result.ok then
		raiseViolation(result)
	end
	return self._effectPlan:stage(kind, targetPath, operation)
end

function ActionScope._eagerMutation(self: any, kind: string, targetPath: string, valueOrWriter: any): any
	local result = self:checkEffect(kind, targetPath)
	if not result.ok then
		raiseViolation(result)
	end
	return runIfNeeded(valueOrWriter, self._context)
end

function ActionScope.write(self: any, targetPath: string, operation: any): any
	return self:_stageMutation("write", targetPath, operation)
end

function ActionScope.create(self: any, targetPath: string, operation: any): any
	return self:_stageMutation("create", targetPath, operation)
end

function ActionScope.destroy(self: any, targetPath: string, operation: any): any
	return self:_stageMutation("destroy", targetPath, operation)
end

function ActionScope.touch(self: any, targetPath: string, operation: any): any
	return self:_stageMutation("touch", targetPath, operation)
end

-- writeDurable stages a session-locked durable write against a loaded profile. It
-- goes through the same write permission gate as scope:write (an undeclared
-- durable path still fails WriteNotAllowed), captures the profile's current value
-- as the compensating rollback value, computes the new value (a plain value or a
-- `transform(previous)`), and stages a DurableEffect operation. Because it is an
-- ordinary kind="write" effect, it persists only at the commit boundary, rolls
-- back/compensates on failure, and participates with in-memory writes in one
-- transaction -- it is transactional, never eager.
function ActionScope.writeDurable(self: any, targetPath: string, profile: any, valueOrTransform: any): any
	local result = self:_checkEffect("write", targetPath)
	if not result.ok then
		raiseViolation(result)
	end

	if type(profile) ~= "table" or type(profile.value) ~= "function" then
		error("scope:writeDurable expects a loaded profile handle", 2)
	end

	local handle = profile :: DurableProfileHandle

	-- Snapshot the pre-write value as the compensating rollback target BEFORE the
	-- transform runs. ProfileService-style handlers commonly mutate the value
	-- table in place and return it, which would otherwise alias `previous` and
	-- corrupt the rollback. The deep copy keeps the rollback value pristine.
	local current: any = handle:value()
	local previous = snapshotValue(current)
	local newValue: any
	if type(valueOrTransform) == "function" then
		local transform = valueOrTransform :: (any) -> any
		newValue = transform(current)
	else
		newValue = valueOrTransform
	end
	handle:set(newValue)

	local operation = DurableEffect.operation({
		store = handle:store(),
		key = handle:key(),
		lock = handle:lock(),
		value = newValue,
		previous = previous,
	})

	return self._effectPlan:stage("write", targetPath, operation)
end

function ActionScope.writeEager(self: any, targetPath: string, valueOrWriter: any): any
	return self:_eagerMutation("write", targetPath, valueOrWriter)
end

function ActionScope.createEager(self: any, targetPath: string, valueOrCreator: any): any
	return self:_eagerMutation("create", targetPath, valueOrCreator)
end

function ActionScope.destroyEager(self: any, targetPath: string, valueOrDestroyer: any): any
	return self:_eagerMutation("destroy", targetPath, valueOrDestroyer)
end

function ActionScope.touchEager(self: any, targetPath: string, valueOrToucher: any): any
	return self:_eagerMutation("touch", targetPath, valueOrToucher)
end

-- Deprecated: stageWrite/stageCreate/stageDestroy/stageTouch/stageEffect remain as
-- aliases now that write/create/destroy/touch stage by default. Prefer the shorter
-- names; these will be removed in a future release.
function ActionScope.stageEffect(self: any, kind: string, targetPath: string, operation: any): any
	return self:_stageMutation(kind, targetPath, operation)
end

function ActionScope.stageWrite(self: any, targetPath: string, operation: any): any
	return self:_stageMutation("write", targetPath, operation)
end

function ActionScope.stageCreate(self: any, targetPath: string, operation: any): any
	return self:_stageMutation("create", targetPath, operation)
end

function ActionScope.stageDestroy(self: any, targetPath: string, operation: any): any
	return self:_stageMutation("destroy", targetPath, operation)
end

function ActionScope.stageTouch(self: any, targetPath: string, operation: any): any
	return self:_stageMutation("touch", targetPath, operation)
end

function ActionScope.commitEffects(self: any, diagnostics: any?, options: any?): any
	return self._effectPlan:commit(self._context, diagnostics or self._diagnostics, options)
end

function ActionScope.rollbackEffects(self: any, diagnostics: any?, options: any?): any
	return self._effectPlan:rollback(self._context, diagnostics or self._diagnostics, options)
end

return ActionScope
