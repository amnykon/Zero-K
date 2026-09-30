-- Widgets-only build: command IDs the source branch added to LuaRules/Configs/customcmds.lua.
-- Official releases don't have them, so this registers them in Spring.Utilities.CMD and, like
-- customcmds.h.lua, sets CMD_<NAME> in the including file's environment.
--   VFS.Include("LuaUI/Configs/widgets_only_cmds.lua", nil, VFS.RAW_FIRST)
-- All of these commands are handled by widgets; none are sent to gadgets.

local commands = {
	GBC_ECO = 13927, -- global build command economy/units split presets
	GBC_BALANCED = 13928,
	GBC_ARMY = 13929,

	-- missile launcher (Missile Command Center widget; see Configs/missile_config.lua)
	MISSILE_ZENITH   = 39610,
	MISSILE_TRINITY  = 39611,
	MISSILE_REEF     = 39612,
	MISSILE_SCYLLA   = 39613,
	MISSILE_EOS      = 39614,
	MISSILE_SEISMIC  = 39615,
	MISSILE_SHOCKLEY = 39616,
	MISSILE_INFERNO  = 39617,
	MISSILE_ZENO     = 39618,
}

local registered = Spring.Utilities.CMD
local env = getfenv()
for name, cmdID in pairs(commands) do
	-- Keep the official ID if a release has since added the same command.
	if registered[name] == nil then
		registered[name] = cmdID
	end
	env["CMD_" .. name] = registered[name]
end

return commands
