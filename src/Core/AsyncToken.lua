--!strict

type CancelCallback = (unknown) -> ()

type TokenData = {
	_cancelled: boolean,
	_reason: unknown?,
	_callbacks: { CancelCallback },
}

local Token = {}
Token.__index = Token

export type Token = typeof(setmetatable({} :: TokenData, Token))

function Token.new(): Token
	local token: TokenData = {
		_cancelled = false,
		_reason = nil,
		_callbacks = {},
	}
	return setmetatable(token, Token)
end

function Token.isCancelled(self: Token): boolean
	return self._cancelled
end

function Token.reason(self: Token): unknown
	return self._reason
end

function Token.cancel(self: Token, reason: unknown?)
	if self._cancelled then
		return
	end
	self._cancelled = true
	self._reason = reason or "cancelled"

	local callbacks = self._callbacks
	self._callbacks = {}
	for _, callback in ipairs(callbacks) do
		pcall(callback, self._reason)
	end
end

function Token.onCancel(self: Token, callback: CancelCallback)
	if type(callback) ~= "function" then
		error("Token.onCancel expects a callback function", 2)
	end
	if self._cancelled then
		pcall(callback, self._reason)
		return
	end
	table.insert(self._callbacks, callback)
end

return Token
