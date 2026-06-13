--!strict

local DiagnosticsBridge = require("../Studio/DiagnosticsBridge")
local PlayersService = require("./PlayersService")

local StudioBridgePublisher = {}

local DEFAULT_FOLDER_NAME = "__LuauContractDiagnostics"
local DEFAULT_MAX_BATCHES = 50
local DEFAULT_LEVEL = "warn"

local function defaultCreateInstance(className: string): any
	local ok, instance = pcall(function()
		return PlayersService.createInstance(className)
	end)
	if ok then
		return instance
	end
	error(
		"StudioBridgePublisher cannot create " .. tostring(className) .. " outside Roblox; pass options.createInstance",
		4
	)
end

local function isStudio(runService: any): boolean
	if runService == nil or type(runService.IsStudio) ~= "function" then
		return false
	end
	local isStudioFn = runService.IsStudio :: (any) -> any
	local ok, value = pcall(isStudioFn, runService)
	return ok and value == true
end

local function connectHeartbeat(runService: any, callback: () -> ()): any
	if runService == nil then
		return nil
	end
	local heartbeat = runService.Heartbeat
	if heartbeat == nil or type(heartbeat.Connect) ~= "function" then
		return nil
	end
	local connect = heartbeat.Connect :: (any, () -> ()) -> any
	return connect(heartbeat, callback) -- contracts-scan: ignore raw-remote-handler
end

local function disconnect(connection: any)
	if connection and type(connection.Disconnect) == "function" then
		local disconnectFn = connection.Disconnect :: (any) -> ()
		disconnectFn(connection)
	end
end

local function noopHandle(): any
	return {
		enabled = false,
		flush = function()
			return nil
		end,
		destroy = function() end,
	}
end

local function ensureFolder(parent: any, folderName: string, createInstance: (string) -> any): any
	local findFirstChild = parent.FindFirstChild :: (any, string) -> any
	local existing = findFirstChild(parent, folderName)
	if existing ~= nil then
		return existing
	end

	local folder = createInstance("Folder")
	folder.Name = folderName
	if type(folder.SetAttribute) == "function" then
		local setAttribute = folder.SetAttribute :: (any, string, any) -> ()
		setAttribute(folder, "wireVersion", DiagnosticsBridge.wireVersion())
	end
	folder.Parent = parent
	return folder
end

function StudioBridgePublisher.publish(diagnostics: any, options: any): any
	options = options or {}

	local runService = options.runService or PlayersService.resolveService("RunService")
	if not isStudio(runService) and options.force ~= true then
		return noopHandle()
	end

	local parent = options.parent or PlayersService.resolveService("ReplicatedStorage")
	if parent == nil or type(parent.FindFirstChild) ~= "function" then
		error("StudioBridgePublisher.publish needs a parent container (ReplicatedStorage)", 2)
	end

	local createInstance: (string) -> any = defaultCreateInstance
	if type(options.createInstance) == "function" then
		createInstance = options.createInstance :: (string) -> any
	end
	local folderName: string = if type(options.folderName) == "string" then options.folderName else DEFAULT_FOLDER_NAME
	local folder = ensureFolder(parent, folderName, createInstance)
	local maxBatches: number = if type(options.maxBatches) == "number" then options.maxBatches else DEFAULT_MAX_BATCHES
	local published: { any } = {}

	local function writeBatch(batch: any, encoded: string)
		local value = createInstance("StringValue")
		value.Name = tostring(batch.seq)
		value.Value = encoded
		value.Parent = folder

		table.insert(published, value)
		while #published > maxBatches do
			local oldest = table.remove(published, 1)
			if oldest ~= nil and type(oldest.Destroy) == "function" then
				local destroy = oldest.Destroy :: (any) -> ()
				destroy(oldest) -- contracts-scan: ignore unowned-destroy
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

	function handle.flush(): any
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
