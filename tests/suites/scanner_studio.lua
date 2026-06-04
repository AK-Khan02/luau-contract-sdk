--!nocheck

local Contracts = require("../../src/Contracts")
local PluginModel = require("../../plugin/LuauContractPluginModel")
local StaticScanner = require("../../src/Core/StaticScanner")
local StudioReport = require("../../src/Studio/StudioReport")

return function(test)
	local function check(name, condition)
		test:check(name, condition)
	end

	test:section("StaticScanner")

	local ruleIds = {}
	for _, rule in ipairs(StaticScanner.rules()) do
		ruleIds[rule.id] = true
	end
	check("scanner exposes registered rules", ruleIds["raw-remote-handler"] == true and ruleIds["async-without-token"] == true)

	local unsafeScan = StaticScanner.scanSource([[
local Remote = {}
local Workspace = {}

Remote.OnServerEvent:Connect(function(player, payload)
	print(payload.Action)
end)

Workspace:ClearAllChildren()

local child = Workspace.CurrentArena
child:Destroy()

task.delay(1, function()
	child.Enabled = false
end)

Remote:FireServer({
	Action = "Deploy",
})
]], {
		path = "Unsafe.server.lua",
	})

	check("scanner finds unsafe source", unsafeScan.summary.total >= 5)
	check("scanner reports raw remote handler", unsafeScan.summary.byRule["raw-remote-handler"] == 1)
	check("scanner reports workspace clear", unsafeScan.summary.byRule["workspace-clear-all"] == 1)
	check("scanner reports unowned destroy", unsafeScan.summary.byRule["unowned-destroy"] == 1)
	check("scanner reports async without token", unsafeScan.summary.byRule["async-without-token"] == 1)
	check("scanner reports raw remote fire", unsafeScan.summary.byRule["raw-remote-fire"] == 1)
	check("scanner formats findings", string.find(StaticScanner.formatReport(unsafeScan), "raw-remote-handler", 1, true) ~= nil)

	local safeScan = StaticScanner.scanSource([[
RemoteGuard.connect(Contract, "DeployRequest", Remote, function(player, payload)
	return payload
end)

local token = spawnToken
task.delay(1, function()
	if token ~= spawnToken then
		return
	end
	state.Ready = true
end)

Ownership.destroyOwned("CombatService", tool)

local effectsFolder = Workspace:FindFirstChild("CombatEffects")
if effectsFolder then
	effectsFolder:ClearAllChildren()
end
]], {
		path = "Safe.server.lua",
	})

	check("scanner ignores guarded source", safeScan.summary.total == 0)

	local ignoredScan = StaticScanner.scanSource([[
tool:Destroy() -- contracts-scan: ignore unowned-destroy
]], {
		path = "Intentional.server.lua",
	})

	check("scanner supports inline ignore", ignoredScan.summary.total == 0)

	test:section("StudioReport")

	local studioDiagnostics = Contracts.diagnostics()
	studioDiagnostics:record({
		level = "error",
		category = "postcondition",
		system = "CombatService",
		name = "OneWeaponToolAfterSpawn",
		message = "missing weapon",
	})

	local studioReport = StudioReport.fromScripts({
		{
			path = "ReplicatedStorage.Contracts.Combat",
			className = "ModuleScript",
			source = [[
local Contracts = require(Contracts)

return Contracts.system("CombatService")
	:ownsTag("GeneratedWeaponTool")
	:ownsFolder("Workspace.CombatEffects")
	:remote("WeaponAction", Contracts.object({}))
	:postcondition("PlayerHasWeapon", function(context)
		return true
	end)
]],
		},
		{
			path = "ServerScriptService.MatchService",
			className = "Script",
			source = [[
DeployRequest.OnServerEvent:Connect(function(player, payload)
	print(payload)
end)
]],
		},
	}, {
		diagnosticsReport = studioDiagnostics:report(),
	})

	check("studio report counts scripts", studioReport.summary.scriptCount == 2)
	check("studio report extracts contract systems", studioReport.summary.systemCount == 1)
	check("studio report extracts system details", studioReport.systems[1].remotes == 1 and studioReport.systems[1].postconditions == 1)
	check("studio report includes scanner findings", studioReport.summary.scannerFindingCount == 1)
	check("studio report includes diagnostics", studioReport.summary.diagnosticCount == 1 and #studioReport.diagnostics == 1)
	check("studio report formats systems", string.find(StudioReport.formatSystem(studioReport.systems[1]), "CombatService", 1, true) ~= nil)
	check("studio report formats diagnostics", string.find(StudioReport.formatDiagnostic(studioReport.diagnostics[1]), "missing weapon", 1, true) ~= nil)
	check("studio report formats findings", string.find(StudioReport.formatFinding(studioReport.scanner.findings[1]), "raw-remote-handler", 1, true) ~= nil)

	test:section("StudioPluginModel")

	local fakeScript = {
		Name = "MatchService",
		ClassName = "Script",
		Source = "print('scan me')",
		GetFullName = function()
			return "ServerScriptService.MatchService"
		end,
	}

	local fakeRoot = {
		GetDescendants = function()
			return {
				fakeScript,
				{
					Name = "Baseplate",
					ClassName = "Part",
				},
			}
		end,
	}

	local scripts = PluginModel.collectScripts(fakeRoot)
	check("plugin model collects script sources", #scripts == 1 and scripts[1].path == "ServerScriptService.MatchService")

	local cards = PluginModel.summaryCards(studioReport)
	check("plugin model builds summary cards", #cards == 4 and cards[1].label == "Systems")

	local findingRows = PluginModel.findingRows(studioReport)
	check("plugin model builds finding rows", #findingRows == 1 and findingRows[1].tone == "error")
end
