--!strict

local okRemoteHarness, RemoteHarness = pcall(require, "./RemoteHarness")
if not okRemoteHarness then
	RemoteHarness = require("./Test/RemoteHarness")
end

local okManualScheduler, ManualScheduler = pcall(require, "./ManualScheduler")
if not okManualScheduler then
	ManualScheduler = require("./Test/ManualScheduler")
end

local Test = {
	ManualScheduler = ManualScheduler,
	RemoteHarness = RemoteHarness,
}

function Test.manualScheduler(startTime: number?): any
	return ManualScheduler.new(startTime)
end

function Test.remoteHarness(systemContract: any, options: any?): any
	return RemoteHarness.new(systemContract, options)
end

return Test
