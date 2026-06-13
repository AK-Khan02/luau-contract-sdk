--!nonstrict

local Contracts = require("../../src/Contracts")
local DiagnosticsBridge = require("../../src/Studio/DiagnosticsBridge")
local StudioBridgePublisher = require("../../src/Roblox/StudioBridgePublisher")
local TaskScheduler = require("../../src/Roblox/TaskScheduler")
local PluginModel = require("../../plugin/LuauContractPluginModel")

local function manualClock(start)
	local state = {
		now = start or 0,
	}
	function state.clock()
		return state.now
	end
	return state
end

local function fakeValue(className)
	local value = {
		ClassName = className,
		Name = "",
		Value = "",
		Parent = nil,
		_attributes = {},
		_destroyed = false,
	}
	function value:SetAttribute(key, attributeValue)
		self._attributes[key] = attributeValue
	end
	function value:Destroy()
		self._destroyed = true
	end
	return value
end

local function fakeContainer()
	local container = {
		_children = {},
	}
	function container:FindFirstChild(name)
		for _, child in ipairs(self._children) do
			if child.Name == name then
				return child
			end
		end
		return nil
	end
	return container
end

local function fakeRunService(studio)
	local service = {
		_heartbeat = nil,
	}
	function service:IsStudio()
		return studio
	end
	service.Heartbeat = {
		Connect = function(_, callback)
			service._heartbeat = callback
			return {
				Disconnect = function()
					service._heartbeat = nil
				end,
			}
		end,
	}
	return service
end

return function(test)
	local function check(name, condition)
		test:check(name, condition)
	end

	test:section("DiagnosticsBridge")

	local clock = manualClock(10)
	local diagnostics = Contracts.diagnostics({
		clock = clock.clock,
	})
	local batches = {}
	local encodedBatches = {}
	local bridge = DiagnosticsBridge.new(diagnostics, {
		level = "warn",
		maxBatchEntries = 3,
		flushIntervalSeconds = 0.25,
		clock = clock.clock,
		onBatch = function(batch, encoded)
			table.insert(batches, batch)
			table.insert(encodedBatches, encoded)
		end,
	})

	diagnostics:record({
		level = "info",
		name = "Ignored",
		message = "below level filter",
	})
	check("bridge filters entries below level", bridge:pendingCount() == 0)

	diagnostics:record({
		level = "error",
		category = "remote",
		system = "InventoryService",
		name = "RemoteRateLimited",
		message = "remote rate limit exceeded",
		context = {
			player = {
				UserId = 1234,
				Name = "Rica",
				Character = {
					deep = {
						deeper = {
							deepest = true,
						},
					},
				},
			},
			callback = function() end,
		},
	})
	check("bridge holds pending entries before flush", bridge:pendingCount() == 1)

	local batch = bridge:flush()
	check("flush returns a versioned batch", batch ~= nil and batch.v == 1 and batch.seq == 1)
	check("flush empties pending", bridge:pendingCount() == 0)
	check("flush invokes onBatch", #batches == 1 and batches[1].seq == 1)

	local entry = batch.entries[1]
	check(
		"entry keeps diagnostic fields",
		entry.name == "RemoteRateLimited" and entry.level == "error" and entry.system == "InventoryService"
	)
	check(
		"player-like context is redacted",
		entry.context.player.userId == 1234 and entry.context.player.name == "Rica"
	)
	check("player redaction drops other fields", entry.context.player.Character == nil)
	check("functions in context become strings", type(entry.context.callback) == "string")

	local deepDiagnostics = Contracts.diagnostics({
		clock = clock.clock,
	})
	local deepBridge = DiagnosticsBridge.new(deepDiagnostics, {
		maxContextDepth = 2,
		clock = clock.clock,
	})
	deepDiagnostics:record({
		level = "error",
		name = "Deep",
		context = {
			a = {
				b = {
					c = true,
				},
			},
		},
	})
	local deepBatch = deepBridge:flush()
	check("deep contexts are depth-capped", deepBatch.entries[1].context.a.b == "<table>")
	deepBridge:destroy()

	check("encoded batch is JSON", string.find(encodedBatches[1], '"RemoteRateLimited"', 1, true) ~= nil)
	check("encoded batch carries wire version", string.find(encodedBatches[1], '"v":1', 1, true) ~= nil)

	diagnostics:record({ level = "warn", name = "A" })
	diagnostics:record({ level = "warn", name = "B" })
	check("bridge does not flush below batch size", #batches == 1)
	diagnostics:record({ level = "warn", name = "C" })
	check("bridge flushes when batch is full", #batches == 2 and #batches[2].entries == 3)
	check("seq increments per batch", batches[2].seq == 2)

	diagnostics:record({ level = "warn", name = "D" })
	check("step respects flush interval", bridge:step(clock.now) == nil and bridge:pendingCount() == 1)
	clock.now += 0.3
	local stepped = bridge:step(clock.now)
	check("step flushes after interval elapses", stepped ~= nil and #batches == 3)

	bridge:destroy()
	diagnostics:record({ level = "error", name = "AfterDestroy" })
	check("destroyed bridge ignores new entries", bridge:pendingCount() == 0 and #batches == 3)

	local replayDiagnostics = Contracts.diagnostics({
		clock = clock.clock,
	})
	replayDiagnostics:record({ level = "error", name = "Early" })
	local replayBridge = DiagnosticsBridge.new(replayDiagnostics, {
		clock = clock.clock,
	})
	check("bridge replays buffered entries by default", replayBridge:pendingCount() == 1)
	replayBridge:destroy()

	test:section("StudioBridgePublisher")

	local publisherClock = manualClock(0)
	local publisherDiagnostics = Contracts.diagnostics({
		clock = publisherClock.clock,
	})
	local container = fakeContainer()
	local runService = fakeRunService(true)
	local created = {}

	local handle = StudioBridgePublisher.publish(publisherDiagnostics, {
		runService = runService,
		parent = container,
		clock = publisherClock.clock,
		maxBatches = 2,
		createInstance = function(className)
			local instance = fakeValue(className)
			table.insert(created, instance)
			return instance
		end,
	})

	check("publisher is enabled in studio", handle.enabled == true)
	check(
		"publisher creates the diagnostics folder",
		created[1] ~= nil and created[1].ClassName == "Folder" and created[1].Name == "__LuauContractDiagnostics"
	)
	check("folder records wire version", created[1]._attributes.wireVersion == 1)
	check("publisher connects heartbeat", runService._heartbeat ~= nil)

	publisherDiagnostics:record({ level = "error", name = "First" })
	handle.flush()
	publisherDiagnostics:record({ level = "error", name = "Second" })
	handle.flush()
	publisherDiagnostics:record({ level = "error", name = "Third" })
	handle.flush()

	local stringValues = {}
	for _, instance in ipairs(created) do
		if instance.ClassName == "StringValue" then
			table.insert(stringValues, instance)
		end
	end
	check("publisher writes one StringValue per batch", #stringValues == 3)
	check("publisher names batches by seq", stringValues[1].Name == "1" and stringValues[3].Name == "3")
	check(
		"publisher trims oldest beyond cap",
		stringValues[1]._destroyed == true and stringValues[2]._destroyed == false
	)
	check("batch values parent to the folder", stringValues[3].Parent == created[1])
	check("batch values hold encoded JSON", string.find(stringValues[3].Value, '"Third"', 1, true) ~= nil)

	publisherDiagnostics:record({ level = "info", name = "BelowDefault" })
	handle.flush()
	local afterInfo = 0
	for _, instance in ipairs(created) do
		if instance.ClassName == "StringValue" then
			afterInfo += 1
		end
	end
	check("publisher defaults to warn level", afterInfo == 3)

	publisherDiagnostics:record({ level = "error", name = "ViaHeartbeat" })
	publisherClock.now += 1
	runService._heartbeat()
	local afterHeartbeat = 0
	for _, instance in ipairs(created) do
		if instance.ClassName == "StringValue" then
			afterHeartbeat += 1
		end
	end
	check("heartbeat steps the bridge", afterHeartbeat == 4)

	handle.destroy()
	check("destroy disconnects heartbeat", runService._heartbeat == nil)

	local disabledHandle = StudioBridgePublisher.publish(publisherDiagnostics, {
		runService = fakeRunService(false),
		parent = fakeContainer(),
		createInstance = fakeValue,
	})
	check("publisher no-ops outside studio", disabledHandle.enabled == false and disabledHandle.flush() == nil)

	local forcedHandle = StudioBridgePublisher.publish(publisherDiagnostics, {
		runService = fakeRunService(false),
		parent = fakeContainer(),
		createInstance = fakeValue,
		force = true,
	})
	check("force overrides the studio gate", forcedHandle.enabled == true)
	forcedHandle.destroy()

	test:section("PluginModel live rows")

	check("batchFromDecoded rejects non-tables", PluginModel.batchFromDecoded("nope") == nil)
	check("batchFromDecoded rejects wrong versions", PluginModel.batchFromDecoded({ v = 99, entries = {} }) == nil)
	check("batchFromDecoded rejects missing entries", PluginModel.batchFromDecoded({ v = 1 }) == nil)

	local liveBatch = PluginModel.batchFromDecoded({
		v = 1,
		seq = 7,
		entries = {
			{ level = "error", system = "InventoryService", name = "RemoteRateLimited", message = "too fast" },
			{ level = "warn", name = "LifecycleRevisionStale" },
			{ level = "info", name = "Note" },
		},
	})
	check("batchFromDecoded accepts v1 batches", liveBatch ~= nil and liveBatch.seq == 7)

	local rows = PluginModel.liveRows(liveBatch)
	check("liveRows maps every entry", #rows == 3)
	check("liveRows maps tones", rows[1].tone == "error" and rows[2].tone == "warn" and rows[3].tone == "text")
	check("liveRows formats entries", rows[1].text == "[error] InventoryService RemoteRateLimited: too fast")
	check("liveRows formats entries without messages", rows[2].text == "[warn] LifecycleRevisionStale")

	local accumulated = {}
	PluginModel.appendLive(accumulated, rows, 2)
	check("appendLive trims to max rows", #accumulated == 2 and accumulated[2].text == rows[3].text)
	test:section("TaskScheduler resolution")

	test:expect("default returns nil outside Roblox", TaskScheduler.default(), nil)
	test:expect("from rejects nil libraries", TaskScheduler.from(nil), nil)
	test:expect(
		"from rejects partial libraries missing delay",
		TaskScheduler.from({
			spawn = function() end,
		}),
		nil
	)
	test:expect(
		"from rejects partial libraries missing spawn",
		TaskScheduler.from({
			delay = function() end,
		}),
		nil
	)

	local spawned = {}
	local delayed = {}
	local cancelled = {}
	local fakeTask = {
		spawn = function(fn)
			table.insert(spawned, fn)
			return fn
		end,
		delay = function(seconds, callback)
			local thread = { seconds = seconds, callback = callback }
			table.insert(delayed, thread)
			return thread
		end,
		cancel = function(thread)
			table.insert(cancelled, thread)
		end,
	}

	local taskScheduler = TaskScheduler.from(fakeTask)
	check(
		"from wraps a complete task library",
		taskScheduler ~= nil
			and type(taskScheduler.spawn) == "function"
			and type(taskScheduler.delay) == "function"
			and type(taskScheduler.clock) == "function"
	)

	taskScheduler.spawn(function() end)
	test:expect("scheduler spawn delegates to task.spawn", #spawned, 1)

	local cancelDelay = taskScheduler.delay(2, function() end)
	test:expect("scheduler delay delegates to task.delay", delayed[1].seconds, 2)
	cancelDelay()
	test:expect("delay cancellation calls task.cancel", cancelled[1], delayed[1])

	local noCancelScheduler = TaskScheduler.from({
		spawn = fakeTask.spawn,
		delay = fakeTask.delay,
	})
	local okWithoutCancel = pcall(noCancelScheduler.delay(1, function() end))
	check("missing task.cancel is tolerated", okWithoutCancel == true)

	test:section("StudioBridgePublisher edges")

	local edgeDiagnostics = Contracts.diagnostics()

	test:expectError("forced publish without a parent errors clearly", "needs a parent container", function()
		StudioBridgePublisher.publish(edgeDiagnostics, {
			runService = fakeRunService(false),
			force = true,
		})
	end)

	test:expectError("publishing outside Roblox without a factory errors clearly", "options.createInstance", function()
		StudioBridgePublisher.publish(edgeDiagnostics, {
			runService = fakeRunService(true),
			parent = fakeContainer(),
		})
	end)

	local reuseContainer = fakeContainer()
	local reuseCreated = {}
	local function reuseFactory(className)
		local instance = fakeValue(className)
		table.insert(reuseCreated, instance)
		return instance
	end

	local firstHandle = StudioBridgePublisher.publish(edgeDiagnostics, {
		runService = fakeRunService(true),
		parent = reuseContainer,
		createInstance = reuseFactory,
	})
	table.insert(reuseContainer._children, firstHandle.folder)
	local secondHandle = StudioBridgePublisher.publish(edgeDiagnostics, {
		runService = fakeRunService(true),
		parent = reuseContainer,
		createInstance = reuseFactory,
	})
	check("second publish reuses the existing folder", secondHandle.folder == firstHandle.folder)
	local folderCount = 0
	for _, instance in ipairs(reuseCreated) do
		if instance.ClassName == "Folder" then
			folderCount += 1
		end
	end
	test:expect("only one diagnostics folder is created", folderCount, 1)
	firstHandle.destroy()
	secondHandle.destroy()

	test:section("PluginModel malformed batches")

	local mixedRows = PluginModel.liveRows({
		v = 1,
		seq = 1,
		entries = {
			{ level = "error", name = "Real" },
			42,
			"junk",
			{ level = "warn", name = "AlsoReal" },
		},
	})
	test:expect("liveRows skips non-table entries", #mixedRows, 2)
	check("liveRows keeps the valid entries", mixedRows[1].tone == "error" and mixedRows[2].tone == "warn")
	test:expect("liveRows of nil batch is empty", #PluginModel.liveRows(nil), 0)
	test:expect("formatLiveEntry tolerates empty entries", PluginModel.formatLiveEntry({}), "[info] Diagnostic")
end
