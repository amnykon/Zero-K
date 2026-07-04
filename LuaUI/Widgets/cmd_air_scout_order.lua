function widget:GetInfo()
	return {
		name      = "Air Scout Order",
		desc      = "Adds Sparrow and Swift scout commands. Drag to scatter a line of scouts spaced by LOS, or click for a single point. Each point is handed to a different scout, which sprints (Swift) or detonates (Sparrow) once it reaches the point.",
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
options_path = 'Settings/Interface/Air Scout Order'
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

local FRAMES_PER_SECOND = 30
local CLICK_THRESHOLD   = 20    -- drag shorter than this (elmos) counts as a click
local CHECK_INTERVAL    = 3     -- frames between sprint-range checks

-- Custom command IDs (10285/10286 are free; 10283/10284 belong to Newton Firezone).
local CMD_SCOUT_SPARROW = 10285
local CMD_SCOUT_SWIFT   = 10286

--------------------------------------------------------------------------------
-- Per-type data, derived from unit defs
--------------------------------------------------------------------------------
local myTeam = Spring.GetMyTeamID()

-- unitData[unitDefID] = { cmdID, los, sprintRangeSq }
local unitData = {}
local cmdToDef = {}   -- cmdID -> unitDefID

local function BuildTypeData(unitName, cmdID)
	local ud = UnitDefNames[unitName]
	if not ud then
		return
	end
	local cp = ud.customParams or {}
	local boostMult     = tonumber(cp.boost_speed_mult) or 5
	local boostDuration = tonumber(cp.boost_duration) or 30 -- frames
	-- Distance the scout dashes during its boost. Triggering the ability this far
	-- from the point makes the Swift's dash / the Sparrow's detonation land on it.
	local perFrameSpeed = (ud.speed or 0) / FRAMES_PER_SECOND
	local sprintRange   = perFrameSpeed * boostMult * boostDuration
	unitData[ud.id] = {
		cmdID         = cmdID,
		los           = ud.sightDistance or 500,
		sprintRangeSq = sprintRange * sprintRange,
	}
	cmdToDef[cmdID] = ud.id
end

BuildTypeData("planelightscout", CMD_SCOUT_SPARROW) -- Sparrow
BuildTypeData("planefighter",    CMD_SCOUT_SWIFT)   -- Swift

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
	action   = 'airscoutsparrow',
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
	action   = 'airscoutswift',
	texture  = 'LuaUI/Images/commands/Bold/sprint.png',
	disabled = false,
	params   = { },
}

-- Stable order matching the tab column layout (Swift col 1, Sparrow col 2).
local scoutCommands = {
	{cmdID = CMD_SCOUT_SWIFT,   desc = cmdSwift,   defID = cmdToDef[CMD_SCOUT_SWIFT]},
	{cmdID = CMD_SCOUT_SPARROW, desc = cmdSparrow, defID = cmdToDef[CMD_SCOUT_SPARROW]},
}

-- Ownership tracking: a scout command is offered whenever the player owns at
-- least one unit of that type, regardless of the current selection. The command
-- can then dispatch unselected scouts (selected ones are merely prioritised).
local owned = {}       -- unitID -> unitDefID (our types, on my team)
local ownedCount = {}  -- unitDefID -> count

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
end

local function RescanOwned()
	owned = {}
	ownedCount = {}
	local teamUnits = spGetTeamUnits(myTeam)
	for i = 1, #teamUnits do
		AddOwned(teamUnits[i], spGetUnitDefID(teamUnits[i]), myTeam)
	end
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
local tracked = {} -- unitID -> {x, y, z, sprintRangeSq}

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
		if spGetUnitDefID(unitID) == defID and not spGetUnitIsDead(unitID) and IsFullyBuilt(unitID) then
			pool[#pool + 1] = unitID
		end
	end

	local assigned = {}
	local moveOpt = shift and CMD_OPT_SHIFT or 0

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
		spGiveOrderToUnit(bestUnit, CMD_MOVE, {pt[1], pt[2], pt[3]}, moveOpt)
		tracked[bestUnit] = {
			x = pt[1], y = pt[2], z = pt[3],
			sprintRangeSq = data.sprintRangeSq,
		}
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
function widget:GameFrame(frame)
	if frame % CHECK_INTERVAL ~= 0 then
		return
	end
	for unitID, info in pairs(tracked) do
		if (not spValidUnitID(unitID)) or spGetUnitIsDead(unitID) then
			tracked[unitID] = nil
		else
			local ux, _, uz = spGetUnitPosition(unitID)
			local dx, dz = ux - info.x, uz - info.z
			if dx*dx + dz*dz <= info.sprintRangeSq then
				-- Insert the one-click ability at the front of the queue so the
				-- pending move order is preserved (mirrors unit_oneclick_weapon).
				spGiveOrderToUnit(unitID, CMD_INSERT, {0, CMD_ONECLICK, CMD_OPT_INTERNAL, 1}, CMD_OPT_ALT)
				tracked[unitID] = nil
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
	RescanOwned()
	RemoveIfSpectator()
end

function widget:Initialize()
	if not (unitData[cmdToDef[CMD_SCOUT_SPARROW] or -1] or unitData[cmdToDef[CMD_SCOUT_SWIFT] or -1]) then
		-- Neither scout type exists in this game; nothing to do.
		widgetHandler:RemoveWidget(widget)
		return
	end
	RescanOwned()
	RemoveIfSpectator()
end
