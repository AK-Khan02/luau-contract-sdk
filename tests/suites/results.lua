--!strict

local Contracts = require("../../src/Contracts")
local Result = require("../../src/Core/Result")

return function(test: any)
	local function check(name: string, condition: any)
		test:check(name, condition)
	end

	test:section("Result")

	local success = Result.ok(42, {
		name = "Meaning",
	})
	check(
		"success constructor keeps value and metadata",
		success.ok == true and success.value == 42 and success.name == "Meaning"
	)

	local failure = Result.fail("ActionRejected", "not allowed", {
		code = "policy",
	})
	check(
		"failure constructor keeps taxonomy fields",
		failure.ok == false
			and failure.name == "ActionRejected"
			and failure.reason == "not allowed"
			and failure.code == "policy"
	)

	local diagnostics = Contracts.diagnostics()
	local context = {
		action = "Grant",
	}
	local diagnosticFailure = Result.failWithDiagnostic(diagnostics, {
		level = "error",
		category = "runtime",
		system = "InventoryService",
		name = "ActionMiddlewareError",
		message = "middleware boom",
		context = context,
	})
	check(
		"diagnostic failure records and returns the same taxonomy",
		diagnosticFailure.ok == false
			and diagnosticFailure.name == "ActionMiddlewareError"
			and diagnosticFailure.reason == "middleware boom"
			and diagnosticFailure.context == context
			and diagnostics:last().name == "ActionMiddlewareError"
	)

	local overrideContext = {
		request = "caller",
	}
	local overridden = Result.failWithDiagnostic(nil, {
		level = "error",
		category = "runtime",
		name = "LifecycleSessionMissing",
		message = "missing session",
		context = context,
	}, {
		context = overrideContext,
	})
	check("failure fields can override diagnostic context", overridden.context == overrideContext)
end
