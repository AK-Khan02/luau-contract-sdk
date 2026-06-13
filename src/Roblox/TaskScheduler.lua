--!strict

local PlayersService = require("./PlayersService")

export type Scheduler = {
	spawn: (any, ...any) -> any,
	delay: (number, () -> ()) -> () -> (),
	clock: (() -> number)?,
}

type TaskLibrary = {
	spawn: (any, ...any) -> any,
	delay: (number, () -> ()) -> any,
	cancel: ((any) -> ())?,
}

local TaskScheduler = {}

function TaskScheduler.from(taskLib: any): Scheduler?
	if type(taskLib) ~= "table" or type(taskLib.spawn) ~= "function" or type(taskLib.delay) ~= "function" then
		return nil
	end

	local typedTaskLib = taskLib :: TaskLibrary
	return {
		spawn = function(fnOrThread: any, ...: any): any
			return typedTaskLib.spawn(fnOrThread, ...)
		end,
		delay = function(seconds: number, callback: () -> ()): () -> ()
			local thread = typedTaskLib.delay(seconds, callback)
			return function()
				if typedTaskLib.cancel ~= nil then
					pcall(typedTaskLib.cancel, thread)
				end
			end
		end,
		clock = function(): number
			return os.clock()
		end,
	}
end

function TaskScheduler.default(): Scheduler?
	return TaskScheduler.from(PlayersService.resolveTaskLibrary())
end

return TaskScheduler
