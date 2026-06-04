local ok, Contracts = pcall(require, "./Contracts")
if ok then
	return Contracts
end

return require("./src/Contracts")
