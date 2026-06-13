--!strict

local RuntimeTypes = require("./RuntimeTypes")
local TableUtil = require("./TableUtil")

export type DiagnosticsSink = RuntimeTypes.DiagnosticsSink
export type Request = RuntimeTypes.Request
export type NormalizedRequest = RuntimeTypes.NormalizedRequest

local RuntimeRequest = {}

local copyMap = TableUtil.copyMap

local function fieldPathValue(source: unknown, path: unknown): unknown
	if type(path) ~= "string" or path == "" then
		return nil
	end

	local value = source
	for key in string.gmatch(path, "[^%.]+") do
		if type(value) ~= "table" then
			return nil
		end
		value = (value :: { [unknown]: unknown })[key]
	end
	return value
end

local function contextFromRequest(request: Request): { [unknown]: unknown }
	local context = copyMap(request.context or {})
	if request.remote ~= nil then
		context.remote = context.remote or request.remote
	end
	return context
end

local function actorFromRequest(request: Request): unknown
	if request.actor ~= nil then
		return request.actor
	end
	return request.player
end

local function payloadFromRequest(request: Request): unknown
	if request.payload ~= nil then
		return request.payload
	end
	return request.input
end

local function expectedRevisionFromRequest(request: Request, payload: unknown): unknown
	local expectedRevision = request.expectedRevision
	if expectedRevision == nil then
		expectedRevision = request.revision
	end
	if type(expectedRevision) == "string" then
		return fieldPathValue(payload, expectedRevision)
	end
	return expectedRevision
end

function RuntimeRequest.normalize(
	actionName: string,
	request: Request?,
	defaultDiagnostics: DiagnosticsSink
): NormalizedRequest
	local source: Request = request or {}
	local payload = payloadFromRequest(source)

	return {
		action = actionName,
		actor = actorFromRequest(source),
		payload = payload,
		context = contextFromRequest(source),
		diagnostics = source.diagnostics or defaultDiagnostics,
		session = source.session,
		sessionName = source.sessionName,
		states = source.states,
		expectedRevision = expectedRevisionFromRequest(source, payload),
		remote = source.remote,
	}
end

return RuntimeRequest
