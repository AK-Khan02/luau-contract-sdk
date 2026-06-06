--!strict

local okRemoteHarness, RemoteHarness = pcall(require, "./RemoteHarness")
if not okRemoteHarness then
	RemoteHarness = require("./Test/RemoteHarness")
end

local Test = {
	RemoteHarness = RemoteHarness,
}

function Test.remoteHarness(systemContract: any, options: any?): any
	return RemoteHarness.new(systemContract, options)
end

return Test
