--!nocheck

local Contracts = require("../../src/Contracts")
local PackageRoot = require("../../src")
local RemoteGuard = require("../../src/Roblox/RemoteGuard")

return function(test)
	local function check(name, condition)
		test:check(name, condition)
	end

	test:section("Package")

	check("package root exports contracts api", PackageRoot.system == Contracts.system)
	check("package exposes version", PackageRoot.version == "0.6.0")
	check("package metadata is present", PackageRoot.Package.name == "luau-contract-sdk")
	check("package root exports Roblox adapters", PackageRoot.Roblox.RemoteGuard == RemoteGuard)
	check("package root exports overlay feed", PackageRoot.OverlayFeed == Contracts.OverlayFeed)
	check("package root exports static scanner", PackageRoot.StaticScanner == Contracts.StaticScanner)
	check("package root exports studio report", PackageRoot.Studio.StudioReport == Contracts.Studio.StudioReport)

	test:section("Schema")

	check("string id accepts simple ids", Contracts.validate(Contracts.stringId(), "Rifle_1").ok == true)
	check("string id rejects path traversal", Contracts.validate(Contracts.stringId(), "../Rifle").ok == false)
	check("integer enforces range", Contracts.validate(Contracts.integer(1, 3), 2).ok == true)
	check("integer rejects out of range", Contracts.validate(Contracts.integer(1, 3), 4).ok == false)
	check("oneOf accepts allowed value", Contracts.validate(Contracts.oneOf({ "solo", "coop" }), "solo").ok == true)
	check("oneOf rejects unknown value", Contracts.validate(Contracts.oneOf({ "solo", "coop" }), "admin").ok == false)

	local deploySchema = Contracts.object({
		Mode = Contracts.oneOf({ "solo", "coop", "tdm" }),
		MapName = Contracts.optional(Contracts.string({ maxLength = 12 })),
		NewRun = Contracts.optional(Contracts.boolean()),
	}, {
		allowExtra = false,
	})

	check("object accepts optional field", Contracts.validate(deploySchema, { Mode = "solo", NewRun = true }).ok == true)
	check("object rejects missing required field", Contracts.validate(deploySchema, { NewRun = true }).ok == false)
	check("object rejects extra field by default", Contracts.validate(deploySchema, { Mode = "solo", Admin = true }).ok == false)
	check("vector3 accepts table vector", Contracts.validate(Contracts.vector3(), { X = 0, Y = 1, Z = 0 }).ok == true)
	check(
		"unitish vector rejects large direction",
		Contracts.validate(Contracts.vector3({ unitish = true }), { X = 0, Y = 20, Z = 0, Magnitude = 20 }).ok == false
	)

	test:section("Lifecycle")

	local lifecycle = Contracts.lifecycle("Player")
		:transition("Menu", "Deploy", "DeployRequested")
		:transition("DeployRequested", "SpawnStarted", "Spawning")
		:transition("Spawning", "Spawned", "Alive")

	local nextState, didTransition = lifecycle:reduce("DeployRequested", "SpawnStarted")
	check("lifecycle reduces valid transition", didTransition == true and nextState == "Spawning")

	local sameState, invalidTransition = lifecycle:reduce("Alive", "Spawned")
	check("lifecycle preserves invalid transition state", invalidTransition == false and sameState == "Alive")

	local validState = lifecycle:validateState("Alive")
	local invalidState = lifecycle:validateState("Ghost")
	check("lifecycle validates known state", validState == true)
	check("lifecycle rejects unknown state", invalidState == false)
	check("lifecycle describes states", #lifecycle:describe().states == 4)
end
