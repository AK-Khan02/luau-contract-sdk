--!strict

local RuntimePipeline = {}

function RuntimePipeline.run(runtime: any, info: any, run: any): any
	-- Snapshot the matching wrap chain at invocation start: use()/remove during
	-- an in-flight invocation must only affect later invocations.
	local chain: { any } = {}
	for _, entry in ipairs(runtime._middleware) do
		if entry.actions == nil or entry.actions[info.action] == true then
			table.insert(chain, entry.fn)
		end
	end

	local hasTaps = next(runtime._taps) ~= nil
	local clock = runtime:_pipelineClock()
	local queuedAt = clock()
	local startedAt = nil

	local function onStarted()
		startedAt = clock()
		if hasTaps then
			runtime:_emitTap("started", {
				action = info.action,
				actor = info.actor,
				remote = info.remote,
				queuedAt = queuedAt,
				startedAt = startedAt,
			})
		end
	end

	local validResults: any = setmetatable({}, { __mode = "k" })
	local function accept(result: any): any
		if type(result) == "table" then
			validResults[result] = true
		end
		return result
	end

	local ranAction = false
	local ctx: any = {
		action = info.action,
		actor = info.actor,
		payload = info.payload,
		remote = info.remote,
		validated = info.validated == true,
		locals = {},
	}

	function ctx.fail(_: any, name: any, reason: any): any
		if ranAction then
			error("ctx:fail cannot be called after next()", 2)
		end
		local failName = type(name) == "string" and name or "ActionRejected"
		local message = reason ~= nil and tostring(reason) or (failName .. " from middleware")
		return accept(runtime:_middlewareFailure(info, failName, message))
	end

	local function invokeChain(index: number): any
		if index > #chain then
			ranAction = true
			return accept(run(onStarted))
		end

		local middlewareFn = chain[index]
		local nextCalled = false
		local function nextFn(): any
			if nextCalled then
				error("next() already called", 2)
			end
			nextCalled = true
			return invokeChain(index + 1)
		end

		local ok, value = pcall(middlewareFn, ctx, nextFn)
		if not ok then
			return accept(runtime:_middlewareFailure(info, "ActionMiddlewareError", tostring(value)))
		end
		if type(value) == "table" and validResults[value] == true then
			return value
		end
		return accept(
			runtime:_middlewareFailure(
				info,
				"ActionMiddlewareInvalidResult",
				"middleware must return next() result or ctx:fail() result"
			)
		)
	end

	local result = invokeChain(1)

	if hasTaps then
		runtime:_emitTap("settled", {
			action = info.action,
			actor = info.actor,
			remote = info.remote,
			queuedAt = queuedAt,
			startedAt = startedAt,
			settledAt = clock(),
			ok = type(result) == "table" and result.ok == true,
			outcome = type(result) == "table" and result.name or nil,
			result = result,
		})
	end

	return result
end

return RuntimePipeline
