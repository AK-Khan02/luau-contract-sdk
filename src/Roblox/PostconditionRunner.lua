local PostconditionRunner = {}

local function record(diagnostics, fields)
	if diagnostics and diagnostics.record then
		return diagnostics:record(fields)
	end
	return fields
end

function PostconditionRunner.run(systemContract, actionName, context, diagnostics, action)
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

	local postconditions = systemContract:checkPostconditions(context, diagnostics)
	return {
		ok = postconditions.ok,
		value = value,
		postconditions = postconditions,
	}
end

return PostconditionRunner
