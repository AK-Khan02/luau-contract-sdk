--!nocheck

local Contracts = require("../../src/Contracts")

return function(test)
	local function check(name, condition)
		test:check(name, condition)
	end

	test:section("Diagnostics")

	local now = 0
	local diagnostics = Contracts.diagnostics({
		capacity = 2,
		clock = function()
			now += 1
			return now
		end,
	})

	diagnostics:record({ name = "A", message = "first", system = "Alpha", category = "remote" })
	diagnostics:record({ name = "B", message = "second", system = "Beta", category = "lifecycle" })
	diagnostics:record({ name = "C", message = "third", system = "Beta", category = "remote" })

	check("diagnostics keeps capacity", diagnostics:count() == 2)
	check("diagnostics tracks dropped records", diagnostics:droppedCount() == 1)
	check("diagnostics keeps latest entry", diagnostics:last().name == "C")
	check("diagnostics findByName works", #diagnostics:findByName("B") == 1)
	check("diagnostics assigns ids", diagnostics:last().id == 3)
	check("diagnostics finds by system", #diagnostics:find({ system = "Beta" }) == 2)
	check("diagnostics finds by category with limit", #diagnostics:find({ category = "remote", limit = 1 }) == 1)

	local diagnosticReport = diagnostics:report({ recentLimit = 1 })
	check("diagnostic report counts records", diagnosticReport.total == 2 and diagnosticReport.dropped == 1)
	check("diagnostic report counts systems", diagnosticReport.counts.bySystem.Beta == 2)
	check("diagnostic report limits recent records", #diagnosticReport.recent == 1 and diagnosticReport.recent[1].name == "C")
	local formatted = diagnostics:formatReport({ recentLimit = 1 })
	local formattedLines = {}
	for line in string.gmatch(formatted, "[^\n]+") do
		table.insert(formattedLines, line)
	end
	check("diagnostic report header carries totals",
		formattedLines[1] == "diagnostics: total=2 dropped=1 failures=true")
	check("diagnostic report lists the recent entry",
		#formattedLines == 2 and formattedLines[2] == "[error] C system=Beta category=remote third")

	local subscriberDiagnostics = Contracts.diagnostics()
	local observed = {}
	local unsubscribe = subscriberDiagnostics:subscribe(function(entry)
		table.insert(observed, entry.name)
	end)
	subscriberDiagnostics:record({ name = "ObservedA" })
	unsubscribe()
	subscriberDiagnostics:record({ name = "ObservedB" })
	check("diagnostics subscribers receive records", #observed == 1 and observed[1] == "ObservedA")

	local replayed = {}
	subscriberDiagnostics:subscribe(function(entry)
		table.insert(replayed, entry.name)
	end, {
		replay = true,
	})()
	check("diagnostics subscribers can replay existing records", #replayed == 2)

	local invariantDiagnostics = Contracts.diagnostics()
	local invariantOk = Contracts.Invariant.check("AlwaysTrue", true, nil, invariantDiagnostics)
	local invariantBad = Contracts.Invariant.check("AlwaysFalse", false, "nope", invariantDiagnostics)
	check("invariant check passes true condition", invariantOk.ok == true)
	check("invariant check records false condition", invariantBad.ok == false and invariantDiagnostics:count() == 1)

	test:section("System")

	local weaponContract = Contracts.system("CombatService")
		:ownsTag("GeneratedWeaponTool")
		:ownsFolder("Workspace.CombatEffects")
		:mayRead("Player.Character")
		:mayWrite("Player.Backpack")
		:mustNeverTouch("Workspace.CurrentArena")
		:remote("WeaponAction", Contracts.object({
			Action = Contracts.oneOf({ "Fire", "Reload" }),
			WeaponId = Contracts.stringId(),
		}, {
			allowExtra = false,
		}))
		:postcondition("PlayerHasWeapon", function(context)
			return context.weaponCount == 1
		end)

	local description = weaponContract:describe()
	check("system records owned tag", description.ownership.tags[1] == "GeneratedWeaponTool")
	check("system records postcondition names", description.postconditions[1] == "PlayerHasWeapon")
	check(
		"system validates remote payload",
		weaponContract:validateRemote("WeaponAction", { Action = "Fire", WeaponId = "Rifle" }).ok == true
	)

	local systemDiagnostics = Contracts.diagnostics()
	local badRemote = weaponContract:validateRemote(
		"WeaponAction",
		{ Action = "Exploit", WeaponId = "Rifle" },
		systemDiagnostics
	)
	check("system rejects invalid remote payload", badRemote.ok == false)
	check("system records invalid remote payload", systemDiagnostics:last().name == "RemotePayloadInvalid")

	local touchDiagnostics = Contracts.diagnostics()
	local touchResult = weaponContract:checkTouch("cleanup", "Workspace.CurrentArena.Spawns", touchDiagnostics)
	check("system rejects forbidden touch", touchResult.ok == false)
	check("system records forbidden touch", touchDiagnostics:last().name == "ForbiddenTouch")

	local postconditionDiagnostics = Contracts.diagnostics()
	local postconditionsOk = weaponContract:checkPostconditions({ weaponCount = 1 }, postconditionDiagnostics)
	local postconditionsBad = weaponContract:checkPostconditions({ weaponCount = 0 }, postconditionDiagnostics)
	check("system accepts passing postconditions", postconditionsOk.ok == true)
	check("system records failing postconditions", postconditionsBad.ok == false and postconditionDiagnostics:last().name == "PlayerHasWeapon")

	test:section("RateLimiter")

	local time = 0
	local limiter = Contracts.RateLimiter.new({ maxRequests = 2, windowSeconds = 1 }, function()
		return time
	end)

	check("rate limiter accepts first request", limiter:check("player", "Deploy") == true)
	check("rate limiter accepts second request", limiter:check("player", "Deploy") == true)
	check("rate limiter rejects burst", limiter:check("player", "Deploy") == false)
	time = 1
	check("rate limiter resets after window", limiter:check("player", "Deploy") == true)

	local anonymousLimiter = Contracts.RateLimiter.new({ maxRequests = 1, windowSeconds = 1 }, function()
		return time
	end)
	check("rate limiter accepts nil key", anonymousLimiter:check(nil, "Deploy") == true)
	check("rate limiter limits repeated nil key", anonymousLimiter:check(nil, "Deploy") == false)

	return weaponContract
end
