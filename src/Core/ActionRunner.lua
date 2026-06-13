--!strict

local ActionScope = require("./ActionScope")
local Completion = require("./ActionRunnerCompletion")
local Guards = require("./ActionRunnerGuards")

export type Options = Guards.Options

local ActionRunner = {}

function ActionRunner.run(
	systemContract: unknown,
	actionName: string,
	options: Options,
	handler: (unknown) -> unknown
): unknown
	local prepared = Guards.prepare(systemContract, actionName, options)
	if not prepared.ok then
		return prepared.failure
	end

	local context = prepared.context :: { [unknown]: unknown }
	local diagnostics = options.diagnostics
	local scope = ActionScope.new(systemContract, actionName, context, diagnostics)
	context.effects = scope:effectView()

	local ok, value = pcall(handler, scope)
	if not ok then
		return Completion.handlerFailure(systemContract, diagnostics, context, scope, value)
	end

	return Completion.finish(systemContract, actionName, options, prepared, scope, value)
end

return ActionRunner
