--!strict

local Result = require("./Result")

local AsyncGateResults = {}

export type FailureOptions = {
	diagnostics: unknown?,
	system: string?,
	action: string?,
	remote: string?,
}

function AsyncGateResults.failureResult(name: string, reason: string): unknown
	return Result.fail(name, reason)
end

function AsyncGateResults.failure(name: string, reason: string, options: FailureOptions): unknown
	return Result.failWithDiagnostic(options.diagnostics, {
		level = "error",
		category = "action",
		system = options.system,
		name = name,
		message = reason,
		context = {
			action = options.action,
			remote = options.remote,
		},
	})
end

return AsyncGateResults
