--!strict

local okJsonEncode, JsonEncode = pcall(require, "./JsonEncode")
if not okJsonEncode then
	JsonEncode = require("./Host/JsonEncode")
end

local okReportPolicy, ReportPolicy = pcall(require, "./ReportPolicy")
if not okReportPolicy then
	ReportPolicy = require("./Host/ReportPolicy")
end

local okScanRunner, ScanRunner = pcall(require, "./ScanRunner")
if not okScanRunner then
	ScanRunner = require("./Host/ScanRunner")
end

return {
	JsonEncode = JsonEncode,
	ReportPolicy = ReportPolicy,
	ScanRunner = ScanRunner,
}
