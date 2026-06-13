--!strict

local Result = require("../Core/Result")

local PostconditionRunner = {}

local record = Result.record

function PostconditionRunner.run(
	systemContract: any,
	actionName: string,
	context: any?,
	diagnostics: any?,
	action: any
): any
	if not systemContract or not systemContract.checkPostconditions then
		error("PostconditionRunner.run expects a system contract", 2)
	end
	if type(action) ~= "function" then
		error("PostconditionRunner.run expects an action function", 2)
	end

	context = context or {}
	context.action = context.action or actionName

	local ok, value = pcall(action, context)
	if not ok then
		record(diagnostics, {
			level = "error",
			category = "action",
			system = systemContract:name(),
			name = "ContractedActionError",
			message = tostring(value),
			context = context,
		})
		return {
			ok = false,
			reason = value,
		}
	end

	local checkPostconditions = systemContract.checkPostconditions :: (any, any?, any?) -> any
	local postconditions = checkPostconditions(systemContract, context, diagnostics)
	return {
		ok = postconditions.ok,
		value = value,
		postconditions = postconditions,
	}
end

return PostconditionRunner
