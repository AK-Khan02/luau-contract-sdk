local function load(primaryPath, fallbackPath)
	local ok, module = pcall(require, primaryPath)
	if ok then
		return module
	end
	return require(fallbackPath)
end

return {
	Ownership = load("./Ownership", "./Roblox/Ownership"),
	OverlayState = load("./OverlayState", "./Roblox/OverlayState"),
	PostconditionRunner = load("./PostconditionRunner", "./Roblox/PostconditionRunner"),
	RemoteGuard = load("./RemoteGuard", "./Roblox/RemoteGuard"),
}
