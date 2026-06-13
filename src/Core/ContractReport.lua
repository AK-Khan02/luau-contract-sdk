--!strict

local RemotePolicy = require("./RemotePolicy")
local Schema = require("./Schema")
local TableUtil = require("./TableUtil")

local ContractReport = {}

local copyList = TableUtil.copyList
local copyMap = TableUtil.copyMap

local function describeValue(value: any): any
	if type(value) == "function" then
		return {
			kind = "function",
		}
	end
	if type(value) ~= "table" then
		return value
	end

	local copy = {}
	for key, child in pairs(value) do
		copy[key] = describeValue(child)
	end
	return copy
end

local function namedChecks(references: any, fallback: { any }?): { string }
	local names = {}
	if references == "all" then
		for _, check in ipairs(fallback or {}) do
			table.insert(names, check.name)
		end
		return names
	end

	for _, name in ipairs(references or {}) do
		table.insert(names, name :: string)
	end
	return names
end

local function schemaDescription(schema: any): any
	if schema == nil then
		return nil
	end
	return Schema.describe(schema)
end

local function describeLifecyclePolicy(lifecycle: any): any
	return {
		requires = copyMap(lifecycle and lifecycle.requires or {}),
		emits = copyMap(lifecycle and lifecycle.emits or {}),
	}
end

local function describeRemoteBinding(remote: any): any
	if remote == nil then
		return nil
	end
	return {
		name = remote.name,
		action = remote.action,
		direction = remote.direction,
		actor = describeValue(remote.actor),
		lifecycle = describeValue(remote.lifecycle),
		rateLimit = describeValue(remote.rateLimit),
		tags = copyList(remote.tags),
		response = schemaDescription(remote.response),
	}
end

local function describePolicy(policy: any): any
	return describeValue(policy or {})
end

local function describeAction(action: any, preconditionFallback: { any }, postconditionFallback: { any }): any
	return {
		name = action.name,
		input = schemaDescription(action.input),
		output = schemaDescription(action.output),
		context = schemaDescription(action.context),
		reads = copyList(action.reads),
		writes = copyList(action.writes),
		touches = copyList(action.touches),
		creates = copyList(action.creates),
		destroys = copyList(action.destroys),
		forbids = copyList(action.forbids),
		preconditions = namedChecks(action.preconditions, preconditionFallback),
		postconditions = namedChecks(action.postconditions, postconditionFallback),
		lifecycle = describeLifecyclePolicy(action.lifecycle),
		remote = describeRemoteBinding(action.remote),
		policy = describePolicy(action.policy),
		async = action.async ~= nil and copyMap(action.async) or nil,
		tags = copyList(action.tags),
	}
end

local function describeLifecycle(lifecycle: any): any
	if lifecycle and type(lifecycle.describe) == "function" then
		local target: any = lifecycle
		return target:describe()
	end
	return describeValue(lifecycle)
end

local function checkNames(checks: { any }): { string }
	local names = {}
	for _, check in ipairs(checks) do
		table.insert(names, check.name)
	end
	return names
end

local function actorPolicyNames(actorPolicies: any): { string }
	local names = {}
	for name in pairs(actorPolicies or {}) do
		if type(name) == "string" then
			table.insert(names, name)
		end
	end
	table.sort(names)
	return names
end

function ContractReport.describeSystem(system: any): any
	local actions = {}
	for name, action in pairs(system._actions) do
		actions[name] = describeAction(action, system._preconditions, system._postconditions)
	end

	local remotes = {}
	for name, remote in pairs(system._remotes) do
		remotes[name] = RemotePolicy.describe(remote)
	end

	local lifecycles = {}
	for name, lifecycle in pairs(system._lifecycles) do
		lifecycles[name] = describeLifecycle(lifecycle)
	end

	return {
		formatVersion = 1,
		name = system._name,
		ownership = {
			tags = copyList(system._ownedTags),
			folders = copyList(system._ownedFolders),
		},
		permissions = {
			strict = system._strictPermissions,
			mayRead = copyList(system._mayRead),
			mayWrite = copyList(system._mayWrite),
			mustNeverTouch = copyList(system._mustNeverTouch),
		},
		actions = actions,
		remotes = remotes,
		preconditions = checkNames(system._preconditions),
		postconditions = checkNames(system._postconditions),
		lifecycles = lifecycles,
		actorPolicies = actorPolicyNames(system._actorPolicies),
	}
end

return ContractReport
