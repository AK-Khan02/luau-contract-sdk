--!strict

export type Description = {
	name: string,
	states: {string},
	transitions: {[string]: {[string]: string}},
}

local Lifecycle: any = {}
Lifecycle.__index = Lifecycle

local function copyList(values: {string}): {string}
	local copy = {}
	for index, value in ipairs(values) do
		copy[index] = value
	end
	return copy
end

local function copyTransitions(transitions: {[string]: {[string]: string}}): {[string]: {[string]: string}}
	local copy = {}
	for state, events in pairs(transitions) do
		copy[state] = {}
		for eventName, nextState in pairs(events) do
			copy[state][eventName] = nextState
		end
	end
	return copy
end

function Lifecycle.new(name: string): any
	if type(name) ~= "string" or name == "" then
		error("Lifecycle name must be a non-empty string", 2)
	end

	return setmetatable({
		_name = name,
		_states = {},
		_stateSet = {},
		_transitions = {},
	}, Lifecycle)
end

function Lifecycle.state(self: any, name: string): any
	if type(name) ~= "string" or name == "" then
		error("Lifecycle state must be a non-empty string", 2)
	end

	if not self._stateSet[name] then
		self._stateSet[name] = true
		table.insert(self._states, name)
	end
	return self
end

function Lifecycle.transition(self: any, fromState: string, eventName: string, toState: string): any
	self:state(fromState)
	self:state(toState)

	if type(eventName) ~= "string" or eventName == "" then
		error("Lifecycle event must be a non-empty string", 2)
	end

	self._transitions[fromState] = self._transitions[fromState] or {}
	self._transitions[fromState][eventName] = toState
	return self
end

function Lifecycle.canTransition(self: any, fromState: string, eventName: string): boolean
	return self._transitions[fromState] ~= nil and self._transitions[fromState][eventName] ~= nil
end

function Lifecycle.reduce(self: any, fromState: string, eventName: string): (string, boolean)
	local events = self._transitions[fromState]
	if not events or events[eventName] == nil then
		return fromState, false
	end
	return events[eventName], true
end

function Lifecycle.validateState(self: any, state: string): (boolean, string?)
	if self._stateSet[state] then
		return true, nil
	end
	return false, "unknown " .. self._name .. " state: " .. tostring(state)
end

function Lifecycle.describe(self: any): Description
	return {
		name = self._name,
		states = copyList(self._states),
		transitions = copyTransitions(self._transitions),
	}
end

return Lifecycle
