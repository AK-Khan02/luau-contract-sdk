--!strict

local Schema = require("./Schema")

export type RemotePolicy = {
	name: string,
	schema: any,
	action: string?,
	direction: string,
	response: any?,
	actor: any?,
	lifecycle: any,
	rateLimit: any?,
	tags: {string},
}

local RemotePolicy = {}

local function assertName(kind: string, value: any)
	if type(value) ~= "string" or value == "" then
		error(kind .. " must be a non-empty string", 3)
	end
end

local function appendUnique(values: {string}, value: string)
	for _, existing in ipairs(values) do
		if existing == value then
			return
		end
	end
	table.insert(values, value)
end

local function normalizeStringList(kind: string, values: any?): {string}
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

local function copyList(values: {any}?): {any}
	local copy = {}
	for index, value in ipairs(values or {}) do
		copy[index] = value
	end
	return copy
end

local function copyTable(value: any): any
	if type(value) ~= "table" then
		return value
	end

	local copy = {}
	for key, child in pairs(value) do
		copy[key] = copyTable(child)
	end
	return copy
end

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

local function defined(primary: any, fallback: any): any
	if primary ~= nil then
		return primary
	end
	return fallback
end

local function normalizeDirection(value: any?): string
	if value == nil then
		return "server"
	end
	assertName("Remote direction", value)
	if value ~= "server" and value ~= "client" and value ~= "bidirectional" then
		error("Remote direction must be server, client, or bidirectional", 3)
	end
	return value :: string
end

local function normalizeLifecycle(definition: any?): any
	if definition == nil then
		return {}
	end
	if type(definition) == "string" then
		assertName("Remote lifecycle session", definition)
		return {
			session = definition,
		}
	end
	if type(definition) ~= "table" then
		error("Remote lifecycle must be a string or table", 3)
	end

	local lifecycle = copyTable(definition)
	if lifecycle.session ~= nil then
		assertName("Remote lifecycle session", lifecycle.session)
	end
	if lifecycle.sessionName ~= nil then
		assertName("Remote lifecycle session", lifecycle.sessionName)
		lifecycle.session = lifecycle.session or lifecycle.sessionName
		lifecycle.sessionName = nil
	end
	if lifecycle.expectedRevision ~= nil and lifecycle.revision == nil then
		lifecycle.revision = lifecycle.expectedRevision
		lifecycle.expectedRevision = nil
	end
	return lifecycle
end

local function normalizeActor(options: any): any
	local policy = options.policy
	local actor = defined(options.actor, options.actorPolicy)
	if actor == nil and type(policy) == "table" then
		actor = defined(policy.actor, policy.authorize)
	end
	if actor == nil and options.actorRequired == true then
		actor = "required"
	end
	return actor
end

function RemotePolicy.normalize(remoteName: string, schema: any, options: any?, defaultAction: string?): RemotePolicy
	assertName("Remote name", remoteName)
	if options ~= nil and type(options) ~= "table" then
		error("Remote options must be a table", 3)
	end

	local remoteOptions = options or {}
	local action = defined(remoteOptions.action, defaultAction)
	if action ~= nil then
		assertName("Remote action", action)
	end

	return {
		name = remoteName,
		schema = schema,
		action = action,
		direction = normalizeDirection(remoteOptions.direction),
		response = defined(defined(remoteOptions.response, remoteOptions.result), remoteOptions.output),
		actor = normalizeActor(remoteOptions),
		lifecycle = normalizeLifecycle(remoteOptions.lifecycle),
		rateLimit = copyTable(remoteOptions.rateLimit),
		tags = normalizeStringList("Remote tag", remoteOptions.tags),
	}
end

function RemotePolicy.options(policy: RemotePolicy): any
	return {
		name = policy.name,
		action = policy.action,
		direction = policy.direction,
		response = policy.response,
		actor = policy.actor,
		lifecycle = copyTable(policy.lifecycle),
		rateLimit = copyTable(policy.rateLimit),
		tags = copyList(policy.tags),
	}
end

function RemotePolicy.describe(policy: RemotePolicy): any
	local report: any = {
		name = policy.name,
		direction = policy.direction,
		action = policy.action,
		payload = Schema.describe(policy.schema),
		actor = describeValue(policy.actor),
		lifecycle = describeValue(policy.lifecycle),
		rateLimit = describeValue(policy.rateLimit),
		tags = copyList(policy.tags),
	}

	if policy.response ~= nil then
		report.response = Schema.describe(policy.response)
	end

	return report
end

return RemotePolicy
