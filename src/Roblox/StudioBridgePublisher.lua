--!nocheck
--!nolint UnknownGlobal

local DiagnosticsBridge = require("../Studio/DiagnosticsBridge")

local StudioBridgePublisher = {}

local DEFAULT_FOLDER_NAME = "__LuauContractDiagnostics"
local DEFAULT_MAX_BATCHES = 50
local DEFAULT_LEVEL = "warn"

local function resolveService(name)
	local ok, service = pcall(function()
		return game:GetService(name)
	end)
	if ok then
		return service
	end
	return nil
end

local function defaultCreateInstance(className)
	local ok, instance = pcall(function()
		return Instance.new(className)
	end)
	if ok then
		return instance
	end
	error("StudioBridgePublisher cannot create " .. tostring(className) .. " outside Roblox; pass options.createInstance", 4)
end

local function isStudio(runService)
	if runService == nil or type(runService.IsStudio) ~= "function" then
		return false
	end
	local ok, value = pcall(function()
		return runService:IsStudio()
	end)
	return ok and value == true
end

local function connectHeartbeat(runService, callback)
	if runService == nil then
		return nil
	end
	local heartbeat = runService.Heartbeat
	if heartbeat == nil or type(heartbeat.Connect) ~= "function" then
		return nil
	end
	return heartbeat:Connect(callback) -- contracts-scan: ignore raw-remote-handler
end

local function disconnect(connection)
	if connection and type(connection.Disconnect) == "function" then
		connection:Disconnect()
	end
end

local function noopHandle()
	return {
		enabled = false,
		flush = function()
			return nil
		end,
		destroy = function() end,
	}
end

local function ensureFolder(parent, folderName, createInstance)
	local existing = parent:FindFirstChild(folderName)
	if existing ~= nil then
		return existing
	end

	local folder = createInstance("Folder")
	folder.Name = folderName
	if type(folder.SetAttribute) == "function" then
		folder:SetAttribute("wireVersion", DiagnosticsBridge.wireVersion())
	end
	folder.Parent = parent
	return folder
end

function StudioBridgePublisher.publish(diagnostics, options)
	options = options or {}

	local runService = options.runService or resolveService("RunService")
	if not isStudio(runService) and options.force ~= true then
		return noopHandle()
	end

	local parent = options.parent or resolveService("ReplicatedStorage")
	if parent == nil or type(parent.FindFirstChild) ~= "function" then
		error("StudioBridgePublisher.publish needs a parent container (ReplicatedStorage)", 2)
	end

	local createInstance = options.createInstance or defaultCreateInstance
	local folder = ensureFolder(parent, options.folderName or DEFAULT_FOLDER_NAME, createInstance)
	local maxBatches = options.maxBatches or DEFAULT_MAX_BATCHES
	local published = {}

	local function writeBatch(batch, encoded)
		local value = createInstance("StringValue")
		value.Name = tostring(batch.seq)
		value.Value = encoded
		value.Parent = folder

		table.insert(published, value)
		while #published > maxBatches do
			local oldest = table.remove(published, 1)
			if oldest ~= nil and type(oldest.Destroy) == "function" then
				oldest:Destroy() -- contracts-scan: ignore unowned-destroy
			end
		end
	end

	local bridge = DiagnosticsBridge.new(diagnostics, {
		level = options.level or DEFAULT_LEVEL,
		replay = options.replay,
		maxBatchEntries = options.maxBatchEntries,
		flushIntervalSeconds = options.flushIntervalSeconds,
		maxContextDepth = options.maxContextDepth,
		clock = options.clock,
		onBatch = writeBatch,
	})

	local connection = connectHeartbeat(runService, function()
		bridge:step()
	end)

	local handle = {
		enabled = true,
		folder = folder,
		bridge = bridge,
	}

	function handle.flush()
		return bridge:flush()
	end

	function handle.destroy()
		bridge:flush()
		bridge:destroy()
		disconnect(connection)
	end

	return handle
end

return StudioBridgePublisher
