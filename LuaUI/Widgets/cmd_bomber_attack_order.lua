function widget:GetInfo()
	return {
		name      = "Bomber Attack Order",
		desc      = "Adds a per-bomber-type area attack command (plus an Odin shield command). Drag a circle; splash bombers spread across the targets inside it, precision bombers focus enough strikes on each target to kill it before moving on.",
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
options_path = 'Settings/Interface/Bomber Attack Order'
options_order = { 'avoidFastTargets', 'minRadius', 'drawCircle' }
options = {
	avoidFastTargets = {
		name = 'Avoid fast targets',
		desc = 'Bombers with slow bombs skip targets too fast to reliably hit (they can dodge the bomb before it lands). Odin restricts to buildings.',
		type = 'bool',
		value = true,
	},
	minRadius = {
		name = 'Minimum circle radius',
		desc = 'A click (or a very short drag) attacks targets within at least this radius.',
		type = 'number',
		value = 96,
		min = 16, max = 400, step = 16,
	},
	drawCircle = {
		name = 'Draw preview circle',
		desc = 'Show the target circle and the units it covers while dragging the order.',
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
local spGetSelectedUnits   = Spring.GetSelectedUnits
local spGetTeamUnits       = Spring.GetTeamUnits
local spGetUnitDefID       = Spring.GetUnitDefID
local spGetUnitPosition    = Spring.GetUnitPosition
local spGetUnitHealth      = Spring.GetUnitHealth
local spGetUnitIsDead      = Spring.GetUnitIsDead
local spGetUnitRulesParam  = Spring.GetUnitRulesParam
local spGetGameFrame       = Spring.GetGameFrame
local spGetUnitAllyTeam    = Spring.GetUnitAllyTeam
local spGetUnitNeutral     = Spring.GetUnitNeutral
local spGetUnitsInCylinder = Spring.GetUnitsInCylinder
local spGiveOrderToUnit    = Spring.GiveOrderToUnit
local spIsAboveMiniMap     = Spring.IsAboveMiniMap

local sqrt  = math.sqrt
local ceil  = math.ceil
local max   = math.max

local CMD_ATTACK          = CMD.ATTACK
local CMD_OPT_SHIFT       = CMD.OPT_SHIFT
local CMD_AIR_MANUAL_FIRE = CMD_AIR_MANUALFIRE -- from customcmds.h.lua

--------------------------------------------------------------------------------
-- Per-command data
--------------------------------------------------------------------------------
-- splash bombers spread one strike per target; precision (non-splash) bombers
-- pile enough strikes on each target to kill it. damage is per bomber strike and
-- is only used by the precision path.
--
-- maxTargetSpeed (elmos/s) is the fastest unit the bomber can reliably hit,
-- enforced only when the "avoid fast targets" option is on. It reflects bomb
-- flight time vs. the target's speed: slow unguided bombs get a low cap, homing
-- or near-instant weapons a high one, and Odin's very slow zeppelin bomb is
-- pinned to buildings only (0). nil means no limit.
--
-- Odin appears twice: its bombs (precision, buildings only) and its shield dgun,
-- which is splash and fired at the ground (CMD_AIR_MANUALFIRE on weapon 3).
local bomberDefList = {
	{cmdID = 10287, unitName = "bomberriot",    splash = true,  damage = 0,    manualFire = false, targetGround = false, maxTargetSpeed = 75},  -- Phoenix (napalm)
	{cmdID = 10288, unitName = "bomberheavy",   splash = true,  damage = 2000, manualFire = false, targetGround = false, maxTargetSpeed = 150}, -- Likho (homing)
	{cmdID = 10289, unitName = "bomberdisarm",  splash = true,  damage = 0,    manualFire = false, targetGround = false, maxTargetSpeed = 150}, -- Thunderbird (beam)
	{cmdID = 10290, unitName = "bomberassault", splash = false, damage = 2500, manualFire = false, targetGround = false, maxTargetSpeed = 0},   -- Odin bombs (buildings only)
	{cmdID = 10291, unitName = "bomberassault", splash = true,  damage = 0,    manualFire = true,  targetGround = true,  maxTargetSpeed = nil}, -- Odin shield dgun
	{cmdID = 10292, unitName = "bomberstrike",  splash = false, damage = 180,  manualFire = false, targetGround = false, maxTargetSpeed = 150}, -- Magpie (homing)
	{cmdID = 10293, unitName = "bomberprec",    splash = false, damage = 800,  manualFire = false, targetGround = false, maxTargetSpeed = 90},  -- Raven (precision)
}

local myTeam    = Spring.GetMyTeamID()
local myAllyTeam = Spring.GetMyAllyTeamID()

-- The set of target categories the bomber's aiming weapon (weapon 1, as ZK's
-- bomber targeting uses) can engage. nil means no restriction.
local function BuildTargetCats(ud)
	local weapon = ud.weapons and ud.weapons[1]
	local onlyTargets = weapon and weapon.onlyTargets
	if not onlyTargets then
		return nil
	end
	local cats, any = {}, false
	for name, allowed in pairs(onlyTargets) do
		if allowed then
			cats[name] = true
			any = true
		end
	end
	return any and cats or nil
end

-- cmdData[cmdID] = { defID, splash, damage, attackCmdID, targetGround, maxTargetSpeed, targetCats }
local cmdData = {}
local watchedDefs = {} -- unitDefID -> true (all bomber types we care about)

for _, entry in ipairs(bomberDefList) do
	local ud = UnitDefNames[entry.unitName]
	if ud then
		cmdData[entry.cmdID] = {
			defID          = ud.id,
			splash         = entry.splash,
			damage         = entry.damage,
			attackCmdID    = entry.manualFire and CMD_AIR_MANUAL_FIRE or CMD_ATTACK,
			targetGround   = entry.targetGround,
			maxTargetSpeed = entry.maxTargetSpeed,
			targetCats     = BuildTargetCats(ud),
		}
		watchedDefs[ud.id] = true
	end
end

--------------------------------------------------------------------------------
-- Command descriptors (placement/icon/tooltip come from integral_menu_config)
--------------------------------------------------------------------------------
-- Ordered list mirroring the scout widget so Update can refresh counts/badges.
local bomberCommands = {}
for _, entry in ipairs(bomberDefList) do
	if cmdData[entry.cmdID] then
		bomberCommands[#bomberCommands + 1] = {
			cmdID = entry.cmdID,
			defID = cmdData[entry.cmdID].defID,
			desc  = {
				id       = entry.cmdID,
				type     = CMDTYPE.ICON_MAP,
				name     = "",
				tooltip  = "Bomber attack run.",
				cursor   = 'Attack',
				action   = "bomberrun_" .. entry.cmdID,
				texture  = 'LuaUI/Images/commands/Bold/attack.png', -- overridden by commandDisplayConfig's unit icon
				disabled = false,
				params   = { },
			},
		}
	end
end

--------------------------------------------------------------------------------
-- Ownership tracking (drives the tab count, like the scout/missile widgets)
--------------------------------------------------------------------------------
local owned = {}       -- unitID -> unitDefID
local ownedCount = {}  -- unitDefID -> count

-- A bomber that has been sent on a run stays committed until it rearms.
local REASSIGN_LOCK_FRAMES = 150 -- ~5s; bridges the gap before noammo updates
local assignLock = {}            -- unitID -> game frame until which it stays committed

local function AddOwned(unitID, unitDefID, unitTeam)
	if unitTeam == myTeam and watchedDefs[unitDefID] and not owned[unitID] then
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

function widget:UnitDestroyed(unitID)
	RemoveOwned(unitID)
	assignLock[unitID] = nil
end

--------------------------------------------------------------------------------
-- Tab registration and count badge (selection-independent, like the scout tab)
--------------------------------------------------------------------------------
function widget:CommandsChanged()
	local customCommands = widgetHandler.customCommands
	for i = 1, #bomberCommands do
		local bc = bomberCommands[i]
		if (ownedCount[bc.defID] or 0) > 0 then
			customCommands[#customCommands + 1] = bc.desc
		end
	end
end

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
	for i = 1, #bomberCommands do
		local bc = bomberCommands[i]
		local count = ownedCount[bc.defID] or 0
		local displayName = (count > 0) and ("x" .. count) or ""
		local disabled = (count == 0)
		if bc.desc.name ~= displayName or bc.desc.disabled ~= disabled then
			bc.desc.name = displayName
			bc.desc.disabled = disabled
			changed = true
		end
		if count > 0 then
			activeIcons[#activeIcons + 1] = {icon = "#" .. bc.defID, count = count, progress = 0}
		end
	end
	WG.bomberActiveIcons = activeIcons

	local emptySelection = (Spring.GetSelectedUnitsCount() == 0)
	if changed or (emptySelection and not wasEmptySelection) then
		Spring.ForceLayoutUpdate()
	end
	wasEmptySelection = emptySelection
end

--------------------------------------------------------------------------------
-- Target gathering and unit assignment
--------------------------------------------------------------------------------
local function IsFullyBuilt(unitID)
	local _, _, _, _, buildProgress = spGetUnitHealth(unitID)
	return buildProgress and buildProgress >= 1
end

-- True if the target moves too fast for this bomber's bombs to land on it.
-- Buildings (speed 0) always pass; radar-only targets of unknown type are kept.
local function TargetTooFast(unitID, maxTargetSpeed)
	if not maxTargetSpeed then
		return false
	end
	local unitDefID = spGetUnitDefID(unitID)
	if not unitDefID then
		return false
	end
	local ud = UnitDefs[unitDefID]
	local speed = (ud and ud.speed) or 0
	return speed > maxTargetSpeed
end

-- True if the bomber's weapon cannot engage this target's categories.
-- Unknown radar targets and unrestricted weapons always pass.
local function CannotTarget(unitID, targetCats)
	if not targetCats then
		return false
	end
	local unitDefID = spGetUnitDefID(unitID)
	if not unitDefID then
		return false
	end
	local springCats = UnitDefs[unitDefID] and UnitDefs[unitDefID].springCategories
	if not springCats then
		return false
	end
	for name in pairs(targetCats) do
		if springCats[name] then
			return false
		end
	end
	return true
end

-- Enemy (non-neutral) units inside the circle, as {id, x, z}, nearest-first.
-- maxTargetSpeed drops targets too fast to hit; targetCats drops targets the
-- bomber's weapon cannot engage (e.g. enemy aircraft for ground bombers).
local function GatherTargets(cx, cz, radius, maxTargetSpeed, targetCats)
	local raw = spGetUnitsInCylinder(cx, cz, radius)
	local targets = {}
	for i = 1, #raw do
		local unitID = raw[i]
		if spGetUnitAllyTeam(unitID) ~= myAllyTeam and not spGetUnitNeutral(unitID)
				and not TargetTooFast(unitID, maxTargetSpeed)
				and not CannotTarget(unitID, targetCats) then
			local ux, _, uz = spGetUnitPosition(unitID)
			if ux then
				local dx, dz = ux - cx, uz - cz
				targets[#targets + 1] = {id = unitID, x = ux, z = uz, distSq = dx*dx + dz*dz}
			end
		end
	end
	table.sort(targets, function(a, b) return a.distSq < b.distSq end)
	return targets
end

-- The speed cap in force for a command right now (nil when the option is off).
local function ActiveMaxSpeed(data)
	return options.avoidFastTargets.value and data.maxTargetSpeed or nil
end

-- A bomber that has been sent on a run is unavailable until it has rearmed.
-- noammo ~= 0 means it is out of ammo / refuelling / repairing. assignLock
-- (declared above) bridges the gap between being ordered and actually dropping.
local function IsAvailable(unitID)
	if (spGetUnitRulesParam(unitID, "noammo") or 0) ~= 0 then
		return false
	end
	local lock = assignLock[unitID]
	if lock and spGetGameFrame() < lock then
		return false
	end
	return true
end

-- Fully-built, living, rearmed bombers of this type, plus the selected set.
local function GatherBombers(defID)
	local pool = {}
	for unitID, unitDefID in pairs(owned) do
		if unitDefID == defID and not spGetUnitIsDead(unitID) and IsFullyBuilt(unitID)
				and IsAvailable(unitID) then
			pool[#pool + 1] = unitID
		end
	end
	local selectedSet = {}
	local selected = spGetSelectedUnits()
	for i = 1, #selected do
		if spGetUnitDefID(selected[i]) == defID then
			selectedSet[selected[i]] = true
		end
	end
	return pool, selectedSet
end

-- Pick the best unassigned bomber for a point: selected first, then closest.
local function TakeBomber(pool, assigned, selectedSet, tx, tz)
	local bestUnit, bestTier, bestDistSq
	for i = 1, #pool do
		local unitID = pool[i]
		if not assigned[unitID] then
			local tier = selectedSet[unitID] and 0 or 1
			local ux, _, uz = spGetUnitPosition(unitID)
			local dx, dz = ux - tx, uz - tz
			local distSq = dx*dx + dz*dz
			if (not bestUnit) or tier < bestTier or (tier == bestTier and distSq < bestDistSq) then
				bestUnit, bestTier, bestDistSq = unitID, tier, distSq
			end
		end
	end
	if bestUnit then
		assigned[bestUnit] = true
	end
	return bestUnit
end

-- Strikes needed to kill a target with a given per-strike damage. Falls back to
-- one strike when the target's health is not visible (radar-only) or unknown.
local function StrikesToKill(targetID, damage)
	if damage <= 0 then
		return 1
	end
	local health = spGetUnitHealth(targetID)
	if not health then
		return 1
	end
	return max(1, ceil(health / damage))
end

local function Dispatch(cmdID, cx, cz, radius, shift)
	local data = cmdData[cmdID]
	if not data then
		return
	end

	local targets = GatherTargets(cx, cz, radius, ActiveMaxSpeed(data), data.targetCats)
	if #targets == 0 then
		return
	end
	local pool, selectedSet = GatherBombers(data.defID)
	if #pool == 0 then
		return
	end

	local assigned = {}
	local opt = shift and CMD_OPT_SHIFT or 0
	local attackCmdID = data.attackCmdID
	local lockUntil = spGetGameFrame() + REASSIGN_LOCK_FRAMES

	-- Ground-targeting commands (Odin's shield dgun) fire at the target's
	-- position; the rest attack the unit directly.
	local function OrderAt(t)
		if data.targetGround then
			return {t.x, max(0, spGetGroundHeight(t.x, t.z)), t.z}
		end
		return {t.id}
	end

	local function Fire(bomber, t)
		spGiveOrderToUnit(bomber, attackCmdID, OrderAt(t), opt)
		assignLock[bomber] = lockUntil
	end

	if data.splash then
		-- One strike per target, spread across the circle, using the nearest
		-- bomber for each, until targets or bombers run out.
		for i = 1, #targets do
			local t = targets[i]
			local bomber = TakeBomber(pool, assigned, selectedSet, t.x, t.z)
			if not bomber then
				break
			end
			Fire(bomber, t)
		end
	else
		-- Focus fire: commit enough bombers to kill each target before moving on.
		for i = 1, #targets do
			local t = targets[i]
			local need = StrikesToKill(t.id, data.damage)
			local exhausted = false
			for _ = 1, need do
				local bomber = TakeBomber(pool, assigned, selectedSet, t.x, t.z)
				if not bomber then
					exhausted = true
					break
				end
				Fire(bomber, t)
			end
			if exhausted then
				break
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Circle drag
--------------------------------------------------------------------------------
local drawing    = false
local activeCmd  = nil
local centerX, centerY, centerZ = 0, 0, 0
local curRadius  = 0

local function ResetDrag()
	drawing = false
	activeCmd = nil
	curRadius = 0
end

local function GetActiveBomberCmd()
	local _, activeCmdID = spGetActiveCommand()
	return activeCmdID and cmdData[activeCmdID] and activeCmdID or nil
end

local function UpdateRadius(mx, my)
	local _, pos = spTraceScreenRay(mx, my, true)
	if pos then
		local dx, dz = pos[1] - centerX, pos[3] - centerZ
		curRadius = sqrt(dx*dx + dz*dz)
	end
end

function widget:MousePress(mx, my, button)
	if spIsAboveMiniMap(mx, my) then
		return false
	end
	if drawing then
		if button == 3 then
			ResetDrag()
			return true
		end
		return true
	end

	local cmdID = GetActiveBomberCmd()
	if not cmdID or button ~= 1 then
		return false
	end

	local _, pos = spTraceScreenRay(mx, my, true)
	if not pos then
		return false
	end

	drawing = true
	activeCmd = cmdID
	centerX, centerY, centerZ = pos[1], pos[2], pos[3]
	curRadius = 0
	return true
end

function widget:MouseMove(mx, my, dx, dy, button)
	if not drawing then
		return false
	end
	UpdateRadius(mx, my)
	return true
end

function widget:MouseRelease(mx, my, button)
	if not drawing then
		return false
	end
	if button == 1 then
		UpdateRadius(mx, my)
		local radius = max(curRadius, options.minRadius.value)
		local _, _, _, shift = Spring.GetModKeyState()
		Dispatch(activeCmd, centerX, centerZ, radius, shift)
		ResetDrag()
		if not shift then
			Spring.SetActiveCommand(nil)
		end
	end
	return true
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------
function widget:DrawWorld()
	if not (drawing and options.drawCircle.value) then
		return
	end
	local radius = max(curRadius, options.minRadius.value)

	gl.DepthTest(false)
	gl.LineWidth(2)
	gl.Color(1.0, 0.3, 0.2, 0.85)
	gl.DrawGroundCircle(centerX, centerY, centerZ, radius, 48)

	-- Mark the enemy targets that would actually be engaged.
	local data = cmdData[activeCmd]
	local targets = GatherTargets(centerX, centerZ, radius,
		data and ActiveMaxSpeed(data) or nil, data and data.targetCats or nil)
	gl.Color(1.0, 0.8, 0.2, 0.7)
	for i = 1, #targets do
		local t = targets[i]
		gl.DrawGroundCircle(t.x, max(0, spGetGroundHeight(t.x, t.z)), t.z, 24, 12)
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
	RemoveIfSpectator()
end

function widget:Initialize()
	if not next(cmdData) then
		widgetHandler:RemoveWidget(widget)
		return
	end
	RescanOwned()
	RemoveIfSpectator()
end
