--!strict

local Result = require("../Core/Result")

local RemoteGuardLifecycle = {}

local function recordLifecycleError(
	diagnostics: any,
	systemContract: any,
	name: string,
	message: string,
	player: any,
	remoteName: string
)
	Result.record(diagnostics, {
		level = "error",
		category = "lifecycle",
		system = systemContract:name(),
		name = name,
		message = message,
		context = {
			player = player,
			remote = remoteName,
		},
	})
end

local function callResolver(
	resolver: any,
	player: any,
	payload: any,
	remoteName: string,
	diagnostics: any,
	systemContract: any,
	diagnosticName: string
): (any, boolean)
	local ok, value = pcall(resolver, player, payload, remoteName)
	if ok then
		return value, true
	end

	recordLifecycleError(diagnostics, systemContract, diagnosticName, tostring(value), player, remoteName)
	return nil, false
end

local function sessionFromRegistry(
	options: any,
	sessionName: any,
	player: any,
	payload: any,
	remoteName: string,
	diagnostics: any,
	systemContract: any
): (any, boolean)
	local sessions = options.sessions or options.lifecycleSessions
	local resolver = sessions and sessions[sessionName]
	if resolver == nil then
		recordLifecycleError(
			diagnostics,
			systemContract,
			"LifecycleSessionMissing",
			"missing lifecycle session resolver: " .. tostring(sessionName),
			player,
			remoteName
		)
		return nil, false
	end
	if type(resolver) == "function" then
		return callResolver(resolver, player, payload, remoteName, diagnostics, systemContract, "LifecycleSessionError")
	end
	return resolver, true
end

local function fieldPathValue(source: any, path: any): any
	if type(path) ~= "string" or path == "" then
		return nil
	end

	local value = source
	for key in string.gmatch(path, "[^%.]+") do
		if type(value) ~= "table" then
			return nil
		end
		value = value[key]
	end
	return value
end

function RemoteGuardLifecycle.resolveSession(
	options: any,
	remoteOptions: any,
	player: any,
	payload: any,
	remoteName: string,
	diagnostics: any,
	systemContract: any
): (any, boolean)
	if type(options.sessionFor) == "function" then
		return callResolver(
			options.sessionFor,
			player,
			payload,
			remoteName,
			diagnostics,
			systemContract,
			"LifecycleSessionError"
		)
	end
	if options.session ~= nil then
		return options.session, true
	end

	local lifecycle = remoteOptions.lifecycle or {}
	if lifecycle.session ~= nil then
		return sessionFromRegistry(options, lifecycle.session, player, payload, remoteName, diagnostics, systemContract)
	end

	return nil, true
end

function RemoteGuardLifecycle.expectedRevision(
	options: any,
	remoteOptions: any,
	player: any,
	payload: any,
	remoteName: string,
	diagnostics: any,
	systemContract: any
): (any, boolean)
	local revision = options.expectedRevision or options.revision
	local policyRevision = remoteOptions.lifecycle and remoteOptions.lifecycle.revision
	if revision == nil then
		revision = policyRevision
	end

	if type(revision) == "function" then
		return callResolver(
			revision,
			player,
			payload,
			remoteName,
			diagnostics,
			systemContract,
			"LifecycleRevisionError"
		)
	end
	if type(revision) == "string" then
		local value = fieldPathValue(payload, revision)
		if value == nil and policyRevision ~= nil then
			recordLifecycleError(
				diagnostics,
				systemContract,
				"LifecycleRevisionMissing",
				"missing lifecycle revision field: " .. revision,
				player,
				remoteName
			)
			return nil, false
		end
		return value, true
	end
	return revision, true
end

return RemoteGuardLifecycle
