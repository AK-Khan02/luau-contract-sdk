--!strict

local Result = require("./Result")
local TableUtil = require("./TableUtil")

export type Snapshot = {
	revision: number,
	states: { [string]: string },
	history: { any }?,
}

local LifecycleSession: any = {}
LifecycleSession.__index = LifecycleSession

local copyList = TableUtil.copyList
local copyMap = TableUtil.copyMap
local record = Result.record

local function assertRevision(value: any)
	if type(value) ~= "number" or value < 0 or value % 1 ~= 0 then
		error("Lifecycle session revision must be a non-negative integer", 3)
	end
end

local function isRevision(value: any): boolean
	return type(value) == "number" and value >= 0 and value % 1 == 0
end

local function revisionContext(context: any?, expectedRevision: any, currentRevision: number): any
	local output = copyMap(context or {})
	output.expectedRevision = expectedRevision
	output.revision = currentRevision
	return output
end

local function result(ok: boolean, name: string, fields: any?): any
	local output = copyMap(fields or {})
	output.ok = ok
	output.name = name
	return output
end

function LifecycleSession.new(systemContract: any, initialStates: any?, options: any?): any
	if not systemContract or type(systemContract.name) ~= "function" then
		error("LifecycleSession.new expects a system contract", 2)
	end

	local config = options or {}
	local revision = config.revision or 0
	assertRevision(revision)

	return setmetatable({
		_system = systemContract,
		_states = copyMap(initialStates or {}),
		_revision = revision,
		_history = {},
		_maxHistory = config.maxHistory or 50,
	}, LifecycleSession)
end

function LifecycleSession.system(self: any): any
	return self._system
end

function LifecycleSession.state(self: any, lifecycleName: string): string?
	return self._states[lifecycleName]
end

function LifecycleSession.states(self: any): { [string]: string }
	return copyMap(self._states)
end

function LifecycleSession.revision(self: any): number
	return self._revision
end

function LifecycleSession.snapshot(self: any): Snapshot
	return {
		revision = self._revision,
		states = self:states(),
		history = copyList(self._history),
	}
end

function LifecycleSession.restore(self: any, snapshot: Snapshot): any
	if type(snapshot) ~= "table" then
		error("LifecycleSession.restore expects a snapshot", 2)
	end
	assertRevision(snapshot.revision)

	self._states = copyMap(snapshot.states or {})
	self._revision = snapshot.revision
	self._history = copyList(snapshot.history or {})
	return self
end

function LifecycleSession.describe(self: any): any
	return {
		system = self._system:name(),
		revision = self._revision,
		states = self:states(),
		history = copyList(self._history),
	}
end

function LifecycleSession.checkRevision(self: any, expectedRevision: any?, diagnostics: any?, context: any?): any
	if expectedRevision == nil then
		return result(true, "LifecycleRevisionAccepted", {
			revision = self._revision,
		})
	end

	if not isRevision(expectedRevision) then
		local name = "LifecycleRevisionInvalid"
		local message = self._system:name() .. " lifecycle session expected a non-negative integer revision"
		record(diagnostics, {
			level = "error",
			category = "lifecycle",
			system = self._system:name(),
			name = name,
			message = message,
			context = revisionContext(context, expectedRevision, self._revision),
		})
		return result(false, name, {
			reason = message,
			expectedRevision = expectedRevision,
			revision = self._revision,
		})
	end

	if expectedRevision == self._revision then
		return result(true, "LifecycleRevisionAccepted", {
			revision = self._revision,
		})
	end

	local name = "LifecycleStaleRevision"
	local message = self._system:name()
		.. " lifecycle session expected revision "
		.. tostring(expectedRevision)
		.. " but current revision is "
		.. tostring(self._revision)
	record(diagnostics, {
		level = "error",
		category = "lifecycle",
		system = self._system:name(),
		name = name,
		message = message,
		context = revisionContext(context, expectedRevision, self._revision),
	})

	return result(false, name, {
		reason = message,
		expectedRevision = expectedRevision,
		revision = self._revision,
	})
end

function LifecycleSession.canRun(
	self: any,
	actionName: string,
	diagnostics: any?,
	context: any?,
	expectedRevision: number?
): any
	local revision = self:checkRevision(expectedRevision, diagnostics, context)
	if not revision.ok then
		return result(false, revision.name, {
			reason = revision.reason,
			failures = { revision },
			revision = self._revision,
			states = self:states(),
		})
	end

	local lifecycle = self._system:checkActionLifecycle(actionName, self._states, diagnostics, context)
	return result(lifecycle.ok, lifecycle.ok and "LifecycleSessionReady" or "ActionLifecycleStateInvalid", {
		failures = lifecycle.failures or {},
		revision = self._revision,
		states = self:states(),
	})
end

function LifecycleSession._remember(self: any, actionName: string, transitions: { any }, previousRevision: number)
	if #transitions == 0 then
		return
	end

	table.insert(self._history, {
		action = actionName,
		revision = self._revision,
		previousRevision = previousRevision,
		transitions = copyList(transitions),
		states = self:states(),
	})

	if #self._history > self._maxHistory then
		table.remove(self._history, 1)
	end
end

function LifecycleSession.apply(
	self: any,
	actionName: string,
	diagnostics: any?,
	context: any?,
	expectedRevision: number?
): any
	local revision = self:checkRevision(expectedRevision, diagnostics, context)
	if not revision.ok then
		return result(false, revision.name, {
			reason = revision.reason,
			failures = { revision },
			revision = self._revision,
			states = self:states(),
			transitions = {},
		})
	end

	local previousRevision = self._revision
	local lifecycle = self._system:reduceActionLifecycle(actionName, self._states, diagnostics, context)
	if not lifecycle.ok then
		lifecycle.revision = self._revision
		lifecycle.previousRevision = previousRevision
		lifecycle.session = self
		return lifecycle
	end

	self._states = copyMap(lifecycle.states or self._states)
	if #(lifecycle.transitions or {}) > 0 then
		self._revision += 1
	end
	self:_remember(actionName, lifecycle.transitions or {}, previousRevision)

	lifecycle.revision = self._revision
	lifecycle.previousRevision = previousRevision
	lifecycle.states = self:states()
	lifecycle.session = self
	return lifecycle
end

return LifecycleSession
