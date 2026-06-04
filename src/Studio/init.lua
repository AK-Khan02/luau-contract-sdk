local function load(primaryPath, fallbackPath)
	local ok, module = pcall(require, primaryPath)
	if ok then
		return module
	end
	return require(fallbackPath)
end

return {
	StudioReport = load("./StudioReport", "./Studio/StudioReport"),
}
