-- Widgets-only build: fills in the unit/weapon def values that these widgets read but official
-- releases don't define (see Configs/widgets_only_defs.lua, generated from the source branch).
--
-- Include it before reading UnitDefs/WeaponDefs customParams:
--   VFS.Include(LUAUI_DIRNAME .. "Widgets/Include/widgets_only_defs.lua", nil, VFS.RAW_FIRST)
-- It runs once per LuaUI session; later includes are no-ops. Then use WG.WidgetsOnlyIconType(ud)
-- instead of ud.iconType, since iconType itself can't be overridden from LuaUI.

if WG.widgetsOnlyDefs then
	return WG.widgetsOnlyDefs
end

local defs = VFS.Include(LUAUI_DIRNAME .. "Configs/widgets_only_defs.lua", nil, VFS.RAW_FIRST)
local iconTypes = VFS.Include(LUAUI_DIRNAME .. "Configs/icontypes.lua", nil, VFS.RAW_FIRST)

local function SetParam(def, key, value)
	-- Only fill in; never override a value an official release has since added.
	local ok, err = pcall(function()
		if def.customParams[key] == nil then
			def.customParams[key] = value
		end
	end)
	if not ok then
		Spring.Echo("Widgets-only defs: could not set customParams." .. key .. " (" .. tostring(err) .. ")")
	end
	return ok
end

local iconTypeByUnitDefID = {}
local registeredIcons = {}

for name, params in pairs(defs.units) do
	local ud = UnitDefNames[name]
	if ud then
		for key, value in pairs(params) do
			if key == "iconType" then
				local iconDef = iconTypes[value]
				if iconDef then
					if not registeredIcons[value] then
						registeredIcons[value] = Spring.AddUnitIcon(value, iconDef.bitmap, iconDef.size)
					end
					if registeredIcons[value] then
						Spring.SetUnitDefIcon(ud.id, value)
						iconTypeByUnitDefID[ud.id] = value
					end
				end
			else
				SetParam(ud, key, value)
			end
		end
	end
end

for _, wd in pairs(WeaponDefs) do
	local icon = defs.weaponIcons[wd.name]
	-- Modular commander weapons are generated per commander; idstring names the base weapon.
	if not icon and wd.customParams.idstring then
		icon = defs.commWeaponIcons[wd.customParams.idstring]
	end
	if icon then
		SetParam(wd, "icon", icon)
	end
end

function WG.WidgetsOnlyIconType(ud)
	return ud and (iconTypeByUnitDefID[ud.id] or ud.iconType)
end

WG.widgetsOnlyDefs = defs
return defs
