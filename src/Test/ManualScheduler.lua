--!strict

local ManualScheduler = {}

function ManualScheduler.new(startTime: number?): any
	local scheduler: any = {
		_now = startTime or 0,
		_timers = {},
	}

	function scheduler.spawn(fnOrThread: any, ...: any): any
		if type(fnOrThread) == "thread" then
			local ok, err = coroutine.resume(fnOrThread, ...)
			if not ok then
				error(err, 2)
			end
			return fnOrThread
		end
		if type(fnOrThread) ~= "function" then
			error("ManualScheduler.spawn expects a function or thread", 2)
		end

		local thread = coroutine.create(fnOrThread)
		local ok, err = coroutine.resume(thread, ...)
		if not ok then
			error(err, 2)
		end
		return thread
	end

	function scheduler.delay(seconds: number, callback: () -> ()): any
		if type(seconds) ~= "number" or seconds < 0 then
			error("ManualScheduler.delay expects a non-negative delay", 2)
		end
		if type(callback) ~= "function" then
			error("ManualScheduler.delay expects a callback", 2)
		end

		local timer = {
			at = scheduler._now + seconds,
			callback = callback,
			cancelled = false,
		}
		table.insert(scheduler._timers, timer)
		return function()
			timer.cancelled = true
		end
	end

	function scheduler.clock(): number
		return scheduler._now
	end

	function scheduler.advance(deltaSeconds: number)
		if type(deltaSeconds) ~= "number" or deltaSeconds < 0 then
			error("ManualScheduler.advance expects a non-negative delta", 2)
		end

		scheduler._now += deltaSeconds

		while true do
			local dueIndex = nil
			local dueAt = nil
			for index, timer in ipairs(scheduler._timers) do
				if not timer.cancelled and timer.at <= scheduler._now then
					if dueAt == nil or timer.at < dueAt then
						dueIndex = index
						dueAt = timer.at
					end
				end
			end

			if dueIndex == nil then
				break
			end

			local timer = table.remove(scheduler._timers, dueIndex)
			scheduler.spawn(timer.callback)
		end
	end

	function scheduler.pendingTimerCount(): number
		local count = 0
		for _, timer in ipairs(scheduler._timers) do
			if not timer.cancelled then
				count += 1
			end
		end
		return count
	end

	return scheduler
end

return ManualScheduler
