local Ownership = {}

local OWNER_ATTRIBUTE = "ContractOwner"

local function record(diagnostics, fields)
	if diagnostics and diagnostics.record then
		return diagnostics:record(fields)
	end
	return fields
end

local function getFullName(instance)
	if instance and instance.GetFullName then
		local ok, name = pcall(function()
			return instance:GetFullName()
		end)
		if ok then
			return name
		end
	end
	return tostring(instance)
end

function Ownership.claim(systemName, instance, options)
	options = options or {}

	if not instance then
		error("Ownership.claim requires an instance", 2)
	end
	if not instance.SetAttribute then
		error("Ownership.claim expects a Roblox Instance-like value", 2)
	end

	instance:SetAttribute(options.ownerAttribute or OWNER_ATTRIBUTE, systemName)

	if options.collectionService and options.tag then
		options.collectionService:AddTag(instance, options.tag)
	end

	return instance
end

function Ownership.ownerOf(instance, ownerAttribute)
	if not instance or not instance.GetAttribute then
		return nil
	end
	return instance:GetAttribute(ownerAttribute or OWNER_ATTRIBUTE)
end

function Ownership.isOwnedBy(systemName, instance, ownerAttribute)
	return Ownership.ownerOf(instance, ownerAttribute) == systemName
end

function Ownership.assertOwned(systemName, instance, diagnostics, context)
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

function Ownership.destroyOwned(systemName, instance, diagnostics, context)
	if not Ownership.assertOwned(systemName, instance, diagnostics, context) then
		return false
	end
	if instance and instance.Destroy then
		instance:Destroy()
	end
	return true
end

return Ownership
