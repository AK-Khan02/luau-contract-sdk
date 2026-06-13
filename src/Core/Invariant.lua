--!strict

export type Result = {
	ok: boolean,
	name: string,
	message: string?,
	reason: any?,
}

local Invariant: any = {}

local function buildMessage(name: string, details: any?): string
	local message = "Invariant failed: " .. tostring(name)
	if details ~= nil then
		message ..= " (" .. tostring(details) .. ")"
	end
	return message
end

local function evaluateCondition(condition: any): (boolean, any?)
	if type(condition) ~= "function" then
		return condition == true, nil
	end

	local ok, resultOrReason = pcall(condition)
	if not ok then
		return false, resultOrReason
	end
	return resultOrReason == true, nil
end

local function resolveWarn(): any?
	-- selene: allow(global_usage)
	local globals: any = _G
	return globals.warn
end

function Invariant.check(name: string, condition: any, details: any?, diagnostics: any?, context: any?): Result
	local ok, errorReason = evaluateCondition(condition)
	if ok then
		return {
			ok = true,
			name = name,
			message = "",
		}
	end

	local message = buildMessage(name, errorReason or details)
	local result: Result = {
		ok = false,
		name = name,
		message = message,
		reason = errorReason or details,
	}

	if diagnostics and diagnostics.record then
		local target: any = diagnostics
		target:record({
			level = "error",
			category = "invariant",
			name = name,
			message = message,
			context = context or {},
		})
	end

	return result
end

function Invariant.warn(name: string, condition: any, details: any?, diagnostics: any?, context: any?): boolean
	local result = Invariant.check(name, condition, details, diagnostics, context)
	local warnFn: any = resolveWarn()
	if not result.ok and type(warnFn) == "function" then
		(warnFn :: (any) -> ())(result.message)
	end
	return result.ok
end

function Invariant.assert(name: string, condition: any, details: any?, diagnostics: any?, context: any?): boolean
	local result = Invariant.check(name, condition, details, diagnostics, context)
	if result.ok then
		return true
	end
	error(result.message, 2)
end

return Invariant
