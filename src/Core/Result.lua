--!strict

export type Failure = {
	ok: false,
	name: string,
	reason: any?,
	context: any?,
	[string]: any,
}

export type Success = {
	ok: true,
	value: any?,
	[string]: any,
}

export type DiagnosticFields = {
	level: string,
	category: string,
	system: string?,
	name: string,
	message: string?,
	context: any?,
	[string]: any,
}

local Result = {}

local function copyMap(values: any?): any
	local copy = {}
	for key, value in pairs(values or {}) do
		copy[key] = value
	end
	return copy
end

function Result.ok(value: any?, fields: any?): Success
	local result = copyMap(fields)
	result.ok = true
	result.value = value
	return result
end

function Result.fail(name: string, reason: any?, fields: any?): Failure
	local result = copyMap(fields)
	result.ok = false
	result.name = name
	result.reason = reason
	return result
end

function Result.record(diagnostics: any, fields: DiagnosticFields): any
	if diagnostics and diagnostics.record then
		local target: any = diagnostics
		return target:record(fields)
	end
	return fields
end

function Result.failWithDiagnostic(diagnostics: any, fields: DiagnosticFields, failureFields: any?): Failure
	Result.record(diagnostics, fields)
	local details = copyMap(failureFields)
	if details.context == nil then
		details.context = fields.context
	end
	local reason = details.reason
	if reason == nil then
		reason = fields.message
	end
	return Result.fail(fields.name, reason, details)
end

return Result
