--!strict

local Names = require("./Names")
local Schema = require("./Schema")
local TableUtil = require("./TableUtil")

export type SchemaLike = Schema.Schema | ((unknown) -> unknown)

export type LifecyclePolicy = {
	requires: { [string]: string },
	emits: { [string]: string },
}

export type ActionPolicy = {
	actor: unknown?,
	authorize: unknown?,
	actorRequired: boolean?,
	[string]: unknown,
}

export type AsyncPolicy = {
	concurrency: unknown?,
	timeoutSeconds: number?,
	[string]: unknown,
}

export type RemoteBinding = string | { [string]: unknown }
export type StringListInput = string | { string }

export type RemoteOptions = {
	action: string?,
	direction: string?,
	response: SchemaLike?,
	result: SchemaLike?,
	output: SchemaLike?,
	actor: unknown?,
	authorize: unknown?,
	lifecycle: unknown?,
	rateLimit: unknown?,
	tags: StringListInput?,
	[string]: unknown,
}

export type ActionDefinition = {
	input: SchemaLike?,
	output: SchemaLike?,
	result: SchemaLike?,
	context: SchemaLike?,
	reads: StringListInput?,
	writes: StringListInput?,
	touches: StringListInput?,
	creates: StringListInput?,
	destroys: StringListInput?,
	forbids: StringListInput?,
	mustNeverTouch: StringListInput?,
	preconditions: unknown?,
	postconditions: unknown?,
	lifecycle: unknown?,
	requiresState: { [string]: string }?,
	emits: { [string]: string }?,
	remote: RemoteBinding?,
	policy: ActionPolicy?,
	policies: ActionPolicy?,
	async: AsyncPolicy?,
	tags: StringListInput?,
	[string]: unknown,
}

export type ActionDescription = {
	name: string,
	input: SchemaLike?,
	output: SchemaLike?,
	context: SchemaLike?,
	reads: { string },
	writes: { string },
	touches: { string },
	creates: { string },
	destroys: { string },
	forbids: { string },
	preconditions: { string },
	postconditions: { string },
	lifecycle: LifecyclePolicy,
	remote: RemoteBinding?,
	policy: ActionPolicy,
	async: AsyncPolicy?,
	tags: { string },
}

local SystemDefinitions = {}

local assertName = Names.assertName
local appendUnique = TableUtil.appendUnique
local copyList = TableUtil.copyList
local copyMap = TableUtil.copyMap
local deepCopy = TableUtil.deepCopy

local function normalizeStringList(kind: string, values: any?): { string }
	if values == nil then
		return {}
	end
	if type(values) == "string" then
		assertName(kind, values)
		return { values }
	end
	if type(values) ~= "table" then
		error(kind .. " must be a string or array of strings", 3)
	end

	local normalized = {}
	for _, value in ipairs(values) do
		assertName(kind, value)
		appendUnique(normalized, value :: string)
	end
	return normalized
end

local function normalizeStringMap(kind: string, values: any?): { [string]: string }
	if values == nil then
		return {}
	end
	if type(values) ~= "table" then
		error(kind .. " must be a map of strings", 3)
	end

	local normalized = {}
	for key, value in pairs(values) do
		assertName(kind .. " key", key)
		assertName(kind .. " value", value)
		normalized[key :: string] = value :: string
	end
	return normalized
end

local function normalizePolicy(definition: any): any
	if definition == nil then
		return {}
	end
	if type(definition) ~= "table" then
		error("Action policy must be a table", 3)
	end
	return copyMap(definition)
end

local function normalizeLifecyclePolicy(definition: any): LifecyclePolicy
	definition = definition or {}
	if type(definition) ~= "table" then
		error("Action lifecycle must be a table", 3)
	end

	return {
		requires = normalizeStringMap("Action lifecycle requirement", definition.requires or definition.requiresState),
		emits = normalizeStringMap("Action lifecycle event", definition.emits),
	}
end

local ASYNC_CONCURRENCY_MODES: { [string]: boolean } = {
	serialize = true,
	reject = true,
	allow = true,
}

local function normalizeAsyncPolicy(definition: any): AsyncPolicy?
	if definition == nil or definition == false then
		return nil
	end
	if definition == true then
		definition = {}
	end
	if type(definition) ~= "table" then
		error("Action async policy must be true or a table", 3)
	end

	local concurrency = definition.concurrency
	if concurrency ~= nil and ASYNC_CONCURRENCY_MODES[concurrency] ~= true then
		error("Action async concurrency must be serialize, reject, or allow", 3)
	end

	local timeoutSeconds = definition.timeoutSeconds
	if timeoutSeconds ~= nil and timeoutSeconds ~= false then
		if type(timeoutSeconds) ~= "number" or timeoutSeconds <= 0 then
			error("Action async timeoutSeconds must be a positive number or false", 3)
		end
	end

	return {
		concurrency = concurrency,
		timeoutSeconds = timeoutSeconds,
	}
end

local function normalizeRemoteBinding(actionName: string, remote: any): any?
	if remote == nil then
		return nil
	end
	if type(remote) == "string" then
		assertName("Action remote", remote)
		return {
			name = remote,
			action = actionName,
		}
	end
	if type(remote) ~= "table" then
		error("Action remote must be a string or table", 3)
	end

	local remoteName = remote.name or remote.remoteName
	assertName("Action remote", remoteName)

	local normalized = copyMap(remote)
	normalized.name = remoteName
	normalized.action = actionName
	return normalized
end

function SystemDefinitions.remoteDeclaration(remoteName: string, schemaOrDefinition: any, options: any?): (any, any?)
	if options ~= nil then
		return schemaOrDefinition, options
	end

	if type(schemaOrDefinition) ~= "table" then
		return schemaOrDefinition, options
	end

	local input = schemaOrDefinition.input or schemaOrDefinition.schema or schemaOrDefinition.payload
	if input == nil then
		return schemaOrDefinition, options
	end

	local remoteOptions = copyMap(schemaOrDefinition)
	remoteOptions.input = nil
	remoteOptions.schema = nil
	remoteOptions.payload = nil
	remoteOptions.name = remoteOptions.name or remoteOptions.remoteName or remoteName
	return input, remoteOptions
end

local function normalizeCheckReferences(kind: string, references: any?): any
	if references == nil then
		return {}
	end
	if references == "all" then
		return "all"
	end
	if type(references) == "string" then
		assertName(kind, references)
		return { references }
	end
	return normalizeStringList(kind, references)
end

local function checkNames(references: any, fallback: { any }?): { string }
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

function SystemDefinitions.buildAction(actionName: string, definition: ActionDefinition): any
	if type(definition) ~= "table" then
		error("Action definition must be a table", 3)
	end

	return {
		name = actionName,
		input = definition.input or definition.schema,
		output = definition.output or definition.result,
		context = definition.context,
		reads = normalizeStringList("Action read path", definition.reads or definition.mayRead),
		writes = normalizeStringList("Action write path", definition.writes or definition.mayWrite),
		touches = normalizeStringList("Action touch path", definition.touches),
		creates = normalizeStringList("Action create path", definition.creates),
		destroys = normalizeStringList("Action destroy path", definition.destroys),
		forbids = normalizeStringList("Action forbidden path", definition.forbids or definition.mustNeverTouch),
		preconditions = normalizeCheckReferences("Action precondition", definition.preconditions),
		postconditions = normalizeCheckReferences("Action postcondition", definition.postconditions),
		lifecycle = normalizeLifecyclePolicy(definition.lifecycle or {
			requires = definition.requiresState,
			emits = definition.emits,
		}),
		remote = normalizeRemoteBinding(actionName, definition.remote),
		policy = normalizePolicy(definition.policy or definition.policies),
		async = normalizeAsyncPolicy(definition.async),
		tags = normalizeStringList("Action tag", definition.tags),
	}
end

function SystemDefinitions.describeAction(
	action: any,
	preconditionFallback: { any },
	postconditionFallback: { any }
): ActionDescription
	return {
		name = action.name,
		input = deepCopy(action.input),
		output = deepCopy(action.output),
		context = deepCopy(action.context),
		reads = copyList(action.reads),
		writes = copyList(action.writes),
		touches = copyList(action.touches),
		creates = copyList(action.creates),
		destroys = copyList(action.destroys),
		forbids = copyList(action.forbids),
		preconditions = checkNames(action.preconditions, preconditionFallback),
		postconditions = checkNames(action.postconditions, postconditionFallback),
		lifecycle = deepCopy(action.lifecycle),
		remote = deepCopy(action.remote),
		policy = deepCopy(action.policy),
		async = action.async ~= nil and deepCopy(action.async) or nil,
		tags = copyList(action.tags),
	}
end

return SystemDefinitions
