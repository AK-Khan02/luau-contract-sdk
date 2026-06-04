local Diagnostics = require("./Core/Diagnostics")
local DiagnosticReport = require("./Core/DiagnosticReport")
local Invariant = require("./Core/Invariant")
local Lifecycle = require("./Core/Lifecycle")
local OverlayFeed = require("./Core/OverlayFeed")
local Package = require("./Package")
local RateLimiter = require("./Core/RateLimiter")
local Roblox = require("./Roblox")
local Schema = require("./Core/Schema")
local StaticScanner = require("./Core/StaticScanner")
local Studio = require("./Studio")
local System = require("./Core/System")

local Contracts = {
	Diagnostics = Diagnostics,
	DiagnosticReport = DiagnosticReport,
	Invariant = Invariant,
	Lifecycle = Lifecycle,
	OverlayFeed = OverlayFeed,
	Package = Package,
	RateLimiter = RateLimiter,
	Roblox = Roblox,
	Schema = Schema,
	StaticScanner = StaticScanner,
	Studio = Studio,
	System = System,
	version = Package.version,
}

function Contracts.diagnostics(config)
	return Diagnostics.new(config)
end

function Contracts.lifecycle(name)
	return Lifecycle.new(name)
end

function Contracts.system(name)
	return System.new(name)
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

return Contracts
