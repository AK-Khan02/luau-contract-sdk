--!strict

local RemoteGuard = require("./RemoteGuard")
local Schema = require("../Core/Schema")
local System = require("../Core/System")

local GuardRemote = {}

local function assertRemote(remote: any)
	if remote == nil then
		error("guardRemote expects a remote object", 3)
	end
end

local function assertOptions(options: any)
	if type(options) ~= "table" then
		error("guardRemote expects an options table", 3)
	end
end

local function assertHandler(handler: any)
	if type(handler) ~= "function" then
		error("guardRemote expects a handler function", 3)
	end
end

local function remoteName(remote: any, options: any): string
	local name = options.name or options.remoteName
	if name ~= nil then
		if type(name) ~= "string" or name == "" then
			error("guardRemote name must be a non-empty string", 3)
		end
		return name
	end

	local instanceName = remote.Name
	if type(instanceName) == "string" and instanceName ~= "" then
		return instanceName
	end

	return "GuardedRemote"
end

local function systemName(name: string, options: any): string
	local configured = options.systemName or options.contractName
	if configured ~= nil then
		if type(configured) ~= "string" or configured == "" then
			error("guardRemote systemName must be a non-empty string", 3)
		end
		return configured
	end
	return name .. "Guard"
end

local function payloadSchema(options: any): any
	return options.input or options.schema or options.payload or Schema.any()
end

local function responseSchema(options: any): any
	return options.output or options.response or options.result
end

local function remoteKind(options: any): any
	return options.kind or options.remoteKind
end

local function actorPolicies(options: any): any
	return options.actorPolicies or options.policies
end

local function installActorPolicies(systemContract: any, policies: any)
	if policies == nil then
		return
	end
	if type(policies) ~= "table" then
		error("guardRemote actorPolicies must be a map of policy functions", 3)
	end

	for name, check in pairs(policies) do
		if type(name) == "string" and type(check) == "function" then
			systemContract:actorPolicy(name, check)
		else
			error("guardRemote actorPolicies must be a map of policy functions", 3)
		end
	end
end

local function remoteOptions(options: any): any
	return {
		actor = options.actor or options.actorPolicy,
		direction = options.direction or "server",
		lifecycle = options.lifecycle,
		rateLimit = options.rateLimit,
		response = responseSchema(options),
		tags = options.tags,
	}
end

local function bindOptions(options: any): any
	return {
		clock = options.clock,
		context = options.context,
		diagnostics = options.diagnostics,
		expectedRevision = options.expectedRevision,
		kind = remoteKind(options),
		lifecycleSessions = options.lifecycleSessions,
		overwrite = options.overwrite,
		revision = options.revision,
		session = options.session,
		sessionFor = options.sessionFor,
		sessions = options.sessions,
		states = options.states,
	}
end

function GuardRemote.contract(remote: any, options: any): any
	assertRemote(remote)
	assertOptions(options)

	local name = remoteName(remote, options)
	local systemContract = System.new(systemName(name, options))
	installActorPolicies(systemContract, actorPolicies(options))
	systemContract:remote(name, payloadSchema(options), remoteOptions(options))
	return systemContract
end

function GuardRemote.connect(remote: any, options: any, handler: any): any
	assertRemote(remote)
	assertOptions(options)
	assertHandler(handler)

	local name = remoteName(remote, options)
	local systemContract = GuardRemote.contract(remote, options)
	return RemoteGuard.connect(systemContract, name, remote, handler, bindOptions(options))
end

return GuardRemote
