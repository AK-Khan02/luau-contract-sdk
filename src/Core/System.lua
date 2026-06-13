--!strict

local ActionRunner = require("./ActionRunner")
local ContractReport = require("./ContractReport")
local LifecycleSession = require("./LifecycleSession")
local Names = require("./Names")
local RemotePolicy = require("./RemotePolicy")
local Schema = require("./Schema")
local SystemConditions = require("./SystemConditions")
local SystemDefinitions = require("./SystemDefinitions")
local SystemLifecyclePolicy = require("./SystemLifecyclePolicy")
local SystemPermissions = require("./SystemPermissions")
local SystemValidation = require("./SystemValidation")
local TableUtil = require("./TableUtil")

export type SchemaLike = SystemDefinitions.SchemaLike
export type LifecyclePolicy = SystemDefinitions.LifecyclePolicy
export type ActionPolicy = SystemDefinitions.ActionPolicy
export type AsyncPolicy = SystemDefinitions.AsyncPolicy
export type RemoteBinding = SystemDefinitions.RemoteBinding
export type StringListInput = SystemDefinitions.StringListInput
export type RemoteOptions = SystemDefinitions.RemoteOptions
export type ActionDefinition = SystemDefinitions.ActionDefinition
export type ActionDescription = SystemDefinitions.ActionDescription

export type Description = {
	name: string,
	ownership: {
		tags: { string },
		folders: { string },
	},
	permissions: {
		strict: boolean,
		mayRead: { string },
		mayWrite: { string },
		mustNeverTouch: { string },
	},
	actions: { [string]: ActionDescription },
	remotes: { [string]: RemotePolicy.RemotePolicy },
	preconditions: { string },
	postconditions: { string },
	lifecycles: { [string]: unknown },
	actorPolicies: { string },
}

type NamedCheck = {
	name: string,
	check: (any) -> any,
}

type SystemData = {
	_name: string,
	_ownedTags: { string },
	_ownedFolders: { string },
	_mayRead: { string },
	_mayWrite: { string },
	_mustNeverTouch: { string },
	_strictPermissions: boolean,
	_actions: { [string]: any },
	_remotes: { [string]: RemotePolicy.RemotePolicy },
	_preconditions: { NamedCheck },
	_preconditionChecks: { [string]: (any) -> any },
	_postconditions: { NamedCheck },
	_postconditionChecks: { [string]: (any) -> any },
	_lifecycles: { [string]: unknown },
	_actorPolicies: { [string]: (any, any) -> any },
}

local System = {}
System.__index = System

export type System = typeof(setmetatable({} :: SystemData, System))

local assertName = Names.assertName
local appendUnique = TableUtil.appendUnique

System.validateRemote = SystemValidation.validateRemote
System.validateRemoteResponse = SystemValidation.validateRemoteResponse
System.validateActionInput = SystemValidation.validateActionInput
System.validateActionOutput = SystemValidation.validateActionOutput
System.validateActionContext = SystemValidation.validateActionContext

System._unknownAction = SystemPermissions._unknownAction
System._checkForbiddenTouch = SystemPermissions._checkForbiddenTouch
System._checkPermission = SystemPermissions._checkPermission
System._checkWriteLikeEffect = SystemPermissions._checkWriteLikeEffect
System._checkEffect = SystemPermissions._checkEffect
System.checkPermission = SystemPermissions.checkPermission
System.checkRead = SystemPermissions.checkRead
System.checkWrite = SystemPermissions.checkWrite
System.checkEffect = SystemPermissions.checkEffect
System.checkEffects = SystemPermissions.checkEffects
System.checkActionRead = SystemPermissions.checkActionRead
System.checkActionWrite = SystemPermissions.checkActionWrite
System.checkActionEffect = SystemPermissions.checkActionEffect
System.checkActionEffects = SystemPermissions.checkActionEffects
System.checkForbiddenTouch = SystemPermissions.checkForbiddenTouch
System.checkTouch = SystemPermissions.checkTouch

System.checkPrecondition = SystemConditions.checkPrecondition
System.checkPreconditions = SystemConditions.checkPreconditions
System.checkPostcondition = SystemConditions.checkPostcondition
System.checkPostconditions = SystemConditions.checkPostconditions
System.checkActionPreconditions = SystemConditions.checkActionPreconditions
System.checkActionPostconditions = SystemConditions.checkActionPostconditions

System.checkActionLifecycle = SystemLifecyclePolicy.checkActionLifecycle
System.reduceActionLifecycle = SystemLifecyclePolicy.reduceActionLifecycle
System._actorFailure = SystemLifecyclePolicy._actorFailure
System._checkActorPolicy = SystemLifecyclePolicy._checkActorPolicy
System.checkRemoteActor = SystemLifecyclePolicy.checkRemoteActor
System.checkActionPolicy = SystemLifecyclePolicy.checkActionPolicy

function System.new(name: string): System
	assertName("System name", name)

	return setmetatable(
		{
			_name = name,
			_ownedTags = {},
			_ownedFolders = {},
			_mayRead = {},
			_mayWrite = {},
			_mustNeverTouch = {},
			_strictPermissions = false,
			_actions = {},
			_remotes = {},
			_preconditions = {},
			_preconditionChecks = {},
			_postconditions = {},
			_postconditionChecks = {},
			_lifecycles = {},
			_actorPolicies = {},
		} :: SystemData,
		System
	)
end

function System.name(self: System): string
	return self._name
end

function System.ownsTag(self: System, tagName: string): System
	assertName("Owned tag", tagName)
	appendUnique(self._ownedTags, tagName)
	return self
end

function System.ownsFolder(self: System, folderPath: string): System
	assertName("Owned folder", folderPath)
	appendUnique(self._ownedFolders, folderPath)
	return self
end

function System.mayRead(self: System, path: string): System
	assertName("Readable path", path)
	appendUnique(self._mayRead, path)
	return self
end

function System.mayWrite(self: System, path: string): System
	assertName("Writable path", path)
	appendUnique(self._mayWrite, path)
	return self
end

function System.mustNeverTouch(self: System, path: string): System
	assertName("Forbidden path", path)
	appendUnique(self._mustNeverTouch, path)
	return self
end

function System.strictPermissions(self: System, enabled: boolean?): System
	self._strictPermissions = enabled ~= false
	return self
end

function System.remote(self: System, remoteName: string, schema: unknown, options: RemoteOptions?): System
	local remoteSchema, remoteOptions = SystemDefinitions.remoteDeclaration(remoteName, schema, options)
	self._remotes[remoteName] = RemotePolicy.normalize(remoteName, remoteSchema, remoteOptions)
	return self
end

function System.action(self: System, actionName: string, definition: ActionDefinition): System
	assertName("Action name", actionName)
	local action = SystemDefinitions.buildAction(actionName, definition)
	self._actions[actionName] = action

	if action.remote ~= nil then
		local remoteName = action.remote.name
		local remote = RemotePolicy.normalize(remoteName, action.input or Schema.any(), action.remote, actionName)
		action.remote = remote
		self._remotes[remoteName] = remote
	end

	return self
end

function System.lifecycle(self: System, name: string, lifecycle: unknown): System
	assertName("Lifecycle name", name)
	self._lifecycles[name] = lifecycle
	return self
end

function System.lifecycleSession(self: System, initialStates: unknown?, options: unknown?): any
	return LifecycleSession.new(self, initialStates or {}, options)
end

function System.precondition(self: System, name: string, check: (any) -> any): System
	assertName("Precondition name", name)
	if type(check) ~= "function" then
		error("Precondition check must be a function", 2)
	end

	if self._preconditionChecks[name] == nil then
		table.insert(self._preconditions, {
			name = name,
			check = check,
		})
	end
	self._preconditionChecks[name] = check
	return self
end

function System.postcondition(self: System, name: string, check: (any) -> any): System
	assertName("Postcondition name", name)
	if type(check) ~= "function" then
		error("Postcondition check must be a function", 2)
	end

	if self._postconditionChecks[name] == nil then
		table.insert(self._postconditions, {
			name = name,
			check = check,
		})
	end
	self._postconditionChecks[name] = check
	return self
end

function System.actorPolicy(self: System, name: string, check: (any, any) -> any): System
	assertName("Actor policy name", name)
	if type(check) ~= "function" then
		error("Actor policy check must be a function", 2)
	end

	self._actorPolicies[name] = check
	return self
end

function System.remoteOptions(self: System, remoteName: string): RemotePolicy.RemotePolicy?
	local remote = self._remotes[remoteName]
	if not remote then
		return nil
	end
	return RemotePolicy.options(remote)
end

function System.actionOptions(self: System, actionName: string): ActionDescription?
	local action = self._actions[actionName]
	if not action then
		return nil
	end
	return SystemDefinitions.describeAction(action, self._preconditions, self._postconditions)
end

function System.hasAction(self: System, actionName: string): boolean
	return self._actions[actionName] ~= nil
end

function System.actionForRemote(self: System, remoteName: string): string?
	local remote = self._remotes[remoteName]
	if remote == nil then
		return nil
	end
	return remote.action :: string?
end

function System.runAction(self: System, actionName: string, options: unknown?, handler: any?): any
	assertName("Action name", actionName)
	if type(options) == "function" and handler == nil then
		handler = options
		options = {}
	end
	local runOptions: ActionRunner.Options = (options or {}) :: ActionRunner.Options

	if type(handler) ~= "function" then
		error("System.runAction expects an action handler function", 2)
	end

	return ActionRunner.run(self, actionName, runOptions, handler)
end

function System.describe(self: System): Description
	return ContractReport.describeSystem(self)
end

return System
