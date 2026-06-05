--!nocheck

local TestHarness = require("./TestHarness")

local suites = {
	require("./suites/package_schema_lifecycle"),
	require("./suites/diagnostics_system"),
	require("./suites/action_contracts"),
	require("./suites/effect_plans"),
	require("./suites/lifecycle_sessions"),
	require("./suites/remote_policies_reports"),
	require("./suites/runtime"),
	require("./suites/adapters_examples"),
	require("./suites/scanner_studio"),
}

local test = TestHarness.new()

for _, runSuite in ipairs(suites) do
	runSuite(test)
end

test:summary()
