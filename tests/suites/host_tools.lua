--!strict

local Contracts = require("../../src/Contracts")
local JsonEncode = require("../../src/Host/JsonEncode")
local ReportPolicy = require("../../src/Host/ReportPolicy")
local ScanRunner = require("../../src/Host/ScanRunner")

return function(test)
	local function check(name, condition)
		test:check(name, condition)
	end

	test:section("HostTools")

	local encoded = JsonEncode.encode({
		name = "Inventory\nService",
		counts = { 1, 2 },
		ok = true,
	})
	check("json encoder escapes strings", string.find(encoded, "Inventory\\nService", 1, true) ~= nil)
	check("json encoder encodes arrays", string.find(encoded, '"counts":[1,2]', 1, true) ~= nil)
	check("json encoder preserves numeric object keys", JsonEncode.encode({
		[2] = "two",
		name = "mixed",
	}) == '{"2":"two","name":"mixed"}')

	local report = ScanRunner.run({
		scripts = {
			{
				path = "ServerScriptService.MatchService",
				className = "Script",
				source = [[
DeployRequest.OnServerEvent:Connect(function(player, payload)
	print(payload)
end)
]],
			},
		},
		policy = {
			failOn = "error",
		},
	})

	check("scan runner includes rule metadata", report.scanner.rules["raw-remote-handler"].severity == "error")
	check("scan runner includes emitted rule metadata", report.scanner.rules["workspace-clear-all"].severity == "error")
	check("scan runner finds unsafe script", report.summary.scannerFindingCount == 1)
	check("scan runner evaluates failing policy", report.policy.ok == false and report.policy.exitCode == 1)

	local findingKey = ReportPolicy.findingKey(report.scanner.findings[1])
	local baselinedReport = ScanRunner.run({
		scripts = {
			{
				path = "ServerScriptService.MatchService",
				className = "Script",
				source = [[
DeployRequest.OnServerEvent:Connect(function(player, payload)
	print(payload)
end)
]],
			},
		},
		policy = {
			failOn = "error",
			baselineKeys = { findingKey },
		},
	})
	check(
		"policy suppresses baseline findings",
		baselinedReport.policy.ok == true
			and baselinedReport.policy.newFindingCount == 0
			and baselinedReport.policy.suppressedByBaseline == 1
	)

	local fakeContract =
		Contracts.system("FakeInventory"):strictPermissions():mayWrite("Player.Inventory"):action("GrantItem", {
			writes = { "Player.Inventory" },
		})

	local exactReport = ScanRunner.run({
		scripts = {},
		contracts = {
			{
				path = "examples/fake.contract.lua",
				contract = fakeContract,
			},
		},
	})
	check("scan runner includes exact contract reports", exactReport.contracts[1].name == "FakeInventory")
	check("exact contract reports preserve path", exactReport.contracts[1].path == "examples/fake.contract.lua")
end
