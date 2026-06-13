--!strict

local Result = require("./Result")
local AsyncGateResults = require("./AsyncGateResults")
local Token = require("./AsyncToken")

local AsyncGateExecution = {}

export type RunOptions = AsyncGateResults.FailureOptions & {
	actor: unknown?,
	timeoutSeconds: number?,
}

export type GateState = {
	_scheduler: {
		spawn: (unknown, ...unknown) -> unknown,
		delay: (number, () -> ()) -> unknown,
	},
	_tokens: { [unknown]: unknown },
}

function AsyncGateExecution.execute(
	gate: GateState,
	options: RunOptions,
	fn: (unknown) -> unknown,
	releaseLock: () -> ()
): (unknown, boolean)
	local token = Token.new()

	local callerThread = coroutine.running()
	local settled = false
	local waiting = false
	local syncResult = nil
	local handlerDone = false
	local timedOut = false

	local function settle(result: unknown): boolean
		if settled then
			return false
		end
		settled = true
		gate._tokens[token] = nil
		if waiting then
			local spawnFn = gate._scheduler.spawn :: (unknown, unknown) -> unknown
			spawnFn(callerThread, result)
		else
			syncResult = result
		end
		return true
	end

	gate._tokens[token] = {
		settle = settle,
		actor = options.actor,
	}

	local spawnFn = gate._scheduler.spawn :: (unknown) -> unknown
	spawnFn(function()
		local ok, value = pcall(fn, token)
		handlerDone = true

		local delivered
		if not ok then
			delivered = settle(AsyncGateResults.failure("ActionHandlerError", tostring(value), options))
		else
			delivered = settle(value)
		end

		if not delivered and timedOut then
			local subject = tostring(options.action or options.remote or "action")
			Result.record(options.diagnostics, {
				level = "warn",
				category = "action",
				system = options.system,
				name = "ActionLateResult",
				message = subject .. " finished after timing out; the late result was discarded",
				context = {
					action = options.action,
					remote = options.remote,
				},
			})
			releaseLock()
		end
	end)

	if settled then
		return syncResult, false
	end

	waiting = true
	local timeoutSeconds = options.timeoutSeconds
	if timeoutSeconds ~= nil then
		local delayFn = gate._scheduler.delay :: (number, () -> ()) -> unknown
		delayFn(timeoutSeconds, function()
			if settled then
				return
			end
			timedOut = true
			token:cancel("timeout")
			local subject = tostring(options.action or options.remote or "action")
			settle(
				AsyncGateResults.failure(
					"ActionTimeout",
					subject .. " timed out after " .. tostring(timeoutSeconds) .. " seconds",
					options
				)
			)
		end)
	end

	local result = coroutine.yield()
	return result, timedOut and not handlerDone
end

return AsyncGateExecution
