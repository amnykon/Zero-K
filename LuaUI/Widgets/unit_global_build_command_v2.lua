--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--
--  file:    unit_global_build_command_v2.lua
--  brief:   Start of a new Global Build Command. While GBC mode is on, every
--           build/repair/reclaim/resurrect order you give is queued into
--           WG.GlobalBuildQueueShare (gui_global_build_queue_ally.lua)
--           instead of being handed to the selected units, so you can keep
--           an army selected and still queue jobs for your constructors.
--           Constructors join or leave GBC with the Global Build state
--           button (on by default). No worker allocation yet.
--
--  Usage:
--    Tab (default; rebind under Hotkeys/Construction)
--                  - toggle GBC mode on/off.
--    any build/repair/reclaim/resurrect order, while GBC mode is on
--                  - queued as a GBC job instead of ordered. Everything the
--                    engine normally does for an order still applies: shift
--                    line/area building placement, facing, build grid
--                    snapping, area and single-target repair/reclaim.
--    right drag    - while GBC mode is on, remove every job this widget
--                    queued inside the circle.
--    Global Build Cancel (command panel, only while GBC mode is on)
--                  - area command that removes jobs the same way.
--    escape        - cancel an in-progress right-drag.
--    Global Build state button (constructors only; hidden in the command
--    panel by default, see integral_menu_culling.lua)
--                  - whether the selected constructors are GBC workers.
--
--  Orders are taken in CommandNotify, so only orders that go through the
--  engine's normal command path are seen. Widgets that give build orders
--  straight to units with Spring.GiveOrderToUnit (eg. area mex placement,
--  lasso terraform) bypass this and are not queued.
--
--  Job identity is derived by Update() itself from the job's own content
--  (see gui_global_build_queue_ally.lua's BuildJobHash) - this widget never
--  computes a hash itself, just keeps whatever jobId each Update() call
--  hands back, to pass to Delete() later. Placing the same building at the
--  same spot again naturally updates that same job rather than queuing a
--  duplicate, since it hashes to the same jobId both times.
--
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

function widget:GetInfo()
	return {
		name      = "Global Build Command v2",
		desc      = "Start of a new Global Build Command: while toggled on (Tab by default), build/repair/reclaim/resurrect orders are queued into WG.GlobalBuildQueueShare instead of given to the selected units.",
		author    = "amnykon",
		date      = "September 26, 2026",
		license   = "GNU GPL, v2 or later",
		layer     = 1001, -- CommandNotify runs from the highest layer down, so this sees orders before most other widgets
		enabled   = true,
	}
end

include("keysym.lua")
VFS.Include("LuaRules/Configs/customcmds.h.lua")

local spGetMouseState     = Spring.GetMouseState
local spTraceScreenRay    = Spring.TraceScreenRay
local spGetGroundHeight   = Spring.GetGroundHeight
local spGetUnitPosition   = Spring.GetUnitPosition
local spGetFeaturePosition = Spring.GetFeaturePosition
local spEcho              = Spring.Echo
local spGetMyTeamID       = Spring.GetMyTeamID
local spGetMyPlayerID     = Spring.GetMyPlayerID
local spGetTeamInfo       = Spring.GetTeamInfo
local spGetSpectatingState = Spring.GetSpectatingState
local spGetTeamUnits      = Spring.GetTeamUnits
local spGetUnitDefID      = Spring.GetUnitDefID
local spGetSelectedUnits  = Spring.GetSelectedUnits
local spGetUnitTeam       = Spring.GetUnitTeam
local spGetUnitRulesParam = Spring.GetUnitRulesParam
local spGetUnitCmdDescs   = Spring.GetUnitCmdDescs

local CMD_REPAIR    = CMD.REPAIR
local CMD_RECLAIM   = CMD.RECLAIM
local CMD_RESURRECT = CMD.RESURRECT

local sqrt  = math.sqrt

local function DistanceSq(x1, z1, x2, z2)
	return (x1 - x2) * (x1 - x2) + (z1 - z2) * (z1 - z2)
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local active = false -- GBC mode on/off, toggled by the toggle hotkey

-- Every job this widget has queued (jobId -> {x, z}), so a right-drag knows
-- what it's allowed to remove without touching anything else's jobs. jobId
-- is whatever Update() below assigned - this widget never computes one itself.
local myJobs = {}

local dragX, dragZ, dragR -- in-progress right-drag for area removal

-- The team whose constructors this player's GBC manages, or nil for none.
-- Only the team's leader manages it: with commshare, several players control
-- one team, and the engine doesn't record which of them owns which unit, so
-- the leader (the player whose team the others merged into) manages every
-- constructor on it and the others manage none. Their GBC mode still queues
-- jobs, which the leader's worker AI sees like any ally's. Spectators never
-- lead the team they're watching, so they manage nothing either.
local managedTeamID = nil

-- GBC workers: workers[unitID] = true for every mobile builder on the
-- managed team with the Global Build state on. A builder with it off simply isn't here.
-- New builders start on, and join as soon as they're created, so a nanoframe
-- switched off before it finishes stays off. Unfinished builders are in the
-- set too - the worker AI skips units it can't order yet. This is only "does
-- GBC control this unit"; worker status (idle, direct orders, working a job)
-- is the worker AI's concern and gets its own tables later.
local workers = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function mousePos()
	local mx, my = spGetMouseState()
	local _, pos = spTraceScreenRay(mx, my, true)
	if pos then
		return pos[1], pos[3]
	end
end

local function StopDrag()
	dragX, dragZ, dragR = nil, nil, nil
end

local function SetActive(on)
	active = on
	StopDrag()
	Spring.ForceLayoutUpdate() -- re-run CommandsChanged, to show/hide Global Build Cancel
	spEcho("GBC mode: " .. (active and "ON (orders are queued as GBC jobs, right-drag to remove)" or "OFF"))
end

--------------------------------------------------------------------------------
-- Options
--------------------------------------------------------------------------------

options_path = 'Settings/Unit Behaviour/Worker AI'
options_order = {'toggle'}
options = {
	toggle = {
		name = 'Toggle GBC Mode',
		desc = 'While on, build/repair/reclaim/resurrect orders are queued as Global Build Command jobs instead of being given to the selected units.',
		type = 'button',
		hotkey = "tab",
		OnChange = function(self)
			SetActive(not active)
		end,
		path = 'Hotkeys/Construction',
	},
}

--------------------------------------------------------------------------------
-- Membership
--------------------------------------------------------------------------------

local function IsMobileBuilder(unitDefID)
	return unitDefID and UnitDefs[unitDefID].isMobileBuilder
end

-- For the state button: selected units can include ones on other teams (eg.
-- while spectating), which GBC doesn't control.
local function IsOurBuilder(unitID)
	return managedTeamID and spGetUnitTeam(unitID) == managedTeamID and IsMobileBuilder(spGetUnitDefID(unitID))
end

local function AddBuilder(unitID, unitDefID)
	if IsMobileBuilder(unitDefID) then
		workers[unitID] = true
	end
end

local function GetManagedTeamID()
	if spGetSpectatingState() then
		return nil
	end
	local teamID = spGetMyTeamID()
	local _, leaderID = spGetTeamInfo(teamID, false)
	if leaderID ~= spGetMyPlayerID() then
		return nil
	end
	return teamID
end

-- Rebuilds membership from scratch when the managed team changes (startup,
-- becoming or ceasing to be a team's leader, spectating). A merge into the
-- team we already lead doesn't come through here: its units arrive through
-- UnitGiven like any other transfer.
local function UpdateManagedTeam(force)
	local teamID = GetManagedTeamID()
	if teamID == managedTeamID and not force then
		return
	end
	managedTeamID = teamID
	workers = {}
	if not managedTeamID then
		return
	end
	local units = spGetTeamUnits(managedTeamID)
	if not units then
		return
	end
	for i = 1, #units do
		local unitID = units[i]
		AddBuilder(unitID, spGetUnitDefID(unitID))
	end
end

local function SetGlobalBuildState(state)
	local selectedUnits = spGetSelectedUnits()
	for i = 1, #selectedUnits do
		local unitID = selectedUnits[i]
		if IsOurBuilder(unitID) then
			workers[unitID] = (state == 1) or nil
		end
	end
end

-- Removes every job this widget queued whose position is inside the circle.
-- Shared by right-drag removal and the Global Build Cancel command.
local function RemoveJobsInCircle(x, z, r)
	if not WG.GlobalBuildQueueShare then
		return
	end
	local rSq = r * r
	for jobId, pos in pairs(myJobs) do
		if DistanceSq(x, z, pos.x, pos.z) <= rSq then
			WG.GlobalBuildQueueShare.Delete(jobId)
			myJobs[jobId] = nil
		end
	end
end

-- Queues one job and remembers it for right-drag removal.
local function QueueJob(job)
	local jobId = WG.GlobalBuildQueueShare.Update(job)
	myJobs[jobId] = {x = job.x, z = job.z}
end

--------------------------------------------------------------------------------
-- Callins
--------------------------------------------------------------------------------

-- While GBC mode is on, offers every command our GBC workers could carry out
-- - their build options and repair/reclaim/resurrect - whatever is selected,
-- so jobs can be queued with no constructor selected. The command panel puts
-- these in the build tabs and orders like the selection's own commands, and
-- CommandNotify turns them into jobs before they reach any unit. Commands the
-- selection already has are skipped, so a selected constructor doesn't give
-- two copies of each.
--
-- UNTESTED: relies on the engine doing building placement (preview, facing,
-- grid snapping, line/area placement) for a widget-added build command that
-- no selected unit can build.
local workerCommands = {
	{
		flag    = "canRepair",
		id      = CMD_REPAIR,
		type    = CMDTYPE.ICON_UNIT_OR_AREA,
		name    = 'Repair',
		action  = 'repair',
		cursor  = 'Repair',
		tooltip = 'Queue a GBC repair job.',
	},
	{
		flag    = "canReclaim",
		id      = CMD_RECLAIM,
		type    = CMDTYPE.ICON_UNIT_FEATURE_OR_AREA,
		name    = 'Reclaim',
		action  = 'reclaim',
		cursor  = 'Reclaim',
		tooltip = 'Queue a GBC reclaim job.',
	},
	{
		flag    = "canResurrect",
		id      = CMD_RESURRECT,
		type    = CMDTYPE.ICON_UNIT_FEATURE_OR_AREA,
		name    = 'Resurrect',
		action  = 'resurrect',
		cursor  = 'Resurrect',
		tooltip = 'Queue a GBC resurrect job.',
	},
}

local function AddWorkerCommands(customCommands)
	-- Commands the selection already offers.
	local existing = {}
	local commands = widgetHandler.commands
	if commands then
		for _, command in pairs(commands) do
			if type(command) == "table" and command.id then
				existing[command.id] = true
			end
		end
	end

	-- Every unit type among our workers, once each. Field factory builders
	-- (the support commander's engineer) are the exception: their UnitDef
	-- lists every factory unit, but unit_field_factory.lua leaves each unit
	-- only the build command for the one unit it's copying, so read those
	-- builders' actual build commands instead.
	local workerDefs = {}
	local buildDefIDs = {}
	for unitID in pairs(workers) do
		local unitDefID = spGetUnitDefID(unitID)
		if unitDefID then
			if UnitDefs[unitDefID].customParams.field_factory then
				local cmdDescs = spGetUnitCmdDescs(unitID)
				if cmdDescs then
					for j = 1, #cmdDescs do
						local cmdDesc = cmdDescs[j]
						if cmdDesc.id < 0 and not cmdDesc.disabled then
							buildDefIDs[-cmdDesc.id] = true
						end
					end
				end
			end
			workerDefs[unitDefID] = true
		end
	end
	for unitDefID in pairs(workerDefs) do
		if not UnitDefs[unitDefID].customParams.field_factory then
			local buildOptions = UnitDefs[unitDefID].buildOptions
			for j = 1, #buildOptions do
				buildDefIDs[buildOptions[j]] = true
			end
		end
	end

	for i = 1, #workerCommands do
		local command = workerCommands[i]
		if not existing[command.id] then
			for unitDefID in pairs(workerDefs) do
				if UnitDefs[unitDefID][command.flag] then
					customCommands[#customCommands+1] = {
						id      = command.id,
						type    = command.type,
						name    = command.name,
						action  = command.action,
						cursor  = command.cursor,
						tooltip = command.tooltip,
					}
					existing[command.id] = true
					break
				end
			end
		end
	end

	for buildDefID in pairs(buildDefIDs) do
		local cmdID = -buildDefID
		if not existing[cmdID] then
			local buildDef = UnitDefs[buildDefID]
			customCommands[#customCommands+1] = {
				id      = cmdID,
				type    = CMDTYPE.ICON_BUILDING,
				name    = buildDef.name,
				action  = 'buildunit_' .. buildDef.name,
				tooltip = buildDef.humanName,
			}
			existing[cmdID] = true
		end
	end
end

-- Adds the Global Build on/off state button when a constructor is selected,
-- showing the state of the first selected constructor.
--
-- While GBC mode is on, also adds the Global Build Cancel area command,
-- whatever is selected, so jobs can be removed with an army selected too.
function widget:CommandsChanged()
	local customCommands = widgetHandler.customCommands
	local selectedUnits = spGetSelectedUnits()
	for i = 1, #selectedUnits do
		local unitID = selectedUnits[i]
		if IsOurBuilder(unitID) then
			customCommands[#customCommands+1] = {
				id      = CMD_GLOBAL_BUILD,
				type    = CMDTYPE.ICON_MODE,
				tooltip = 'Toggle using global build command for workers.',
				name    = 'Global Build',
				cursor  = 'Repair',
				action  = 'globalbuild',
				params  = {workers[unitID] and 1 or 0, 'off', 'on'},
			}
			break
		end
	end

	if active then
		customCommands[#customCommands+1] = {
			id      = CMD_GBCANCEL,
			type    = CMDTYPE.ICON_AREA,
			tooltip = 'Cancel Global Build tasks.',
			name    = 'Global Build Cancel',
			cursor  = 'Repair',
			action  = 'globalbuildcancel',
		}
		AddWorkerCommands(customCommands)
	end
end

function widget:CommandNotify(cmdID, params, opts)
	if cmdID == CMD_GLOBAL_BUILD then
		SetGlobalBuildState(params[1])
		return true
	end

	-- Handled even if GBC mode was switched off while the command was on the
	-- cursor, so it never reaches the selected units.
	if cmdID == CMD_GBCANCEL then
		if #params >= 4 then
			RemoveJobsInCircle(params[1], params[3], params[4])
		end
		return true
	end

	if not active or not WG.GlobalBuildQueueShare then
		return false
	end

	if cmdID < 0 then
		if not (params[1] and params[3]) then
			return false -- factory production (no position) - not a GBC job
		end
		QueueJob({id = cmdID, x = params[1], y = params[2], z = params[3], h = params[4] or 0})
		return true
	end

	if cmdID == CMD_REPAIR or cmdID == CMD_RECLAIM or cmdID == CMD_RESURRECT then
		if #params >= 4 then -- area job
			QueueJob({id = cmdID, x = params[1], y = params[2], z = params[3], r = params[4]})
			return true
		elseif #params == 1 then -- single target: cache its current position
			local target = params[1]
			local x, y, z
			if target >= Game.maxUnits then
				x, y, z = spGetFeaturePosition(target - Game.maxUnits)
			else
				x, y, z = spGetUnitPosition(target)
			end
			if not x then
				return false
			end
			QueueJob({id = cmdID, target = target, x = x, y = y, z = z})
			return true
		end
	end

	return false
end

-- For other widgets, eg. the Quick Selection Bar's GBC button
-- (gui_chili_core_selector.lua).
local externalFunctions = {}

function externalFunctions.IsActive()
	return active
end

function externalFunctions.SetActive(on)
	if on ~= active then
		SetActive(on)
	end
end

function externalFunctions.Toggle()
	SetActive(not active)
end

-- The toggle's current hotkey, readable, or "" if it has none.
function externalFunctions.GetHotkey()
	local hotkey = WG.crude and WG.crude.GetOptionHotkey and WG.crude.GetOptionHotkey(options.toggle.path, options.toggle)
	return hotkey or ""
end

-- How many jobs we own in the shared queue.
function externalFunctions.GetJobCount()
	local share = WG.GlobalBuildQueueShare
	if not share then
		return 0
	end
	return #share.GetJobIds(spGetMyPlayerID())
end

function widget:Initialize()
	UpdateManagedTeam(true)
	WG.GlobalBuildCommandV2 = externalFunctions
end

function widget:Shutdown()
	WG.GlobalBuildCommandV2 = nil
end

function widget:PlayerChanged(playerID)
	UpdateManagedTeam()
end

function widget:UnitCreated(unitID, unitDefID, unitTeam)
	if managedTeamID and unitTeam == managedTeamID then
		AddBuilder(unitID, unitDefID)
	end
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam)
	-- Morphing (eg. a commander upgrade) creates a new unit and then destroys
	-- the old one, so the new unit has already joined as on through
	-- UnitCreated. Carry over the old builder's state, so a builder switched
	-- off stays off after it morphs.
	local morphedTo = spGetUnitRulesParam(unitID, "wasMorphedTo")
	if morphedTo and unitTeam == managedTeamID and IsMobileBuilder(unitDefID) and not workers[unitID] then
		workers[morphedTo] = nil
	end
	workers[unitID] = nil
end

function widget:UnitGiven(unitID, unitDefID, newTeam, oldTeam)
	if managedTeamID and newTeam == managedTeamID then
		AddBuilder(unitID, unitDefID)
	end
end

function widget:UnitTaken(unitID, unitDefID, oldTeam, newTeam)
	if oldTeam == managedTeamID and newTeam ~= managedTeamID then
		workers[unitID] = nil
	end
end

function widget:KeyPress(key)
	if active and dragX and key == KEYSYMS.ESCAPE then
		StopDrag()
		return true
	end
	return false
end

function widget:MousePress(x, y, button)
	if not active or button ~= 3 then
		return false
	end
	local mx, mz = mousePos()
	if mx then
		dragX, dragZ, dragR = mx, mz, 0
	end
	return true
end

function widget:MouseMove(x, y, dx, dy, button)
	if dragX then
		local mx, mz = mousePos()
		if mx then
			dragR = sqrt(DistanceSq(dragX, dragZ, mx, mz))
		end
	end
end

function widget:MouseRelease(x, y, button)
	if not dragX then
		return false
	end
	RemoveJobsInCircle(dragX, dragZ, dragR)
	StopDrag()
	return true
end

function widget:DrawWorld()
	if dragX then
		gl.Color(1, 0.3, 0.3, 0.3)
		gl.DrawGroundCircle(dragX, spGetGroundHeight(dragX, dragZ), dragZ, dragR, 32)
		gl.Color(1, 1, 1, 1)
	end
end

-- While GBC mode is on, label the cursor so it's obvious orders aren't going
-- to the selected units.
function widget:DrawScreen()
	if not active or Spring.IsGUIHidden() then
		return
	end
	local mx, my = spGetMouseState()
	local hotkey = externalFunctions.GetHotkey()
	local label = "GBC"
	if hotkey ~= "" then
		label = label .. " (" .. hotkey .. ")"
	end
	gl.Color(1.0, 0.8, 0.2, 1)
	gl.Text(label, mx + 18, my - 28, 14, "o")
	gl.Color(1, 1, 1, 1)
end
