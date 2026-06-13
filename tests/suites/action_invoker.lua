--!strict

local ActionInvoker = require("../../src/Core/ActionInvoker")
local Contracts = require("../../src/Contracts")
local ManualScheduler = require("../../src/Test/ManualScheduler")

local function buildSystem(): any
	return Contracts.system("InvokerService")
		:action("Grant", {
			input = Contracts.object({
				id = Contracts.stringId(),
			}, { allowExtra = false }),
			output = Contracts.object({
				granted = Contracts.boolean(),
			}, { allowExtra = false }),
		})
		:action("Slow", {
			input = Contracts.any(),
		})
end

return function(test: any)
	local function check(name: string, condition: any)
		test:check(name, condition)
	end

	test:section("ActionInvoker")

	local system = buildSystem()
	local actor = { UserId = 42 }
	local handlerRequest = { source = "runtime" }
	local seenRequest: any = nil
	local started = 0
	local pipelineInfo: any = nil

	local result = ActionInvoker.run({
		system = system,
		action = "Grant",
		actor = actor,
		payload = {
			id = "Sword",
		},
		context = {},
		validated = true,
		handlerRequest = handlerRequest,
		handler = function(scope: any, request: any)
			seenRequest = request
			return {
				granted = scope:payload().id == "Sword",
			}
		end,
		pipeline = function(info: any, run: any)
			pipelineInfo = info
			return run(function()
				started += 1
			end)
		end,
	})

	check("invoker runs actions through the supplied pipeline", result.ok == true and result.value.granted == true)
	check("invoker forwards handler request", seenRequest == handlerRequest)
	check(
		"invoker exposes pipeline identity",
		pipelineInfo.action == "Grant" and pipelineInfo.actor == actor and pipelineInfo.validated == true
	)
	check("invoker starts non-async calls exactly once", started == 1)

	local gateKey = nil
	local fakeGate = {
		run = function(_: any, key: any, options: any, execute: any)
			gateKey = key
			options.onStarted()
			return execute(nil)
		end,
	}
	local fallbackResult = ActionInvoker.run({
		system = system,
		action = "Slow",
		payload = {},
		asyncPolicy = {
			concurrency = "reject",
			timeoutSeconds = false,
		},
		asyncGate = fakeGate,
		asyncFallbackKey = "RemoteFallback",
		handler = function()
			return "ok"
		end,
	})
	check(
		"invoker uses explicit fallback key for anonymous async calls",
		fallbackResult.ok == true and gateKey == "RemoteFallback"
	)

	local scheduler = ManualScheduler.new()
	local asyncGate = Contracts.AsyncGate.new({
		scheduler = scheduler,
	})
	local threads = {}
	local results = {}
	local order = {}

	local function invokeSlow(slot: number)
		scheduler.spawn(function()
			results[slot] = ActionInvoker.run({
				system = system,
				action = "Slow",
				payload = {},
				asyncPolicy = {
					concurrency = "serialize",
					timeoutSeconds = false,
				},
				asyncGate = asyncGate,
				asyncFallbackKey = "SharedRemote",
				handler = function()
					table.insert(order, "start:" .. tostring(slot))
					threads[slot] = coroutine.running()
					coroutine.yield()
					table.insert(order, "finish:" .. tostring(slot))
					return slot
				end,
			})
		end)
	end

	invokeSlow(1)
	invokeSlow(2)
	check("invoker serializes shared async fallback key", #order == 1 and order[1] == "start:1")

	scheduler.spawn(threads[1])
	check(
		"invoker starts queued fallback-key call after release",
		order[3] == "start:2" and results[1] ~= nil and results[1].value == 1
	)
	scheduler.spawn(threads[2])
	check("invoker completes queued fallback-key call", results[2] ~= nil and results[2].value == 2)
end
