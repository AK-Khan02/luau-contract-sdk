--!strict

local Result = require("../Core/Result")

local Ownership = {}

local OWNER_ATTRIBUTE = "ContractOwner"

local record = Result.record

local function getFullName(instance: any): string
	if instance and type(instance.GetFullName) == "function" then
		local getFullNameFn = instance.GetFullName :: (any) -> any
		local ok, name = pcall(function()
			return getFullNameFn(instance)
		end)
		if ok then
			return name
		end
	end
	return tostring(instance)
end

function Ownership.claim(systemName: string, instance: any, options: any?): any
	options = options or {}

	if not instance then
		error("Ownership.claim requires an instance", 2)
	end
	if type(instance.SetAttribute) ~= "function" then
		error("Ownership.claim expects a Roblox Instance-like value", 2)
	end

	local setAttribute = instance.SetAttribute :: (any, string, any) -> ()
	setAttribute(instance, options.ownerAttribute or OWNER_ATTRIBUTE, systemName)

	if options.collectionService and options.tag then
		local collectionService: any = options.collectionService
		local addTag = collectionService.AddTag :: (any, any, string) -> ()
		addTag(collectionService, instance, tostring(options.tag))
	end

	return instance
end

function Ownership.ownerOf(instance: any, ownerAttribute: string?): any
	if not instance or type(instance.GetAttribute) ~= "function" then
		return nil
	end
	local getAttribute = instance.GetAttribute :: (any, string) -> any
	return getAttribute(instance, ownerAttribute or OWNER_ATTRIBUTE)
end

function Ownership.isOwnedBy(systemName: string, instance: any, ownerAttribute: string?): boolean
	return Ownership.ownerOf(instance, ownerAttribute) == systemName
end

function Ownership.assertOwned(systemName: string, instance: any, diagnostics: any?, context: any?): boolean
	local owner = Ownership.ownerOf(instance)
	if owner == systemName then
		return true
	end

	record(diagnostics, {
		level = "error",
		category = "ownership",
		system = systemName,
		name = "UnownedObjectTouch",
		message = systemName .. " touched object owned by " .. tostring(owner),
		context = context or {
			object = getFullName(instance),
			owner = owner,
		},
	})

	return false
end

function Ownership.destroyOwned(systemName: string, instance: any, diagnostics: any?, context: any?): boolean
	if not Ownership.assertOwned(systemName, instance, diagnostics, context) then
		return false
	end
	if instance and type(instance.Destroy) == "function" then
		local destroy = instance.Destroy :: (any) -> ()
		destroy(instance)
	end
	return true
end

return Ownership
