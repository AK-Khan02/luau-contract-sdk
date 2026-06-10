--!nocheck
--!nolint UnknownGlobal

local TaskScheduler = {}

local function resolveTaskLibrary()
	local ok, taskLib = pcall(function()
		return task
	end)
	if ok and type(taskLib) == "table" and type(taskLib.spawn) == "function" and type(taskLib.delay) == "function" then
		return taskLib
	end
	return nil
end

function TaskScheduler.default()
	local taskLib = resolveTaskLibrary()
	if taskLib == nil then
		return nil
	end

	return {
		spawn = function(fnOrThread, ...)
			return taskLib.spawn(fnOrThread, ...)
		end,
		delay = function(seconds, callback)
			local thread = taskLib.delay(seconds, callback)
			return function()
				if type(taskLib.cancel) == "function" then
					pcall(taskLib.cancel, thread)
				end
			end
		end,
		clock = function()
			return os.clock()
		end,
	}
end

return TaskScheduler
