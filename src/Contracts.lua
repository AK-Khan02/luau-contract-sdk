--!strict

local AsyncGate = require("./Core/AsyncGate")
local Diagnostics = require("./Core/Diagnostics")
local DiagnosticReport = require("./Core/DiagnosticReport")
local DurableEffect = require("./Core/DurableEffect")
local DurableProfile = require("./Core/DurableProfile")
local DurableTransaction = require("./Core/DurableTransaction")
local EffectPlan = require("./Core/EffectPlan")
local Host = require("./Host")
local Invariant = require("./Core/Invariant")
local Lifecycle = require("./Core/Lifecycle")
local LifecycleSession = require("./Core/LifecycleSession")
local OverlayFeed = require("./Core/OverlayFeed")
local Package = require("./Package")
local RateLimiter = require("./Core/RateLimiter")
local Reconcile = require("./Core/Reconcile")
local Roblox = require("./Roblox")
local Runtime = require("./Core/Runtime")
local Schema = require("./Core/Schema")
local StaticScanner = require("./Core/StaticScanner")
local Studio = require("./Studio")
local System = require("./Core/System")
local Test = require("./Test")

local function freezeTable(value: any): any
	local freeze = table.freeze
	if freeze ~= nil then
		local freezeFn = freeze :: (any) -> any
		return freezeFn(value)
	end
	return value
end

local PUBLIC_API_STATUS = freezeTable({
	stable = "stable",
	experimental = "experimental",
	internal = "internal",
})

local Contracts = {
	AsyncGate = AsyncGate,
	Diagnostics = Diagnostics,
	DiagnosticReport = DiagnosticReport,
	DurableEffect = DurableEffect,
	DurableProfile = DurableProfile,
	DurableTransaction = DurableTransaction,
	EffectPlan = EffectPlan,
	Host = Host,
	Invariant = Invariant,
	Lifecycle = Lifecycle,
	LifecycleSession = LifecycleSession,
	OverlayFeed = OverlayFeed,
	Package = Package,
	RateLimiter = RateLimiter,
	Reconcile = Reconcile,
	Roblox = Roblox,
	Runtime = Runtime,
	Schema = Schema,
	StaticScanner = StaticScanner,
	Studio = Studio,
	System = System,
	Test = Test,
	version = Package.version,
}

function Contracts.diagnostics(config)
	return Diagnostics.new(config)
end

function Contracts.lifecycle(name)
	return Lifecycle.new(name)
end

function Contracts.lifecycleSession(systemContract, initialStates, options)
	return LifecycleSession.new(systemContract, initialStates, options)
end

function Contracts.loadProfile(store, key, options)
	return DurableProfile.load(store, key, options)
end

function Contracts.durableTransaction(store)
	return DurableTransaction.new(store)
end

function Contracts.runtime(systemContract, options)
	return Runtime.new(systemContract, options)
end

function Contracts.system(name)
	return System.new(name)
end

function Contracts.guardRemote(remote, options, handler)
	return Roblox.GuardRemote.connect(remote, options, handler)
end

function Contracts.publishDiagnostics(diagnostics, options)
	return Roblox.StudioBridgePublisher.publish(diagnostics, options)
end

function Contracts.cancelOnLeave(runtime, playersService)
	return Roblox.PlayerCancellation.cancelOnLeave(runtime, playersService)
end

function Contracts.publishRelay(diagnostics, options)
	return Roblox.RelayPublisher.publish(diagnostics, options)
end

Contracts.any = Schema.any
Contracts.arrayOf = Schema.arrayOf
Contracts.boolean = Schema.boolean
Contracts.custom = Schema.custom
Contracts.integer = Schema.integer
Contracts.literal = Schema.literal
Contracts.number = Schema.number
Contracts.object = Schema.object
Contracts.oneOf = Schema.oneOf
Contracts.optional = Schema.optional
Contracts.string = Schema.string
Contracts.stringId = Schema.stringId
Contracts.vector3 = Schema.vector3
Contracts.validate = Schema.validate

local STABLE_API_NAMES = freezeTable({
	"Public",
	"Experimental",
	"Internal",
	"publicApi",
	"diagnostics",
	"lifecycle",
	"lifecycleSession",
	"runtime",
	"system",
	"guardRemote",
	"cancelOnLeave",
	"publishDiagnostics",
	"publishRelay",
	"any",
	"arrayOf",
	"boolean",
	"custom",
	"integer",
	"literal",
	"number",
	"object",
	"oneOf",
	"optional",
	"string",
	"stringId",
	"vector3",
	"validate",
	"Schema",
	"Diagnostics",
	"DiagnosticReport",
	"Lifecycle",
	"LifecycleSession",
	"Runtime",
	"System",
	"version",
})

local EXPERIMENTAL_API_NAMES = freezeTable({
	"EffectPlan",
	"Host",
	"OverlayFeed",
	"Roblox",
	"StaticScanner",
	"Studio",
	"Test",
	"DurableEffect",
	"DurableProfile",
	"loadProfile",
	"DurableTransaction",
	"durableTransaction",
	"Reconcile",
})

local INTERNAL_API_NAMES = freezeTable({
	"AsyncGate",
	"Invariant",
	"Package",
	"RateLimiter",
})

Contracts.Public = freezeTable({
	diagnostics = Contracts.diagnostics,
	lifecycle = Contracts.lifecycle,
	lifecycleSession = Contracts.lifecycleSession,
	runtime = Contracts.runtime,
	system = Contracts.system,
	guardRemote = Contracts.guardRemote,
	cancelOnLeave = Contracts.cancelOnLeave,
	publishDiagnostics = Contracts.publishDiagnostics,
	publishRelay = Contracts.publishRelay,
	any = Contracts.any,
	arrayOf = Contracts.arrayOf,
	boolean = Contracts.boolean,
	custom = Contracts.custom,
	integer = Contracts.integer,
	literal = Contracts.literal,
	number = Contracts.number,
	object = Contracts.object,
	oneOf = Contracts.oneOf,
	optional = Contracts.optional,
	string = Contracts.string,
	stringId = Contracts.stringId,
	vector3 = Contracts.vector3,
	validate = Contracts.validate,
	Schema = Schema,
	Diagnostics = Diagnostics,
	DiagnosticReport = DiagnosticReport,
	Lifecycle = Lifecycle,
	LifecycleSession = LifecycleSession,
	Runtime = Runtime,
	System = System,
	version = Package.version,
})

Contracts.Experimental = freezeTable({
	EffectPlan = EffectPlan,
	Host = Host,
	OverlayFeed = OverlayFeed,
	Roblox = Roblox,
	StaticScanner = StaticScanner,
	Studio = Studio,
	Test = Test,
	DurableEffect = DurableEffect,
	DurableProfile = DurableProfile,
	loadProfile = Contracts.loadProfile,
	DurableTransaction = DurableTransaction,
	durableTransaction = Contracts.durableTransaction,
	Reconcile = Reconcile,
})

Contracts.Internal = freezeTable({
	AsyncGate = AsyncGate,
	Invariant = Invariant,
	Package = Package,
	RateLimiter = RateLimiter,
})

Contracts.publicApi = freezeTable({
	version = 1,
	status = PUBLIC_API_STATUS,
	stable = STABLE_API_NAMES,
	experimental = EXPERIMENTAL_API_NAMES,
	internal = INTERNAL_API_NAMES,
})

return Contracts
