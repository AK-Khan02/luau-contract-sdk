--!nocheck

local TestHarness = require("./TestHarness")

local suites = {
	{ name = "package_schema_lifecycle", run = require("./suites/package_schema_lifecycle") },
	{ name = "diagnostics_system", run = require("./suites/diagnostics_system") },
	{ name = "action_contracts", run = require("./suites/action_contracts") },
	{ name = "effect_plans", run = require("./suites/effect_plans") },
	{ name = "lifecycle_sessions", run = require("./suites/lifecycle_sessions") },
	{ name = "remote_policies_reports", run = require("./suites/remote_policies_reports") },
	{ name = "runtime", run = require("./suites/runtime") },
	{ name = "middleware", run = require("./suites/middleware") },
	{ name = "relay_publisher", run = require("./suites/relay_publisher") },
	{ name = "async_actions", run = require("./suites/async_actions") },
	{ name = "test_harness", run = require("./suites/test_harness") },
	{ name = "adapters_examples", run = require("./suites/adapters_examples") },
	{ name = "scanner_studio", run = require("./suites/scanner_studio") },
	{ name = "studio_bridge", run = require("./suites/studio_bridge") },
	{ name = "boundaries", run = require("./suites/boundaries") },
	{ name = "host_tools", run = require("./suites/host_tools") },
}

local filter = (...)
if filter ~= nil and filter ~= "" then
	local matching = {}
	for _, suite in ipairs(suites) do
		if string.find(suite.name, filter, 1, true) ~= nil then
			table.insert(matching, suite)
		end
	end
	if #matching == 0 then
		error("no test suites match filter: " .. tostring(filter), 0)
	end
	suites = matching
	print(("running %d suite(s) matching %q"):format(#suites, filter))
end

local test = TestHarness.new()

for _, suite in ipairs(suites) do
	test:suite(suite.name)
	local ok, err = pcall(suite.run, test)
	if not ok then
		test:suiteError(suite.name, err)
	end
end

test:summary()
