--!strict

export type Line = {
	raw: string,
	code: string,
}

local StaticScannerSource = {}

local function stripQuoted(source: string, quote: string, index: number): number
	index += 1
	while index <= #source do
		local char = string.sub(source, index, index)
		if char == "\\" then
			index += 2
		elseif char == quote then
			return index + 1
		else
			index += 1
		end
	end
	return index
end

function StaticScannerSource.codeView(line: string): string
	local output = table.create(#line, " ")
	local index = 1

	while index <= #line do
		local char = string.sub(line, index, index)
		local nextChar = string.sub(line, index + 1, index + 1)
		if char == "-" and nextChar == "-" then
			break
		end
		if char == "'" or char == '"' then
			local nextIndex = stripQuoted(line, char, index)
			output[index] = char
			output[nextIndex - 1] = char
			index = nextIndex
		else
			output[index] = char
			index += 1
		end
	end

	return table.concat(output, "")
end

function StaticScannerSource.splitLines(source: string?): { Line }
	local lines = {}
	source = source or ""

	for raw in string.gmatch(source .. "\n", "([^\n]*)\n") do
		table.insert(lines, {
			raw = raw,
			code = StaticScannerSource.codeView(raw),
		})
	end

	return lines
end

function StaticScannerSource.trim(value: string?): string
	return string.match(value or "", "^%s*(.-)%s*$") or ""
end

function StaticScannerSource.isCommentOnly(line: string): boolean
	return string.match(line, "^%s*%-%-") ~= nil
end

function StaticScannerSource.hasInlineAllow(line: string, ruleId: string): boolean
	local marker = "contracts%-scan:%s*ignore"
	if string.find(line, marker) == nil then
		return false
	end
	return string.find(line, ruleId, 1, true) ~= nil or string.find(line, "next", 1, true) ~= nil
end

function StaticScannerSource.contextHasAllow(
	lines: { Line },
	startIndex: number,
	endIndex: number,
	ruleId: string
): boolean
	local first = math.max(1, startIndex)
	local last = math.min(#lines, endIndex)

	for index = first, last do
		if StaticScannerSource.hasInlineAllow(lines[index].raw, ruleId) then
			return true
		end
	end

	return false
end

function StaticScannerSource.contextContains(
	lines: { Line },
	startIndex: number,
	endIndex: number,
	pattern: string
): boolean
	local first = math.max(1, startIndex)
	local last = math.min(#lines, endIndex)

	for index = first, last do
		if string.find(lines[index].code, pattern) then
			return true
		end
	end

	return false
end

function StaticScannerSource.contextContainsText(
	lines: { Line },
	startIndex: number,
	endIndex: number,
	text: string
): boolean
	local first = math.max(1, startIndex)
	local last = math.min(#lines, endIndex)

	for index = first, last do
		if string.find(lines[index].code, text, 1, true) then
			return true
		end
	end

	return false
end

return StaticScannerSource
