--!nonstrict

local function load(primaryPath, fallbackPath)
	local ok, module = pcall(require, primaryPath)
	if ok then
		return module
	end
	return require(fallbackPath)
end

return {
	DiagnosticsBridge = load("./DiagnosticsBridge", "./Studio/DiagnosticsBridge"),
	StudioReport = load("./StudioReport", "./Studio/StudioReport"),
}
