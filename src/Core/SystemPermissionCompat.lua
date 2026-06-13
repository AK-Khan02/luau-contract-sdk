--!strict

export type AccessRequest = {
	actionName: string?,
	targetPath: string,
	diagnostics: any?,
	context: any?,
}

export type EffectRequest = {
	actionName: string?,
	effect: any,
	diagnostics: any?,
	context: any?,
}

local SystemPermissionCompat = {}

function SystemPermissionCompat.access(
	targetPath: any,
	diagnostics: any?,
	context: any?,
	legacyContext: any?
): AccessRequest
	if type(diagnostics) == "string" then
		return {
			actionName = targetPath :: string,
			targetPath = diagnostics,
			diagnostics = context,
			context = legacyContext,
		}
	end

	return {
		actionName = nil,
		targetPath = targetPath,
		diagnostics = diagnostics,
		context = context,
	}
end

function SystemPermissionCompat.effect(
	effect: any,
	diagnostics: any?,
	context: any?,
	legacyContext: any?
): EffectRequest
	if type(effect) == "string" and type(diagnostics) == "table" then
		return {
			actionName = effect,
			effect = diagnostics,
			diagnostics = context,
			context = legacyContext,
		}
	end

	return {
		actionName = nil,
		effect = effect,
		diagnostics = diagnostics,
		context = context,
	}
end

return SystemPermissionCompat
