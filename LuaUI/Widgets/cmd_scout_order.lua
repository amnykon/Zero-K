function widget:GetInfo()
	return {
		name      = "Scout Order",
		desc      = "Adds Sparrow, Swift and Flea scout commands. Drag to scatter a line of scouts spaced by LOS, or click for a single point. Each point is handed to a different scout: the Swift sprints and the Sparrow detonates on arrival, while the Flea is sent to scout passively (return fire, building selection rank, deselected).",
		author    = "Claude",
		date      = "2026",
		license   = "GNU GPL, v2 or later",
		handler   = true, -- for adding customCommands into the UI
		layer     = 0,
		enabled   = true,
	}
end

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------
options_path = 'Settings/Interface/Scout Order'
options_order = { 'spacing', 'drawLine' }
options = {
	spacing = {
		name = 'Point spacing (x LOS)',
		desc = 'Distance between scattered points, as a multiple of the scout type\'s line of sight. Lower values pack scouts closer together for denser coverage.',
		type = 'number',
		value = 1.0,
		min = 0.1, max = 2.0, step = 0.1,
	},
	drawLine = {
		name = 'Draw preview line',
		desc = 'Show the dragged path and the resulting scout points while placing the order.',
		type = 'bool',
		value = true,
	},
}

--------------------------------------------------------------------------------
-- Speedups and constants
--------------------------------------------------------------------------------
VFS.Include("LuaRules/Configs/customcmds.h.lua")

local spGetActiveCommand   = Spring.GetActiveCommand
local spTraceScreenRay     = Spring.TraceScreenRay
local spGetGroundHeight    = Spring.GetGroundHeight
local spGetMouseState      = Spring.GetMouseState
local spGetSelectedUnits   = Spring.GetSelectedUnits
local spGetTeamUnits       = Spring.GetTeamUnits
local spGetUnitDefID       = Spring.GetUnitDefID
local spGetUnitPosition    = Spring.GetUnitPosition
local spGetUnitHealth      = Spring.GetUnitHealth
local spGetUnitIsDead      = Spring.GetUnitIsDead
local spGetUnitRulesParam  = Spring.GetUnitRulesParam
local spGetUnitStates      = Spring.GetUnitStates
local spSelectUnitArray    = Spring.SelectUnitArray
local spGiveOrderToUnit    = Spring.GiveOrderToUnit
local spValidUnitID        = Spring.ValidUnitID
local spSetActiveCommand   = Spring.SetActiveCommand
local spIsAboveMiniMap     = Spring.IsAboveMiniMap

local sqrt  = math.sqrt
local floor = math.floor
local max   = math.max

local CMD_MOVE           = CMD.MOVE
local CMD_INSERT         = CMD.INSERT
local CMD_OPT_ALT        = CMD.OPT_ALT
local CMD_OPT_SHIFT      = CMD.OPT_SHIFT
local CMD_OPT_INTERNAL   = CMD.OPT_INTERNAL
local CMD_ONECLICK       = Spring.Utilities.CMD.ONECLICK_WEAPON
local CMD_RAW_MOVE       = Spring.Utilities.CMD.RAW_MOVE
local CMD_FIRE_STATE     = CMD.FIRE_STATE

local FIRE_STATE_RETURN  = 1 -- 0 hold fire, 1 return fire, 2 fire at will
local FLEA_RANK          = 1 -- selection rank Low, the same level as buildings

local FRAMES_PER_SECOND = 30
local CLICK_THRESHOLD   = 20     -- drag shorter than this (elmos) counts as a click
local CHECK_INTERVAL    = 3      -- frames between sprint-range checks
local RETURN_DISTANCE_SQ = 250 * 250 -- how close to a pad counts as "back"

local PAD_REFRESH = 15 -- frames between rebuilds of the retreat-target cache

-- Somewhere safe to recharge after a run: any allied factory, plus airpads.
local retreatDefs = {}
for id = 1, #UnitDefs do
	local ud = UnitDefs[id]
	if ud and (ud.isFactory or ud.name == "staticrearm") then
		retreatDefs[id] = true
	end
end

-- Custom command IDs (10283/10284 are Newton Firezone; 10287-10293 are bombers).
local CMD_SCOUT_SPARROW = 10285
local CMD_SCOUT_SWIFT   = 10286
local CMD_SCOUT_FLEA    = 10294

--------------------------------------------------------------------------------
-- Per-type data, derived from unit defs
--------------------------------------------------------------------------------
local myTeam = Spring.GetMyTeamID()
local myAllyTeam = Spring.GetMyAllyTeamID()

-- unitData[unitDefID] = { cmdID, los, mode, sprintRangeSq }
-- mode "sprint": Sparrow/Swift dash to the point and trigger their ability.
-- mode "flea":   send a Flea and set it to a passive scouting state.
local unitData = {}
local cmdToDef = {}   -- cmdID -> unitDefID

local function BuildTypeData(unitName, cmdID, mode)
	local ud = UnitDefNames[unitName]
	if not ud then
		return
	end
	local data = {
		cmdID = cmdID,
		los   = ud.sightDistance or 500,
		mode  = mode,
	}
	if mode == "sprint" then
		local cp = ud.customParams or {}
		local boostMult     = tonumber(cp.boost_speed_mult) or 5
		local boostDuration = tonumber(cp.boost_duration) or 30 -- frames
		-- Distance the scout dashes during its boost. Triggering the ability this
		-- far from the point lands the Swift's dash / Sparrow's detonation on it.
		local perFrameSpeed = (ud.speed or 0) / FRAMES_PER_SECOND
		local sprintRange   = perFrameSpeed * boostMult * boostDuration
		data.sprintRangeSq  = sprintRange * sprintRange
	end
	unitData[ud.id] = data
	cmdToDef[cmdID] = ud.id
end

BuildTypeData("planelightscout", CMD_SCOUT_SPARROW, "sprint") -- Sparrow
BuildTypeData("planefighter",    CMD_SCOUT_SWIFT,   "sprint") -- Swift
BuildTypeData("spiderscout",     CMD_SCOUT_FLEA,    "flea")   -- Flea

-- Only the Swift (which survives its run) retreats to a pad; the Sparrow detonates.
local SWIFT_DEF = cmdToDef[CMD_SCOUT_SWIFT]

--------------------------------------------------------------------------------
-- Command descriptors
--------------------------------------------------------------------------------
-- Placement in the "Scouts" tab, the icon and the tooltip come from
-- commandDisplayConfig in integral_menu_config.lua. The name field carries the
-- available-scout count (drawn by the menu because drawName is set there) and is
-- refreshed in widget:Update.
local cmdSparrow = {
	id       = CMD_SCOUT_SPARROW,
	type     = CMDTYPE.ICON_MAP,
	name     = "",
	tooltip  = 'Sparrow Scout Run: click or drag a line to scatter Sparrows. Each detonates on arrival for a reveal ping.',
	cursor   = 'Attack',
	action   = 'scoutrun_sparrow',
	texture  = 'LuaUI/Images/commands/Bold/detonate.png',
	disabled = false,
	params   = { },
}

local cmdSwift = {
	id       = CMD_SCOUT_SWIFT,
	type     = CMDTYPE.ICON_MAP,
	name     = "",
	tooltip  = 'Swift Scout Run: click or drag a line to scatter Swifts. Each speed-boosts to reach its point.',
	cursor   = 'Move',
	action   = 'scoutrun_swift',
	texture  = 'LuaUI/Images/commands/Bold/sprint.png',
	disabled = false,
	params   = { },
}

local cmdFlea = {
	id       = CMD_SCOUT_FLEA,
	type     = CMDTYPE.ICON_MAP,
	name     = "",
	tooltip  = 'Flea Scout: click or drag a line to send Fleas to scout. Each is set to return fire, dropped to building selection rank and deselected.',
	cursor   = 'Move',
	action   = 'scoutrun_flea',
	texture  = 'LuaUI/Images/commands/Bold/move.png',
	disabled = false,
	params   = { },
}

-- Stable order matching the tab column layout (Swift col 1, Sparrow col 2, Flea col 3).
local scoutCommands = {
	{cmdID = CMD_SCOUT_SWIFT,   desc = cmdSwift,   defID = cmdToDef[CMD_SCOUT_SWIFT]},
	{cmdID = CMD_SCOUT_SPARROW, desc = cmdSparrow, defID = cmdToDef[CMD_SCOUT_SPARROW]},
	{cmdID = CMD_SCOUT_FLEA,    desc = cmdFlea,    defID = cmdToDef[CMD_SCOUT_FLEA]},
}

-- Ownership tracking: a scout command is offered whenever the player owns at
-- least one unit of that type, regardless of the current selection. The command
-- can then dispatch unselected scouts (selected ones are merely prioritised).
local owned = {}       -- unitID -> unitDefID (our scout types, on my team)
local ownedCount = {}  -- unitDefID -> count
local returning = {}   -- unitID -> true while a Swift is flying back to safety
local retreatPads = {} -- cached list of allied factory / airpad positions {x, y, z}

local function AddOwned(unitID, unitDefID, unitTeam)
	if unitTeam == myTeam and unitData[unitDefID] and not owned[unitID] then
		owned[unitID] = unitDefID
		ownedCount[unitDefID] = (ownedCount[unitDefID] or 0) + 1
	end
end

local function RemoveOwned(unitID)
	local unitDefID = owned[unitID]
	if unitDefID then
		ownedCount[unitDefID] = ownedCount[unitDefID] - 1
		owned[unitID] = nil
	end
	returning[unitID] = nil
end

local function RescanOwned()
	owned = {}
	ownedCount = {}
	returning = {}
	local teamUnits = spGetTeamUnits(myTeam)
	for i = 1, #teamUnits do
		AddOwned(teamUnits[i], spGetUnitDefID(teamUnits[i]), myTeam)
	end
end

-- Rebuild the cache of allied retreat targets (any allied factory, plus airpads).
local function RebuildRetreatPads()
	retreatPads = {}
	local allyTeams = Spring.GetTeamList(myAllyTeam) or {}
	for a = 1, #allyTeams do
		local units = spGetTeamUnits(allyTeams[a])
		for i = 1, #units do
			local defID = spGetUnitDefID(units[i])
			if defID and retreatDefs[defID] then
				local x, y, z = spGetUnitPosition(units[i])
				if x then
					retreatPads[#retreatPads + 1] = {x, y, z}
				end
			end
		end
	end
end

-- Nearest retreat target to a position, with its squared distance.
local function NearestPad(x, z)
	local best, bestDistSq
	for i = 1, #retreatPads do
		local pos = retreatPads[i]
		local dx, dz = pos[1] - x, pos[3] - z
		local distSq = dx*dx + dz*dz
		if not best or distSq < bestDistSq then
			best, bestDistSq = pos, distSq
		end
	end
	return best, bestDistSq
end

function widget:CommandsChanged()
	local customCommands = widgetHandler.customCommands
	for i = 1, #scoutCommands do
		local sc = scoutCommands[i]
		if (ownedCount[sc.defID] or 0) > 0 then
			customCommands[#customCommands + 1] = sc.desc
		end
	end
end

-- Refresh the tab's per-button count badge and keep it visible while nothing is
-- selected. Mirrors missile_command_center.lua: the integral menu only re-reads
-- custom commands on CommandsChanged, which the menu pipeline does not run on its
-- own with an empty selection, so a layout update is forced when needed.
local UPDATE_FREQUENCY = 0.25
local updateTimer = UPDATE_FREQUENCY + 1
local wasEmptySelection = false

function widget:Update(dt)
	updateTimer = updateTimer + dt
	if updateTimer < UPDATE_FREQUENCY then
		return
	end
	updateTimer = 0

	local changed = false
	local activeIcons = {}
	for i = 1, #scoutCommands do
		local sc = scoutCommands[i]
		local count = ownedCount[sc.defID] or 0
		local displayName = (count > 0) and ("x" .. count) or ""
		local disabled = (count == 0)
		if sc.desc.name ~= displayName or sc.desc.disabled ~= disabled then
			sc.desc.name = displayName
			sc.desc.disabled = disabled
			changed = true
		end
		if count > 0 then
			activeIcons[#activeIcons + 1] = {icon = "#" .. sc.defID, count = count, progress = 0}
		end
	end
	WG.airScoutActiveIcons = activeIcons

	local emptySelection = (Spring.GetSelectedUnitsCount() == 0)
	if changed or (emptySelection and not wasEmptySelection) then
		Spring.ForceLayoutUpdate()
	end
	wasEmptySelection = emptySelection
end

--------------------------------------------------------------------------------
-- Path capture and point generation
--------------------------------------------------------------------------------
local drawing    = false   -- currently dragging out an order
local activeDef  = nil     -- unitDefID being ordered
local fNodes     = {}      -- {x, y, z} path samples
local fDists     = {}      -- cumulative distance to each node
local lineLength = 0

local function ResetPath()
	drawing    = false
	activeDef  = nil
	fNodes     = {}
	fDists     = {}
	lineLength = 0
end

local function AddNode(pos)
	local n = #fNodes
	if n == 0 then
		fNodes[1] = pos
		fDists[1] = 0
		return true
	end
	local prev = fNodes[n]
	local dx, dz = pos[1] - prev[1], pos[3] - prev[3]
	local distSq = dx*dx + dz*dz
	if distSq == 0 then
		return false
	end
	local dis = sqrt(distSq)
	fNodes[n + 1] = pos
	fDists[n + 1] = fDists[n] + dis
	lineLength = lineLength + dis
	return true
end

-- Evenly spaced points along the sampled path (endpoints included).
local function GetSpacedPoints(number)
	if number <= 1 then
		local mid = fNodes[floor(#fNodes / 2) + 1] or fNodes[1]
		return { {mid[1], mid[2], mid[3]} }
	end

	local spacing = fDists[#fNodes] / (number - 1)
	local points = {}

	local sPos = fNodes[1]
	local sX, sZ, sDist = sPos[1], sPos[3], 0
	local eIdx = 2
	local ePos = fNodes[2]
	local eX, eZ, eDist = ePos[1], ePos[3], fDists[2]

	points[1] = {sPos[1], max(0, spGetGroundHeight(sPos[1], sPos[3])), sPos[3]}

	for n = 1, number - 2 do
		local reqDist = n * spacing
		while reqDist > eDist and eIdx < #fNodes do
			sX, sZ, sDist = eX, eZ, eDist
			eIdx = eIdx + 1
			ePos = fNodes[eIdx]
			eX, eZ, eDist = ePos[1], ePos[3], fDists[eIdx]
		end
		local span = eDist - sDist
		local frac = (span > 0) and ((reqDist - sDist) / span) or 0
		local nX = sX * (1 - frac) + eX * frac
		local nZ = sZ * (1 - frac) + eZ * frac
		points[n + 1] = {nX, max(0, spGetGroundHeight(nX, nZ)), nZ}
	end

	local last = fNodes[#fNodes]
	points[number] = {last[1], max(0, spGetGroundHeight(last[1], last[3])), last[3]}
	return points
end

--------------------------------------------------------------------------------
-- Unit selection and dispatch
--------------------------------------------------------------------------------
local tracked = {}   -- unitID -> {x, y, z, sprintRangeSq}
local fleaState = {} -- unitID -> {fireState} while a Flea holds its scouting state

-- A direct order from the player (one of these, not internal) restores a Flea.
local RESTORE_CMDS = {
	[CMD_MOVE]      = true,
	[CMD_RAW_MOVE]  = true,
	[CMD.FIGHT]     = true,
	[CMD.ATTACK]    = true,
	[CMD.PATROL]    = true,
	[CMD.GUARD]     = true,
	[CMD.STOP]      = true,
	[CMD.MANUALFIRE] = true,
}

local function IsFullyBuilt(unitID)
	local _, _, _, _, buildProgress = spGetUnitHealth(unitID)
	return buildProgress and buildProgress >= 1
end

local function IsReadyToSprint(unitID)
	-- Swift uses specialReloadRemaining (0 = ready). Sparrow's detonate is a
	-- one-shot with no reload param, so an alive Sparrow reads as ready (nil).
	return (spGetUnitRulesParam(unitID, "specialReloadRemaining") or 0) == 0
end

-- Priority tier for a candidate: selected (0) < ready to sprint (1) < other (2).
local function CandidateTier(unitID, selectedSet)
	if selectedSet[unitID] then
		return 0
	elseif IsReadyToSprint(unitID) then
		return 1
	end
	return 2
end

-- Send a Flea to scout: passive states (return fire, building selection rank)
-- and a move it will keep unless the player takes over. Widget orders are marked
-- internal so they don't count as the player's own direct order.
local function ApplyFleaScout(unitID, pt, shift)
	local opt = CMD_OPT_INTERNAL + (shift and CMD_OPT_SHIFT or 0)
	local states = spGetUnitStates(unitID)
	fleaState[unitID] = { fireState = states and states.firestate }
	spGiveOrderToUnit(unitID, CMD_MOVE, {pt[1], pt[2], pt[3]}, opt)
	spGiveOrderToUnit(unitID, CMD_FIRE_STATE, {FIRE_STATE_RETURN}, CMD_OPT_INTERNAL)
	if WG.SetSelectionRank then
		WG.SetSelectionRank(unitID, FLEA_RANK)
	end
end

-- Restore a Flea's normal states after the player gives it a direct order.
local function RestoreFlea(unitID)
	local st = fleaState[unitID]
	if not st then
		return
	end
	fleaState[unitID] = nil
	if WG.SetSelectionRank then
		WG.SetSelectionRank(unitID, nil) -- clear the override, back to default rank
	end
	if st.fireState then
		spGiveOrderToUnit(unitID, CMD_FIRE_STATE, {st.fireState}, CMD_OPT_INTERNAL)
	end
end

local function DeselectUnits(units)
	local sel = spGetSelectedUnits()
	local remove = {}
	for i = 1, #units do
		remove[units[i]] = true
	end
	local kept, changed = {}, false
	for i = 1, #sel do
		if remove[sel[i]] then
			changed = true
		else
			kept[#kept + 1] = sel[i]
		end
	end
	if changed then
		spSelectUnitArray(kept)
	end
end

local function DispatchPoints(defID, points, shift)
	local data = unitData[defID]
	if not data then
		return
	end

	-- Candidate pool: all my fully-built, living units of this type.
	local selectedSet = {}
	local selected = spGetSelectedUnits()
	for i = 1, #selected do
		if spGetUnitDefID(selected[i]) == defID then
			selectedSet[selected[i]] = true
		end
	end

	local pool = {}
	local teamUnits = spGetTeamUnits(myTeam)
	for i = 1, #teamUnits do
		local unitID = teamUnits[i]
		if spGetUnitDefID(unitID) == defID and not spGetUnitIsDead(unitID) and IsFullyBuilt(unitID)
				and not returning[unitID] then -- a Swift on its way back is not available
			pool[#pool + 1] = unitID
		end
	end

	local assigned = {}
	local assignedFleas = {}
	local moveOpt = shift and CMD_OPT_SHIFT or 0
	local isFlea = (data.mode == "flea")

	for p = 1, #points do
		local pt = points[p]
		local bestUnit, bestTier, bestDistSq
		for i = 1, #pool do
			local unitID = pool[i]
			if not assigned[unitID] then
				local tier = CandidateTier(unitID, selectedSet)
				local ux, _, uz = spGetUnitPosition(unitID)
				local dx, dz = ux - pt[1], uz - pt[3]
				local distSq = dx*dx + dz*dz
				if (not bestUnit) or tier < bestTier or (tier == bestTier and distSq < bestDistSq) then
					bestUnit, bestTier, bestDistSq = unitID, tier, distSq
				end
			end
		end

		if not bestUnit then
			break -- ran out of scouts
		end

		assigned[bestUnit] = true
		if isFlea then
			ApplyFleaScout(bestUnit, pt, shift)
			assignedFleas[#assignedFleas + 1] = bestUnit
		else
			spGiveOrderToUnit(bestUnit, CMD_MOVE, {pt[1], pt[2], pt[3]}, moveOpt)
			tracked[bestUnit] = {
				x = pt[1], y = pt[2], z = pt[3],
				sprintRangeSq = data.sprintRangeSq,
				defID = defID,
			}
		end
	end

	-- Fleas are deselected so they drop out of the way after being sent.
	if #assignedFleas > 0 then
		DeselectUnits(assignedFleas)
	end
end

local function FinishOrder(shift)
	local defID = activeDef
	if defID and #fNodes > 0 then
		local data = unitData[defID]
		local points
		if lineLength < CLICK_THRESHOLD or #fNodes < 2 then
			local last = fNodes[#fNodes]
			points = { {last[1], max(0, spGetGroundHeight(last[1], last[3])), last[3]} }
		else
			local spacing = data.los * options.spacing.value
			local number = floor(lineLength / spacing) + 1
			points = GetSpacedPoints(number)
		end
		DispatchPoints(defID, points, shift)
	end
	ResetPath()
	if not shift then
		spSetActiveCommand(nil)
	end
end

--------------------------------------------------------------------------------
-- Mouse handling
--------------------------------------------------------------------------------
local function GetActiveScoutDef()
	local _, activeCmdID = spGetActiveCommand()
	return activeCmdID and cmdToDef[activeCmdID] or nil
end

function widget:MousePress(mx, my, button)
	if spIsAboveMiniMap(mx, my) then
		return false
	end
	if drawing then
		if button == 3 then -- right click cancels an in-progress order
			ResetPath()
			return true
		end
		return true
	end

	local defID = GetActiveScoutDef()
	if not defID or button ~= 1 then
		return false
	end

	local _, pos = spTraceScreenRay(mx, my, true)
	if not pos then
		return false
	end

	drawing   = true
	activeDef = defID
	AddNode(pos)
	return true
end

function widget:MouseMove(mx, my, dx, dy, button)
	if not drawing then
		return false
	end
	local _, pos = spTraceScreenRay(mx, my, true)
	if pos then
		AddNode(pos)
	end
	return true
end

function widget:MouseRelease(mx, my, button)
	if not drawing then
		return false
	end
	if button == 1 then
		local _, pos = spTraceScreenRay(mx, my, true)
		if pos then
			AddNode(pos)
		end
		local _, _, _, shift = Spring.GetModKeyState()
		FinishOrder(shift)
	end
	return true
end

-- Fallback for clicks the drag capture does not handle (e.g. issued from the
-- minimap). Treats the command as a single point.
function widget:CommandNotify(cmdID, params, cmdOptions)
	local defID = cmdToDef[cmdID]
	if not defID then
		return false
	end
	if params and params[1] and params[3] then
		local y = params[2] or max(0, spGetGroundHeight(params[1], params[3]))
		DispatchPoints(defID, { {params[1], y, params[3]} }, cmdOptions.shift)
	end
	if not cmdOptions.shift then
		spSetActiveCommand(nil)
	end
	return true
end

--------------------------------------------------------------------------------
-- Sprint / detonate trigger
--------------------------------------------------------------------------------
local function TriggerAbility(unitID, info)
	-- A Swift survives its run, so queue a retreat to the nearest pad after it
	-- reaches its point (append, so the sprint still carries it over the point),
	-- then it will fly back to try to stay alive.
	if info.defID == SWIFT_DEF then
		local ux, _, uz = spGetUnitPosition(unitID)
		local pad = ux and NearestPad(ux, uz)
		if pad then
			spGiveOrderToUnit(unitID, CMD_RAW_MOVE, {pad[1], pad[2], pad[3]}, CMD_OPT_SHIFT)
			returning[unitID] = true -- unavailable until it is back at a pad
		end
	end
	-- Insert the one-click ability at the front of the queue so the pending
	-- move-to-point (and any queued retreat) is preserved.
	spGiveOrderToUnit(unitID, CMD_INSERT, {0, CMD_ONECLICK, CMD_OPT_INTERNAL, 1}, CMD_OPT_ALT)
end

function widget:GameFrame(frame)
	if frame % CHECK_INTERVAL ~= 0 then
		return
	end
	if frame % PAD_REFRESH == 0 then
		RebuildRetreatPads()
	end
	for unitID, info in pairs(tracked) do
		if (not spValidUnitID(unitID)) or spGetUnitIsDead(unitID) then
			tracked[unitID] = nil
		else
			local ux, _, uz = spGetUnitPosition(unitID)
			local dx, dz = ux - info.x, uz - info.z
			if dx*dx + dz*dz <= info.sprintRangeSq then
				TriggerAbility(unitID, info)
				tracked[unitID] = nil
			end
		end
	end

	-- A returning Swift becomes available again once it reaches a pad.
	for unitID in pairs(returning) do
		if (not spValidUnitID(unitID)) or spGetUnitIsDead(unitID) then
			returning[unitID] = nil
		else
			local ux, _, uz = spGetUnitPosition(unitID)
			local _, padDistSq = NearestPad(ux, uz)
			if (not padDistSq) or padDistSq <= RETURN_DISTANCE_SQ then
				returning[unitID] = nil
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Ownership callins
--------------------------------------------------------------------------------
function widget:UnitCreated(unitID, unitDefID, unitTeam)
	AddOwned(unitID, unitDefID, unitTeam)
end

function widget:UnitGiven(unitID, unitDefID, newTeam, oldTeam)
	if newTeam == myTeam then
		AddOwned(unitID, unitDefID, newTeam)
	end
end

function widget:UnitTaken(unitID, unitDefID, oldTeam, newTeam)
	if oldTeam == myTeam then
		RemoveOwned(unitID)
	end
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam)
	RemoveOwned(unitID)
	tracked[unitID] = nil
	fleaState[unitID] = nil
end

-- Restore a scouting Flea's states once the player gives it a direct order.
function widget:UnitCommand(unitID, unitDefID, unitTeam, cmdID, cmdParams, cmdOpts)
	if not fleaState[unitID] then
		return
	end
	if cmdOpts and cmdOpts.internal then
		return -- our own orders (the scout move / state changes)
	end
	if RESTORE_CMDS[cmdID] then
		RestoreFlea(unitID)
	end
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------
local function VertexPath()
	for i = 1, #fNodes do
		gl.Vertex(fNodes[i][1], fNodes[i][2], fNodes[i][3])
	end
end

function widget:DrawWorld()
	if not (drawing and options.drawLine.value and #fNodes > 0) then
		return
	end

	gl.DepthTest(false)
	gl.LineWidth(2)
	gl.Color(0.4, 0.8, 1.0, 0.8)
	gl.BeginEnd(GL.LINE_STRIP, VertexPath)

	-- Preview of the resulting points.
	local data = unitData[activeDef]
	if data then
		local points
		if lineLength < CLICK_THRESHOLD or #fNodes < 2 then
			local last = fNodes[#fNodes]
			points = { {last[1], last[2], last[3]} }
		else
			local spacing = data.los * options.spacing.value
			points = GetSpacedPoints(floor(lineLength / spacing) + 1)
		end
		gl.Color(1.0, 1.0, 0.3, 0.6)
		for i = 1, #points do
			local pt = points[i]
			gl.DrawGroundCircle(pt[1], pt[2], pt[3], 40, 16)
		end
	end

	gl.Color(1, 1, 1, 1)
	gl.LineWidth(1)
end

--------------------------------------------------------------------------------
-- Init / teardown
--------------------------------------------------------------------------------
local function RemoveIfSpectator()
	if Spring.GetSpectatingState() and not Spring.IsCheatingEnabled() then
		widgetHandler:RemoveWidget(widget)
	end
end

function widget:PlayerChanged()
	myTeam = Spring.GetMyTeamID()
	myAllyTeam = Spring.GetMyAllyTeamID()
	RescanOwned()
	RebuildRetreatPads()
	RemoveIfSpectator()
end

function widget:Initialize()
	if not (unitData[cmdToDef[CMD_SCOUT_SPARROW] or -1] or unitData[cmdToDef[CMD_SCOUT_SWIFT] or -1]) then
		-- Neither scout type exists in this game; nothing to do.
		widgetHandler:RemoveWidget(widget)
		return
	end
	RescanOwned()
	RebuildRetreatPads()
	RemoveIfSpectator()
end
