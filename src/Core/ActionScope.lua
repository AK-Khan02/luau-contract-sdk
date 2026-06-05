--!strict

export type Effect = {
	kind: string,
	target: string,
}

local ActionScope: any = {}
ActionScope.__index = ActionScope

local VIOLATION_MARKER = "__luauContractActionScopeViolation"

local function copyEffects(effects: {Effect}): {Effect}
	local copy = {}
	for index, effect in ipairs(effects) do
		copy[index] = {
			kind = effect.kind,
			target = effect.target,
		}
	end
	return copy
end

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
		_effects = {},
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

function ActionScope.effects(self: any): {Effect}
	return copyEffects(self._effects)
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

function ActionScope._rememberEffect(self: any, kind: string, targetPath: string)
	table.insert(self._effects, {
		kind = kind,
		target = targetPath,
	})
end

function ActionScope.checkEffect(self: any, kind: string, targetPath: string): any
	local result = self._system:checkActionEffect(self._actionName, {
		kind = kind,
		target = targetPath,
	}, self._diagnostics, self._context)
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

function ActionScope.write(self: any, targetPath: string, valueOrWriter: any): any
	local result = self:checkWrite(targetPath)
	if not result.ok then
		raiseViolation(result)
	end
	return runIfNeeded(valueOrWriter, self._context)
end

function ActionScope.create(self: any, targetPath: string, valueOrCreator: any): any
	local result = self:checkEffect("create", targetPath)
	if not result.ok then
		raiseViolation(result)
	end
	return runIfNeeded(valueOrCreator, self._context)
end

function ActionScope.destroy(self: any, targetPath: string, valueOrDestroyer: any): any
	local result = self:checkEffect("destroy", targetPath)
	if not result.ok then
		raiseViolation(result)
	end
	return runIfNeeded(valueOrDestroyer, self._context)
end

function ActionScope.touch(self: any, targetPath: string, valueOrToucher: any): any
	local result = self:checkEffect("touch", targetPath)
	if not result.ok then
		raiseViolation(result)
	end
	return runIfNeeded(valueOrToucher, self._context)
end

return ActionScope
