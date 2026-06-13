--!strict

local Names = require("./Names")
local Result = require("./Result")
local TableUtil = require("./TableUtil")

local SystemLifecyclePolicy = {}

local assertName = Names.assertName
local copyMap = TableUtil.copyMap
local recordViolation = Result.record

function SystemLifecyclePolicy.checkActionLifecycle(
	self: any,
	actionName: string,
	states: any,
	diagnostics: any?,
	context: any?
): any
	local action = self._actions[actionName]
	if not action then
		return {
			ok = false,
			failures = {
				{
					ok = false,
					name = "UnknownAction",
					reason = "unknown action contract: " .. tostring(actionName),
				},
			},
		}
	end

	local failures = {}
	for lifecycleName, requiredState in pairs(action.lifecycle.requires) do
		local currentState = states and states[lifecycleName]
		if currentState ~= requiredState then
			local name = "ActionLifecycleStateInvalid"
			local message = self._name
				.. "."
				.. actionName
				.. " requires "
				.. lifecycleName
				.. " to be "
				.. requiredState
			recordViolation(diagnostics, {
				level = "error",
				category = "lifecycle",
				system = self._name,
				name = name,
				message = message,
				context = context or {
					action = actionName,
					lifecycle = lifecycleName,
					expected = requiredState,
					actual = currentState,
				},
			})
			table.insert(failures, {
				ok = false,
				name = name,
				reason = message,
			})
		end
	end

	return {
		ok = #failures == 0,
		failures = failures,
	}
end

function SystemLifecyclePolicy.reduceActionLifecycle(
	self: any,
	actionName: string,
	states: any,
	diagnostics: any?,
	context: any?
): any
	local action = self._actions[actionName]
	local nextStates = copyMap(states or {})
	local transitions = {}
	local failures = {}

	if not action then
		return {
			ok = false,
			states = nextStates,
			transitions = transitions,
			failures = {
				{
					ok = false,
					name = "UnknownAction",
					reason = "unknown action contract: " .. tostring(actionName),
				},
			},
		}
	end

	for lifecycleName, eventName in pairs(action.lifecycle.emits) do
		local lifecycle = self._lifecycles[lifecycleName]
		local currentState = nextStates[lifecycleName]
		if lifecycle == nil then
			local name = "ActionLifecycleUnknown"
			local message = "unknown lifecycle contract: " .. tostring(lifecycleName)
			recordViolation(diagnostics, {
				level = "error",
				category = "lifecycle",
				system = self._name,
				name = name,
				message = message,
				context = context or {
					action = actionName,
					lifecycle = lifecycleName,
					event = eventName,
				},
			})
			table.insert(failures, {
				ok = false,
				name = name,
				reason = message,
			})
		elseif currentState == nil then
			local name = "ActionLifecycleStateMissing"
			local message = self._name .. "." .. actionName .. " needs current " .. lifecycleName .. " state"
			recordViolation(diagnostics, {
				level = "error",
				category = "lifecycle",
				system = self._name,
				name = name,
				message = message,
				context = context or {
					action = actionName,
					lifecycle = lifecycleName,
					event = eventName,
				},
			})
			table.insert(failures, {
				ok = false,
				name = name,
				reason = message,
			})
		else
			local nextState, didTransition = lifecycle:reduce(currentState, eventName)
			if didTransition then
				nextStates[lifecycleName] = nextState
				table.insert(transitions, {
					lifecycle = lifecycleName,
					event = eventName,
					from = currentState,
					to = nextState,
				})
			else
				local name = "ActionLifecycleTransitionInvalid"
				local message = self._name
					.. "."
					.. actionName
					.. " cannot emit "
					.. eventName
					.. " from "
					.. tostring(currentState)
				recordViolation(diagnostics, {
					level = "error",
					category = "lifecycle",
					system = self._name,
					name = name,
					message = message,
					context = context or {
						action = actionName,
						lifecycle = lifecycleName,
						event = eventName,
						state = currentState,
					},
				})
				table.insert(failures, {
					ok = false,
					name = name,
					reason = message,
				})
			end
		end
	end

	return {
		ok = #failures == 0,
		states = nextStates,
		transitions = transitions,
		failures = failures,
	}
end

function SystemLifecyclePolicy._actorFailure(
	self: any,
	ownerKind: string,
	ownerName: string,
	failure: string,
	message: string,
	reason: any?,
	context: any?,
	diagnostics: any?
): any
	local diagnosticName = "ActionActorRejected"
	if ownerKind == "remote" then
		diagnosticName = "Remote" .. failure
	elseif failure == "ActorPolicyUnknown" then
		diagnosticName = "ActionActorPolicyUnknown"
	end

	local failureContext = copyMap(context or {})
	failureContext[ownerKind] = ownerName

	recordViolation(diagnostics, {
		level = "error",
		category = ownerKind,
		system = self._name,
		name = diagnosticName,
		message = message,
		context = failureContext,
	})

	return {
		ok = false,
		name = diagnosticName,
		reason = reason or message,
		message = message,
	}
end

function SystemLifecyclePolicy._checkActorPolicy(
	self: any,
	ownerKind: string,
	ownerName: string,
	actorPolicy: any,
	actor: any,
	context: any?,
	diagnostics: any?
): any
	if actorPolicy == nil then
		return {
			ok = true,
		}
	end

	local subject = self._name .. "." .. ownerName
	if actorPolicy == true or actorPolicy == "required" then
		if actor ~= nil then
			return {
				ok = true,
			}
		end
		return self:_actorFailure(
			ownerKind,
			ownerName,
			"ActorRequired",
			subject .. " requires an actor",
			nil,
			context,
			diagnostics
		)
	end

	local check = actorPolicy
	local policyName = nil
	if type(actorPolicy) == "string" then
		policyName = actorPolicy
		check = self._actorPolicies[actorPolicy]
	elseif type(actorPolicy) == "table" then
		policyName = actorPolicy.name or actorPolicy.policy
		check = actorPolicy.check or actorPolicy.authorize
		if actorPolicy.required == true and actor == nil then
			return self:_actorFailure(
				ownerKind,
				ownerName,
				"ActorRequired",
				subject .. " requires an actor",
				nil,
				context,
				diagnostics
			)
		end
	end

	if type(check) ~= "function" then
		local missingName = policyName or tostring(actorPolicy)
		return self:_actorFailure(
			ownerKind,
			ownerName,
			"ActorPolicyUnknown",
			subject .. " references unknown actor policy " .. tostring(missingName),
			missingName,
			context,
			diagnostics
		)
	end

	local ok, acceptedOrReason = pcall(check, actor, context or {})
	if ok and acceptedOrReason == true then
		return {
			ok = true,
		}
	end

	local reason = ok and acceptedOrReason or acceptedOrReason
	local message = subject .. " rejected actor"
	if reason ~= nil and reason ~= false then
		message ..= " (" .. tostring(reason) .. ")"
	end

	return self:_actorFailure(ownerKind, ownerName, "ActorRejected", message, reason, context, diagnostics)
end

function SystemLifecyclePolicy.checkRemoteActor(
	self: any,
	remoteName: string,
	actor: any,
	context: any?,
	diagnostics: any?
): any
	assertName("Remote name", remoteName)
	local remote = self._remotes[remoteName]
	if not remote then
		local message = "unknown remote contract: " .. tostring(remoteName)
		recordViolation(diagnostics, {
			level = "error",
			category = "remote",
			system = self._name,
			name = "UnknownRemote",
			message = message,
			context = context or {
				remote = remoteName,
			},
		})
		return {
			ok = false,
			name = "UnknownRemote",
			reason = message,
		}
	end

	local actorContext = copyMap(context or {})
	actorContext.actor = actorContext.actor or actor
	actorContext.player = actorContext.player or actor
	actorContext.remote = actorContext.remote or remoteName

	return self:_checkActorPolicy("remote", remoteName, remote.actor, actor, actorContext, diagnostics)
end

function SystemLifecyclePolicy.checkActionPolicy(self: any, actionName: string, context: any?, diagnostics: any?): any
	local action = self._actions[actionName]
	if not action then
		return {
			ok = false,
			name = "UnknownAction",
			reason = "unknown action contract: " .. tostring(actionName),
		}
	end

	local policy = action.policy or {}
	local actorPolicy = policy.actor or policy.authorize
	if actorPolicy == nil and policy.actorRequired == true then
		actorPolicy = "required"
	elseif policy.actorRequired == true and (context == nil or context.actor == nil) then
		return self:_checkActorPolicy("action", actionName, "required", nil, context, diagnostics)
	end

	local actor = context and context.actor or nil
	return self:_checkActorPolicy("action", actionName, actorPolicy, actor, context, diagnostics)
end
return SystemLifecyclePolicy
