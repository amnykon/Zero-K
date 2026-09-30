--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--
--  file:    unit_global_build_command.lua
--  brief:   Start of a new Global Build Command. While GBC mode is on, every
--           build/repair/reclaim/resurrect order you give is queued into
--           WG.GlobalBuildListShare (gui_global_build_list.lua)
--           instead of being handed to the selected units, so you can keep
--           an army selected and still queue jobs for your constructors.
--           Constructors join or leave GBC with the Global Build state
--           button (on by default), and the worker AI assigns them to your
--           and your allies' jobs by cost (see the Worker AI section;
--           costs are under Settings/Unit Behaviour/Worker AI/Costs, shown
--           only with advanced settings).
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
--  engine's normal command path are seen - plus mex and area mex placement,
--  energy grid placement (cmd_energy_grid.lua, through QueueBuild/QueueRepair),
--  and terraform (lasso terraform, building on raised or lowered ground),
--  which those widgets offer to WG.GlobalBuildCommand first. Terraform
--  becomes repair jobs on the terraform gadget's "terraunits".
--
--  Job identity is derived by Update() itself from the job's own content
--  (see gui_global_build_list.lua's BuildJobHash) - this widget never
--  computes a hash itself, and reads its own jobs back from the store rather
--  than keeping a list of them. Placing the same building at the same spot
--  again naturally updates that same job rather than queuing a duplicate,
--  since it hashes to the same jobId both times.
--
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

function widget:GetInfo()
	return {
		name      = "Global Build Command v2",
		desc      = "Start of a new Global Build Command: while toggled on (Tab by default), build/repair/reclaim/resurrect orders are queued into WG.GlobalBuildListShare instead of given to the selected units.",
		author    = "amnykon",
		date      = "September 26, 2026",
		license   = "GNU GPL, v2 or later",
		layer     = 1001, -- CommandNotify runs from the highest layer down, so this sees orders before most other widgets
		handler   = true, -- CommandsChanged needs widgetHandler.customCommands and widgetHandler.commands
		enabled   = true,
	}
end

include("keysym.lua")
VFS.Include("LuaRules/Configs/customcmds.h.lua")
VFS.Include("LuaUI/Configs/widgets_only_cmds.lua", nil, VFS.RAW_FIRST) -- widgets-only build: command IDs official releases lack
VFS.Include("LuaRules/Configs/constants.lua") -- HIDDEN_STORAGE

local spGetMouseState     = Spring.GetMouseState
local spGetGroundHeight   = Spring.GetGroundHeight
local spGetUnitPosition   = Spring.GetUnitPosition
local spEcho              = Spring.Echo
local spGetMyTeamID       = Spring.GetMyTeamID
local spGetSpectatingState = Spring.GetSpectatingState
local spGetTeamUnits      = Spring.GetTeamUnits
local spGetUnitDefID      = Spring.GetUnitDefID
local spGetSelectedUnits  = Spring.GetSelectedUnits
local spGetUnitTeam       = Spring.GetUnitTeam
local spGetUnitRulesParam = Spring.GetUnitRulesParam
local spGiveOrderToUnit   = Spring.GiveOrderToUnit
local spGetUnitCurrentCommand = Spring.GetUnitCurrentCommand
local spFindUnitCmdDesc   = Spring.FindUnitCmdDesc
local spGetUnitHealth     = Spring.GetUnitHealth
local spGetUnitIsDead     = Spring.GetUnitIsDead
local spGetUnitIsStunned  = Spring.GetUnitIsStunned
local spValidUnitID       = Spring.ValidUnitID
local spValidFeatureID    = Spring.ValidFeatureID
local spTestBuildOrder    = Spring.TestBuildOrder
local spGetGameFrame      = Spring.GetGameFrame
local spAreTeamsAllied    = Spring.AreTeamsAllied
local spGetTeamResources  = Spring.GetTeamResources
local spGetUnitIsBuilding = Spring.GetUnitIsBuilding
local spGetUnitsInCylinder = Spring.GetUnitsInCylinder
local spIsUnitAllied      = Spring.IsUnitAllied

local CMD_REPAIR    = CMD.REPAIR
local CMD_RECLAIM   = CMD.RECLAIM
local CMD_RESURRECT = CMD.RESURRECT
local CMD_GUARD     = CMD.GUARD
-- The walk to a job cmd_raw_move.lua puts in front of a constructor's order
-- while it's out of range.
local CMD_RAW_BUILD = Spring.Utilities.CMD.RAW_BUILD

local sqrt  = math.sqrt

local function DistanceSq(x1, z1, x2, z2)
	return (x1 - x2) * (x1 - x2) + (z1 - z2) * (z1 - z2)
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local active = false -- GBC mode on/off, toggled by the toggle hotkey

local dragX, dragZ, dragR -- in-progress right-drag for area removal
local dragScreenX, dragScreenY -- where that right-press was on screen, to tell a click from a drag

-- A right-press that moves less than this (in pixels) is a click, which
-- closes GBC mode, rather than a drag, which removes jobs.
local CLICK_MAX_MOVE_SQ = 8*8

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

-- Worker AI assignments (see the Worker AI section). assignment[unitID] is the
-- key ("<ownerPlayerID>#<jobId>") of the job the worker is on, assignedCmd the
-- command we gave it for it and assignedFrame when, so we can tell when the
-- player (or anything else) gives it other orders.
local assignment = {}
local assignedCmd = {}
local assignedFrame = {}
-- ourCount[key] = how many of our workers are on that job, as reported to the
-- job store with Assist().
local ourCount = {}
-- baseCosts[key] = that job's JobBaseCost() for a worker not on it, while
-- UpdateWorkers runs, or nil outside it. Cleared for a job when its ourCount
-- changes, since its crowd changes with it.
local baseCosts
-- failedUntil[unitID][key] = game frame until which that worker won't retry a
-- job it went idle on without finishing (eg. couldn't reach it).
local failedUntil = {}
-- assignedSide[unitID] = "econ" or "units" for a worker on an economy job or
-- helping a factory, for the economy/units split.
local assignedSide = {}
-- assignedProduces[unitID] = "metal", "energy" or "production" for a worker
-- on a job building one (for the economy log).
local assignedProduces = {}
local Unassign -- defined in the Worker AI section
local RestoreAllPriorities -- defined in the Worker AI section

-- Our factories (the managed team's), for the economy/units split.
local factories = {}

-- Terraform. Terraform orders are carried out by repairing "terraunits",
-- markers the terraform gadget (unit_terraform.lua) creates on the ground and
-- removes once done. While GBC mode is on, GBC takes terraform orders from
-- gui_lasso_terraform.lua and gui_persistent_build_height.lua (see
-- WG.GlobalBuildCommand below), and our terraunits created within
-- TERRAFORM_CAPTURE_FRAMES after become repair jobs.
local terraunitDefID = UnitDefNames.terraunit and UnitDefNames.terraunit.id
local TERRAFORM_CAPTURE_FRAMES = 90
local captureTerraformUntil = -1
-- alliedTerraunits[unitID] = {x, z}: every allied terraunit, so a build job
-- waiting on terraform (raise-and-build) isn't taken or removed as blocked
-- until the ground is done.
local alliedTerraunits = {}

-- Whether terraform is still going on within radius of a spot.
local function TerraformPendingAt(x, z, radius)
	local rSq = radius * radius
	for _, pos in pairs(alliedTerraunits) do
		if DistanceSq(x, z, pos[1], pos[2]) <= rSq then
			return true
		end
	end
	return false
end

-- How far from a building's centre terraform for it can be.
local function TerraformRadius(unitDef)
	return math.max(unitDef.xsize or 0, unitDef.zsize or 0) * 8 + 32
end

local function IsNanoframe(unitID)
	local _, _, beingBuilt = spGetUnitIsStunned(unitID)
	return beingBuilt
end

--------------------------------------------------------------------------------
-- Buildings at a height, and walls
--------------------------------------------------------------------------------
-- A build job can say to build the building at an elevation (an absolute
-- height: a spire, or a hole such as a buried mex) and/or with a wall around
-- it (a height above its base). The job only says what's wanted; the
-- terraform is worked out here, when a worker gets to it:
--   - elevation: level the building's footprint to that height, before
--     building (as persistent build height does).
--   - wall: once the building stands, raise-only the square twice its
--     footprint to base + wall height (as area mex does); the terraform
--     gadget leaves the ground under a building alone, so that makes a ring.
-- Whether terraform is still needed is read from the ground each time, so
-- nothing needs remembering: a wall around an existing building works, and it
-- survives a reload. Terraform is started through the terraform gadget like
-- the terraform widgets do (CMD_TERRAFORM_INTERNAL, then CMD_LEVEL with the
-- same tag, which sends the worker to repair that terraform's terraunits).

local TERRAFORM_TOLERANCE = 4
-- After starting a job's terraform, how long to wait for its terraunits to
-- appear before starting it again.
local TERRAFORM_ISSUE_WAIT = 90
-- terraformIssued[key] = {tag, frame}: terraform we started for a job, so our
-- other workers can join it by tag.
local terraformIssued = {}
local ownTerraformTag = 1000000

local function NextTerraformTag()
	if WG.Terraform_GetNextTag then
		return WG.Terraform_GetNextTag()
	end
	ownTerraformTag = ownTerraformTag + 1
	return ownTerraformTag
end

-- Half-size of a building's footprint, as persistent build height uses.
local function FootprintHalf(unitDef, facing)
	local hx, hz = (unitDef.xsize or 0) * 4, (unitDef.zsize or 0) * 4
	if facing == 1 or facing == 3 then
		hx, hz = hz, hx
	end
	return hx - 0.1, hz - 0.1
end

-- The finished building of this type standing at a spot, if any (ours or an
-- ally's).
local function ExistingBuildingAt(unitDefID, x, z)
	local units = spGetUnitsInCylinder(x, z, 24)
	if units then
		for i = 1, #units do
			local unitID = units[i]
			if spGetUnitDefID(unitID) == unitDefID and spIsUnitAllied(unitID) and not IsNanoframe(unitID) then
				return unitID
			end
		end
	end
	return nil
end

-- Whether the ground under a building's footprint isn't yet level at the
-- elevation: its centre or any corner is off. The centre alone misses a slope
-- levelled to the height it has in the middle (as the energy grid asks for).
local function ElevationNeeded(unitDef, x, z, facing, elevation)
	-- A heightmap square in from the edge: right at the edge, the height is
	-- blended with the unlevelled ground outside.
	local fx, fz = FootprintHalf(unitDef, facing)
	fx, fz = math.max(0, fx - 8), math.max(0, fz - 8)
	local function off(px, pz)
		return math.abs(spGetGroundHeight(px, pz) - elevation) > TERRAFORM_TOLERANCE
	end
	return off(x, z) or off(x + fx, z + fz) or off(x + fx, z - fz)
		or off(x - fx, z + fz) or off(x - fx, z - fz)
end

-- The height a wall should reach, from the building's base.
local function WallTop(x, z, wall)
	return math.max(math.max(spGetGroundHeight(x, z), 0) + wall, 0)
end

local function WallNeeded(unitDef, x, z, facing, wall)
	local fx, fz = FootprintHalf(unitDef, facing)
	local top = WallTop(x, z, wall)
	-- Sample halfway between the building's edge and the wall's edge.
	local dx, dz = fx * 1.5, fz * 1.5
	return spGetGroundHeight(x + dx, z) < top - TERRAFORM_TOLERANCE
		or spGetGroundHeight(x - dx, z) < top - TERRAFORM_TOLERANCE
		or spGetGroundHeight(x, z + dz) < top - TERRAFORM_TOLERANCE
		or spGetGroundHeight(x, z - dz) < top - TERRAFORM_TOLERANCE
end

-- The allied terraunit nearest a spot, within radius, if any.
local function NearestTerraunit(x, z, radius)
	local best, bestSq
	local rSq = radius * radius
	for unitID, pos in pairs(alliedTerraunits) do
		local dSq = DistanceSq(x, z, pos[1], pos[2])
		if dSq <= rSq and (not bestSq or dSq < bestSq) then
			best, bestSq = unitID, dSq
		end
	end
	return best
end

-- Starts a build job's terraform (job.phase "elevate" or "wall") with this
-- worker, and sends the worker to it.
local function StartTerraform(unitID, job, frame)
	local unitDef = UnitDefs[-job.cmd]
	local fx, fz = FootprintHalf(unitDef, job.h)
	local hx, hz, height, volume
	if job.phase == "elevate" then
		hx, hz, height, volume = fx, fz, job.elevation, 0 -- raise or lower
	else
		hx, hz, height, volume = fx * 2, fz * 2, WallTop(job.x, job.z, job.wall), 1 -- raise only
	end
	local tag = NextTerraformTag()
	local x, z = job.x, job.z
	local params = {
		1,                -- terraform type: level
		spGetUnitTeam(unitID),
		x, z,
		tag,
		1,                -- loop
		height,
		5,                -- points
		1,                -- constructors
		volume,
		x + hx, z + hz, x + hx, z - hz, x - hx, z - hz, x - hx, z + hz, x + hx, z + hz,
		unitID,
	}
	spGiveOrderToUnit(unitID, CMD_TERRAFORM_INTERNAL, params, 0)
	spGiveOrderToUnit(unitID, CMD_LEVEL, {x, spGetGroundHeight(x, z), z, tag}, 0)
	terraformIssued[job.key] = {tag, frame}
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function mousePos()
	local mx, my = spGetMouseState()
	local _, pos = Spring.TraceScreenRay(mx, my, true)
	if pos then
		return pos[1], pos[3]
	end
end

local function StopDrag()
	dragX, dragZ, dragR = nil, nil, nil
	dragScreenX, dragScreenY = nil, nil
end

local function SetActive(on)
	active = on
	StopDrag()
	Spring.ForceLayoutUpdate() -- re-run CommandsChanged, to show/hide Global Build Cancel
	spEcho("GBC mode: " .. (active and "ON (orders are queued as GBC jobs, right-drag to remove, right-click or Esc to close)" or "OFF"))
end

-- Close GBC mode and drop any armed command with it, like closing the missile
-- launcher, so the next click doesn't place an ordinary order by surprise.
local function Dismiss()
	if Spring.GetActiveCommand() then
		Spring.SetActiveCommand(nil)
	end
	SetActive(false)
end

--------------------------------------------------------------------------------
-- Options
--------------------------------------------------------------------------------

-- Assigning workers to jobs: released by the workerAI option, defined in the
-- Worker AI section below.
local ReleaseAllWorkers

local COSTS_PATH = 'Settings/Unit Behaviour/Worker AI/Costs'

-- A cost setting, in seconds - see the Worker AI section for how costs work.
local function CostOption(name, desc, value, maxValue)
	return {
		name = name,
		desc = desc,
		type = 'number',
		min = 0, max = maxValue or 60, step = 0.5,
		value = value,
		path = COSTS_PATH,
	}
end

options_path = 'Settings/Unit Behaviour/Worker AI'
options_order = {
	'toggle', 'workerAI', 'updateRate',
	'switchCost', 'travelWeight',
	'targetFinishTime', 'minPreferred', 'maxPreferred', 'areaPreferred',
	'shortHandedBonus', 'overStaffedCost',
	'largeMinMetal', 'completionWeight', 'completionMinProgress', 'largeConcurrentCost',
	'highMetalFrom', 'repairHighMetalCost',
	'lowMetalBelow', 'reclaimHighMetalCost', 'reclaimLowMetalBonus',
	'lowEnergyBelow', 'repairLowEnergyCost', 'resurrectLowEnergyCost',
	'allyJobCost', 'waitingBonusPerMinute', 'waitingBonusMax', 'commanderTravelFactor',
	'metalNeedBonus', 'energyNeedBonus', 'incomeBalanceBand', 'productionNeedBonus',
	'assistFactories', 'factoryFallback', 'factoryFallbackCost', 'econShare', 'splitWeight', 'factoryAssistPreferred', 'factoryAssistCost', 'factoryAssistLowMetalCost',
	'backupReclaim', 'backupReclaimCost', 'steerPriority',
	'dangerRadius', 'dangerPenalty', 'dangerRadarDotMetal',
	'autoCaretakers', 'autoCaretakersIdleFactories', 'maxCaretakersPerFactory', 'caretakerNeedBonus',
	'lowPriorityCost', 'highPriorityDiscount',
	'debugCosts', 'debugDanger', 'debugEconLog', 'debugWorkerLog',
}
options = {
	workerAI = {
		name = 'GBC Worker AI',
		desc = 'Assign GBC workers (constructors with Global Build on) to queued GBC jobs, yours and your allies\'.',
		type = 'bool',
		value = true,
		noHotkey = true,
		OnChange = function(self)
			if not self.value and ReleaseAllWorkers then
				ReleaseAllWorkers()
			end
		end,
	},
	updateRate = {
		name = 'Worker AI update interval (seconds)',
		desc = 'How often idle and GBC workers are (re)assigned. Lower reacts faster but costs more CPU.',
		type = 'number',
		min = 0.25, max = 5, step = 0.25,
		value = 1,
	},

	-- Costs, all in seconds. A worker takes the job with the lowest cost: its
	-- travel time to the job plus these kickers.
	switchCost = CostOption('Switch cost',
		'Extra cost of pulling a worker off the job it is on: it only switches if another job is cheaper by more than this.', 5),
	travelWeight = {
		name = 'Travel time weight',
		desc = 'How much each second of a worker\'s travel time to a job counts against the other costs. Lower lets the other costs (need, priority, crowding) pick further-off jobs; 1 counts travel time in full.',
		type = 'number', min = 0.1, max = 2, step = 0.05, value = 0.5,
		path = COSTS_PATH,
	},
	targetFinishTime = {
		name = 'Target finish time (seconds)',
		desc = 'Sets each job\'s preferred worker count: enough average GBC workers to build it in about this long. A building\'s count is fixed for its whole build; repair uses the target\'s build time.',
		type = 'number', min = 5, max = 300, step = 5, value = 30,
		path = COSTS_PATH,
	},
	minPreferred = {
		name = 'Preferred workers: minimum',
		desc = 'The smallest preferred worker count any job gets.',
		type = 'number', min = 1, max = 20, step = 1, value = 1,
		path = COSTS_PATH,
	},
	maxPreferred = {
		name = 'Preferred workers: maximum',
		desc = 'The largest preferred worker count any job gets.',
		type = 'number', min = 1, max = 60, step = 1, value = 10,
		path = COSTS_PATH,
	},
	areaPreferred = {
		name = 'Preferred workers: area, reclaim and resurrect jobs',
		desc = 'Preferred worker count for jobs whose amount of work isn\'t known up front.',
		type = 'number', min = 1, max = 20, step = 1, value = 2,
		path = COSTS_PATH,
	},
	shortHandedBonus = CostOption('Short-handed bonus per missing worker',
		'Taken off a started job\'s cost for each worker it is short of its preferred count, so crews fill started jobs before new ones are started. A job counts as started once it has a unit or a worker on it.', 2),
	overStaffedCost = CostOption('Over-staffed cost per extra worker',
		'Added to a job\'s cost for each worker beyond its preferred count. For large projects past the completion bonus threshold it fades with build progress.', 10),
	largeMinMetal = {
		name = 'Large project: from (metal)',
		desc = 'Jobs costing at least this much metal are large projects: they get the completion bonus, and their over-staffed cost fades as they near completion.',
		type = 'number', min = 0, max = 10000, step = 50, value = 1000,
		path = COSTS_PATH,
	},
	largeConcurrentCost = CostOption('Large project: cost of starting another',
		'Added to starting a large project (see Large project: from) for each large project already in progress, so they are finished one at a time rather than several at once. Your own is in progress once it has a nanoframe or a worker on it; an ally\'s only while your workers are on it (so joining one counts as starting it), as only then is it spending your metal.', 30, 120),
	completionWeight = CostOption('Large project: completion bonus',
		'Taken off a large project\'s cost, scaled by its build progress, so nearly finished ones pull workers in to finish them.', 20),
	completionMinProgress = {
		name = 'Large project: completion bonus from',
		desc = 'Build progress (0 to 1) a large project needs before the completion bonus applies and its over-staffed cost starts fading.',
		type = 'number', min = 0, max = 1, step = 0.05, value = 0.5,
		path = COSTS_PATH,
	},
	highMetalFrom = {
		name = 'High metal: from (share of storage)',
		desc = 'Metal counts as high from this share of your metal storage (0 to 1), rising to fully high when storage is full - scaled down while build power wants more metal than comes in, so metal being spent down doesn\'t count.',
		type = 'number', min = 0, max = 1, step = 0.05, value = 0.5,
		path = COSTS_PATH,
	},
	repairHighMetalCost = CostOption('Repair cost when metal is high',
		'Added to repair jobs, scaled by how high metal is. Repair costs energy but no metal, so when metal is piling up, build power is better spent building.', 20),
	lowMetalBelow = {
		name = 'Low metal: below (share of storage)',
		desc = 'Metal counts as low below this share of your metal storage (0 to 1), rising to fully low when storage is empty.',
		type = 'number', min = 0, max = 1, step = 0.05, value = 0.2,
		path = COSTS_PATH,
	},
	reclaimHighMetalCost = CostOption('Reclaim cost when metal is high',
		'Added to reclaim jobs, scaled by how high metal is: reclaimed metal is wasted once storage is full.', 20),
	reclaimLowMetalBonus = CostOption('Reclaim bonus when metal is low',
		'Taken off reclaim jobs, scaled by how low metal is: reclaim is free metal.', 10),
	lowEnergyBelow = {
		name = 'Low energy: below (share of storage)',
		desc = 'Energy counts as low below this share of your energy storage (0 to 1), rising to fully low when storage is empty.',
		type = 'number', min = 0, max = 1, step = 0.05, value = 0.2,
		path = COSTS_PATH,
	},
	repairLowEnergyCost = CostOption('Repair cost when energy is low',
		'Added to repair jobs, scaled by how low energy is: repair costs energy.', 15),
	resurrectLowEnergyCost = CostOption('Resurrect cost when energy is low',
		'Added to resurrect jobs, scaled by how low energy is: resurrect costs a lot of energy.', 20),
	allyJobCost = CostOption('Ally job cost',
		'Added to jobs in allies\' queues, so your workers do your own queue first. 0 treats them the same as yours.', 5),
	waitingBonusPerMinute = CostOption('Waiting bonus per minute',
		'Taken off a job\'s cost for each minute it has waited with no workers on it, so far-off jobs don\'t wait forever.', 2),
	waitingBonusMax = CostOption('Waiting bonus: maximum',
		'The most the waiting bonus can take off a job\'s cost.', 20, 120),
	commanderTravelFactor = {
		name = 'Commander travel time factor',
		desc = 'A commander\'s travel time counts this many times over, so it builds near where it is instead of walking out to the front. 1 treats it like any other worker.',
		type = 'number', min = 1, max = 10, step = 0.25, value = 2,
		path = COSTS_PATH,
	},
	metalNeedBonus = CostOption('Metal need bonus',
		'Taken off building mexes, scaled by how much more metal is needed: metal is low, metal income is behind energy income, or build power wants more than comes in (unless energy income is the one behind). Never while metal is piling up.', 15),
	energyNeedBonus = CostOption('Energy need bonus',
		'Taken off building energy (solar, wind, fusion, geothermal, singularity), scaled by how much more energy is needed: energy is low, energy income is behind metal income, or build power wants more than comes in (unless metal income is the one behind).', 15),
	incomeBalanceBand = {
		name = 'Metal/energy income: even within',
		desc = 'Building spends metal and energy about 1:1. Incomes within this share (0 to 1) of each other count as even: mexes and energy get the same bonus, so workers aren\'t pulled off one for the other. Beyond it, whichever income is behind gets the bonus, fully so once it is behind by this much more again.',
		type = 'number', min = 0, max = 0.5, step = 0.05, value = 0.1,
		path = COSTS_PATH,
	},
	productionNeedBonus = CostOption('Build power need bonus',
		'Taken off building caretakers and factories, and off helping factories, scaled by how high metal is: metal piling up means there isn\'t enough build power to spend it. Metal being spent faster than it comes in doesn\'t count as high.', 15),
	assistFactories = {
		name = 'Help factories',
		desc = 'Let GBC workers help (guard) your factories while they are producing, as the "units" side of the economy/units split. Off, factories get their build power from caretakers instead (see Auto-build caretakers).',
		type = 'bool',
		value = false,
		noHotkey = true,
	},
	econShare = {
		name = 'Economy vs units: economy share',
		desc = 'The share (0 to 1) of build power - GBC workers plus producing factories - to spend on economy (mexes, energy, storage, pylons). The rest goes to units: factories and GBC workers helping them. The Eco, Balanced and Army buttons in GBC mode\'s orders set it too.',
		type = 'number', min = 0, max = 1, step = 0.05, value = 0.5,
		OnChange = function(self)
			Spring.ForceLayoutUpdate() -- re-mark which preset button is in use
		end,
	},
	splitWeight = CostOption('Economy vs units: steering strength',
		'How strongly the economy share steers workers: economy jobs get up to this much cheaper when economy is behind its share, and helping factories this much dearer (and the other way round when units are behind).', 20),
	factoryAssistPreferred = {
		name = 'Preferred workers helping a factory',
		desc = 'Preferred worker count for helping each producing factory.',
		type = 'number', min = 1, max = 20, step = 1, value = 3,
		path = COSTS_PATH,
	},
	factoryAssistCost = CostOption('Help factory cost',
		'Added to helping a factory, so it is what workers fall back on: a queued job is taken instead unless it is this much further away.', 10),
	factoryFallback = {
		name = 'Help factories when there\'s nothing else',
		desc = 'With Help factories off: GBC workers with no other job to take help (guard) your producing factories, so spare build power goes into units rather than standing idle. They leave for any job that comes up. Energy expansion (fusions, singularities) is left to you.',
		type = 'bool',
		value = true,
		noHotkey = true,
	},
	factoryFallbackCost = CostOption('Help factories when there\'s nothing else: cost',
		'Added to helping a factory as a fallback (see Help factories when there\'s nothing else), on top of Help factory cost, so any queued job, caretaker or backup reclaim is taken first.', 30, 120),
	backupReclaim = {
		name = 'Backup: reclaim near our buildings',
		desc = 'When there is nothing better to do, area reclaim wrecks and other metal near your buildings, where it is safe (no danger, see Danger radius).',
		type = 'bool',
		value = true,
		noHotkey = true,
	},
	backupReclaimCost = CostOption('Backup reclaim cost',
		'Added to backup reclaim, so workers only fall back on it: a queued job is taken instead unless it is this much further away.', 20),
	factoryAssistLowMetalCost = CostOption('Help factory cost when metal is short',
		'Added to helping a factory, scaled by how much more metal is needed: without the metal to spend, more build power on a factory only spreads it thinner.', 20),
	steerPriority = {
		name = 'Steer build priority',
		desc = 'While metal is short, lower whichever side of the economy/units split is ahead to Low build priority: factories when units are ahead, GBC workers on economy jobs when economy is ahead. Only ever between Normal and Low, never High, and never a unit whose priority you set yourself. Units it lowered go back to Normal when no longer ahead.',
		type = 'bool',
		value = true,
		noHotkey = true,
	},
	dangerRadius = {
		name = 'Danger radius (elmos)',
		desc = 'Armed units within this distance of a job count towards its danger (allied defences only if they can reach the job).',
		type = 'number', min = 100, max = 6000, step = 50, value = 2000,
		path = COSTS_PATH,
	},
	dangerPenalty = CostOption('Danger penalty',
		'Added to a job\'s cost whenever the metal of armed enemy units within the danger radius is more than that of allied armed units there and allied defences that can reach it (a defence job counts itself): so workers clear out of a raid\'s path before it arrives. It doesn\'t grow with the difference. An armed worker (a commander, a Welder) counts its own metal on the allied side too.', 30, 120),
	dangerRadarDotMetal = {
		name = 'Danger: unidentified radar dot (metal)',
		desc = 'How much metal an enemy radar dot counts as, when its type isn\'t known.',
		type = 'number', min = 0, max = 1000, step = 10, value = 100,
		path = COSTS_PATH,
	},
	autoCaretakers = {
		name = 'Auto-build caretakers',
		desc = 'Queue caretakers beside your producing factories until they and the factories can spend the units share of your metal income (see Economy vs units) - or more, when your GBC workers\' build power can\'t spend all of the economy share, so metal doesn\'t pile up. Each spends up to its build power in metal a second. While metal is piling up anyway, more are added to spend what goes unspent. They go beside the factory with the fewest first, and are ordinary GBC jobs: shown, and removable like any other.',
		type = 'bool',
		value = true,
		noHotkey = true,
	},
	autoCaretakersIdleFactories = {
		name = 'Auto-build caretakers: idle factories too',
		desc = 'Also queue caretakers beside factories that aren\'t producing anything.',
		type = 'bool',
		value = false,
		noHotkey = true,
	},
	maxCaretakersPerFactory = {
		name = 'Auto-build caretakers: per factory',
		desc = 'The most caretakers (built or queued) to have beside each factory, however much income there is to spend.',
		type = 'number', min = 1, max = 30, step = 1, value = 12,
	},
	caretakerNeedBonus = CostOption('Caretaker need bonus',
		'Taken off building your caretakers, scaled by how far short the units side is of the caretakers it should have (see Auto-build caretakers), in full once two short: brings a worker back to base to build them. None once there are enough.', 30, 120),
	lowPriorityCost = CostOption('Low priority job cost',
		'Added to jobs marked low priority.', 15),
	highPriorityDiscount = CostOption('High priority job discount',
		'Taken off jobs the player marked high priority.', 30, 120),
	debugCosts = {
		name = 'Debug: show job costs',
		desc = 'Print each job\'s cost above it, as an unassigned worker would see it, leaving out its travel time. Updated on each worker AI update.',
		type = 'bool',
		value = false,
		noHotkey = true,
	},
	debugDanger = {
		name = 'Debug: show danger',
		desc = 'Print the danger of every danger square on the map at its centre: its danger in metal and the cost that adds to a job there, then the enemy, allied unit and allied defence metal it is worked out from. Updated on each worker AI update.',
		type = 'bool',
		value = false,
		noHotkey = true,
	},
	debugWorkerLog = {
		name = 'Debug: log workers',
		desc = 'Every 10 seconds, write a line to the infolog for each GBC worker: the job it is on, how far it is from it and how long it takes to get there, and that job\'s cost.',
		type = 'bool',
		value = false,
		noHotkey = true,
	},
	debugEconLog = {
		name = 'Debug: log the economy',
		desc = 'Every 10 seconds, write a line to the infolog with income and spending, what the worker AI makes of them (needs, caretakers), and where build power is going.',
		type = 'bool',
		value = false,
		noHotkey = true,
	},
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

-- Every setting is advanced (hidden unless the player shows advanced
-- settings); only the mode's hotkey stays visible, so it can be rebound.
for key, option in pairs(options) do
	if key ~= 'toggle' then
		option.advanced = true
	end
end

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
	elseif unitDefID and UnitDefs[unitDefID].isFactory then
		factories[unitID] = true
	end
end

local function GetManagedTeamID()
	if spGetSpectatingState() then
		return nil
	end
	local teamID = spGetMyTeamID()
	local _, leaderID = Spring.GetTeamInfo(teamID, false)
	if leaderID ~= Spring.GetMyPlayerID() then
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
	for unitID in pairs(assignment) do
		Unassign(unitID)
	end
	RestoreAllPriorities()
	workers = {}
	factories = {}
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
			if state ~= 1 then
				-- Stop managing it, but leave whatever it's doing alone.
				Unassign(unitID)
			end
		end
	end
end

-- Removes every job of ours whose position is inside the circle. Reads our
-- jobs from the job store rather than keeping its own list, so jobs the store
-- got back after a reload or rejoin can be removed too. Shared by right-drag
-- removal and the Global Build Cancel command.
local function RemoveJobsInCircle(x, z, r)
	local share = WG.GlobalBuildListShare
	if not share then
		return
	end
	local myTeamID = spGetMyTeamID()
	local rSq = r * r
	local jobIds = share.GetJobIds(myTeamID)
	for i = 1, #jobIds do
		local jobId = jobIds[i]
		local jx, jz = share.GetX(myTeamID, jobId), share.GetZ(myTeamID, jobId)
		if jx and DistanceSq(x, z, jx, jz) <= rSq then
			share.Delete(jobId)
		end
	end
end

local function QueueJob(job)
	WG.GlobalBuildListShare.Update(job)
end

--------------------------------------------------------------------------------
-- Callins
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Worker AI
--------------------------------------------------------------------------------
-- Every updateRate seconds, each GBC worker that is idle or on a GBC job picks
-- the job with the lowest cost, from our own and our allies' lists in the job
-- store. Costs are in seconds:
--   - travel time: distance to the job, less the worker's build range (and an
--     area job's radius), divided by the worker's speed.
--   - preferred workers: each job has a preferred worker count, enough
--     average GBC workers to build it in the target finish time (fixed for
--     the whole build). A started job short of it gets a bonus per missing
--     worker, so crews fill started jobs before new ones get started; any job
--     past it costs more per extra worker.
--   - completion: large projects get cheaper the closer they are to finished,
--     and their over-staffed cost fades with progress, so a nearly finished
--     superweapon draws in every worker for whom it's the cheapest job.
--   - high metal: repair jobs cost more the fuller metal storage is, since
--     repair spends energy but no metal - piling-up metal is better turned
--     into buildings. Reclaim jobs cost more too (reclaimed metal is wasted
--     once storage is full), and less when metal is low.
--   - low energy: repair and resurrect jobs cost more the emptier energy
--     storage is, since both spend energy.
--   - ally jobs cost a little more than our own.
--   - waiting: a job gets cheaper the longer it waits with no workers on it.
--   - commanders: their travel time counts extra, to keep them near home.
--   - resource need: mexes get cheaper the lower metal is, energy the lower
--     energy is, and caretakers, factories and helping factories the higher
--     metal is (not enough build power to spend it).
--   - danger: a flat penalty whenever armed enemies' metal near a job is
--     more than allied armed units' metal and that of the defences that
--     can reach it (a defence job counts itself, an armed worker - a
--     commander, a Welder - its own metal).
--   - economy vs units: workers can also help (guard) our producing
--     factories. Economy jobs (mexes, energy, storage, pylons) get cheaper
--     and helping factories dearer while economy is behind its share of build
--     power, and the other way round while units are behind. While metal is
--     short, whichever side is ahead is also lowered to Low build priority -
--     only ever Normal <-> Low, never touching a unit whose priority the
--     player set.
--   - priority: low priority jobs cost more, and jobs the player marked high
--     priority less. GBC never marks anything high itself.
--   - switching: a worker already on a job only moves to another one if it's
--     cheaper by more than the switch cost.
-- A worker the player (or anything else) gives other orders is left alone
-- until it's idle again. Switching a worker off (Global Build state) only
-- stops GBC managing it; it isn't stopped.
--
-- Not yet: pathing (a job across water from a land worker looks reachable
-- until the worker gives up on it).

-- Frames after giving an order during which the worker's current command
-- isn't checked yet, since the order takes a moment to arrive.
local ORDER_GRACE_FRAMES = 60
-- How long a worker leaves a job alone after going idle on it without
-- finishing it.
local FAILED_RETRY_FRAMES = 30 * 30
-- How close (elmos) a new unit has to be to a build job's spot to be its unit.
local LINK_DISTANCE = 24


local function SplitKey(key)
	local owner, jobId = key:match("^(%d+)#(.+)$")
	return tonumber(owner), jobId
end

-- Reports how many of our workers are on a job to the job store.
local function SetOurCount(key, count)
	if count < 0 then
		count = 0
	end
	ourCount[key] = (count > 0) and count or nil
	if baseCosts then
		baseCosts[key] = nil
	end
	local share = WG.GlobalBuildListShare
	local owner, jobId = SplitKey(key)
	if share and owner then -- not for helping a factory, which isn't a job store job
		share.Assist(owner, jobId, count)
	end
end

Unassign = function(unitID)
	local key = assignment[unitID]
	if not key then
		return
	end
	assignment[unitID] = nil
	assignedCmd[unitID] = nil
	assignedFrame[unitID] = nil
	assignedSide[unitID] = nil
	assignedProduces[unitID] = nil
	SetOurCount(key, (ourCount[key] or 1) - 1)
end

ReleaseAllWorkers = function()
	for unitID in pairs(assignment) do
		Unassign(unitID)
	end
	RestoreAllPriorities()
end

-- Rewrites one of our own jobs with a new unitID (the unit being built for
-- it, or nil), keeping its other fields - Update() derives the same jobId.
local function SetOwnJobUnitID(share, jobId, unitID)
	local me = spGetMyTeamID()
	share.Update({
		id = share.GetCmdId(me, jobId),
		x = share.GetX(me, jobId), y = share.GetY(me, jobId), z = share.GetZ(me, jobId),
		h = share.GetH(me, jobId), r = share.GetR(me, jobId),
		target = share.GetTarget(me, jobId),
		reach = share.GetReach(me, jobId),
		priority = share.GetPriority(me, jobId),
		unitID = unitID,
		elevation = share.GetElevation(me, jobId),
		wall = share.GetWall(me, jobId),
	})
end

-- A new unit (anyone's on our side) that sits on one of our build jobs'
-- spots, of the right type, is that job's unit.
local function LinkNewUnit(unitID, unitDefID)
	local share = WG.GlobalBuildListShare
	if not share then
		return
	end
	local me = spGetMyTeamID()
	local ux, _, uz = spGetUnitPosition(unitID)
	if not ux then
		return
	end
	local jobIds = share.GetJobIds(me)
	for i = 1, #jobIds do
		local jobId = jobIds[i]
		if share.GetCmdId(me, jobId) == -unitDefID and not share.GetUnitID(me, jobId) then
			local jx, jz = share.GetX(me, jobId), share.GetZ(me, jobId)
			if math.abs(jx - ux) <= LINK_DISTANCE and math.abs(jz - uz) <= LINK_DISTANCE then
				SetOwnJobUnitID(share, jobId, unitID)
				return
			end
		end
	end
end

-- Removes our own jobs that are done or can't be done any more: build jobs
-- whose spot is blocked (including by the finished building), and
-- single-target jobs whose target is gone (or, for repair, fully repaired).
-- Finished build jobs are removed in UnitFinished.
local function CleanOwnJobs(share)
	local me = spGetMyTeamID()
	local jobIds = share.GetJobIds(me)
	for i = 1, #jobIds do
		local jobId = jobIds[i]
		local cmd = share.GetCmdId(me, jobId)
		local target = share.GetTarget(me, jobId)
		local done = false
		if cmd < 0 then
			local x, z = share.GetX(me, jobId), share.GetZ(me, jobId)
			local facing = share.GetH(me, jobId) or 0
			local wall = share.GetWall(me, jobId)
			local unitID = share.GetUnitID(me, jobId)
			if unitID then
				-- Built, and a wall still to raise: keep it until the wall is up.
				if wall and spValidUnitID(unitID) and not IsNanoframe(unitID) then
					done = not WallNeeded(UnitDefs[-cmd], x, z, facing, wall)
				end
			elseif spTestBuildOrder(-cmd, x, share.GetY(me, jobId), z, facing) == 0 then
				-- Blocked: by the building itself (built by someone else, or
				-- already there when a wall was ordered around it), by
				-- terraform still going on, or by something else.
				local existing = ExistingBuildingAt(-cmd, x, z)
				local elevation = share.GetElevation(me, jobId)
				if existing and wall then
					SetOwnJobUnitID(share, jobId, existing) -- on to its wall
				elseif not existing and elevation and ElevationNeeded(UnitDefs[-cmd], x, z, facing, elevation) then
					done = false -- not levelled yet: the job levels it first
				else
					done = not TerraformPendingAt(x, z, TerraformRadius(UnitDefs[-cmd]))
				end
			end
		elseif target then
			if target >= Game.maxUnits then
				done = not spValidFeatureID(target - Game.maxUnits)
			elseif not spValidUnitID(target) or spGetUnitIsDead(target) then
				done = true
			elseif cmd == CMD_REPAIR then
				local health, maxHealth, _, _, buildProgress = spGetUnitHealth(target)
				done = health and health >= maxHealth and (buildProgress or 1) >= 1
			end
		end
		if done then
			share.Delete(jobId)
		end
	end
end

-- The UnitDef a job builds or repairs, or nil for area, reclaim and
-- resurrect jobs.
local function JobUnitDef(cmd, target)
	if cmd < 0 then
		return UnitDefs[-cmd]
	elseif cmd == CMD_REPAIR and target and target < Game.maxUnits then
		local unitDefID = spGetUnitDefID(target)
		return unitDefID and UnitDefs[unitDefID]
	end
end

-- What a building a job builds is for: "metal", "energy" or "production"
-- (build power), or nil; and whether it's on the economy side of the
-- economy/units split (mexes, energy, storage, pylons).
local function BuildCategory(unitDef)
	if not (unitDef and unitDef.isImmobile) then
		return nil, false
	end
	local cp = unitDef.customParams
	if cp.ismex then
		return "metal", true
	-- (unitdefs_post.lua moves energyMake into income_energy, leaving it 0.)
	elseif (tonumber(cp.income_energy) or 0) > 0 or (unitDef.energyMake or 0) > 0 or cp.windgen then
		return "energy", true
	elseif (unitDef.buildSpeed or 0) > 0 then
		return "production", false
	end
	local storage = (unitDef.metalStorage or 0) > 0 or (unitDef.energyStorage or 0) > 0
	return nil, storage or (cp.pylonrange ~= nil)
end

-- Shields don't count: a Convict or an Aegis can't fight off a raid.
local function IsArmed(unitDef)
	local weapons = unitDef.weapons
	for i = 1, #(weapons or {}) do
		local weaponDef = WeaponDefs[weapons[i].weaponDef]
		if weaponDef and weaponDef.type ~= "Shield" then
			return true
		end
	end
	return false
end

-- Whether a building is a defence: armed, and not a large project (so not a
-- superweapon).
local function IsDefence(unitDef)
	return unitDef and unitDef.isImmobile and IsArmed(unitDef)
		and (unitDef.metalCost or 0) < options.largeMinMetal.value
end

-- Danger is worked out once per DANGER_CELL x DANGER_CELL map square per
-- update, at the square's centre, and shared by every job in it: with a big
-- danger radius, scanning the units around every job separately would cost
-- a lot of CPU in a big game. dangerCache[cellKey] = {enemy, allied, defence}.
local DANGER_CELL = 256
local dangerCache = {}

-- {x, y, z, cost} per job from the last worker AI update, for the debugCosts
-- option, or nil.
local debugCosts
-- {x, y, z, danger, cost, enemy, allied, defence} per danger square from the
-- last worker AI update, for the debugDanger option, or nil.
local debugDanger

local function DangerSums(x, z)
	local radius = options.dangerRadius.value
	local units = spGetUnitsInCylinder(x, z, radius)
	local enemy, allied, defence = 0, 0, 0
	if units then
		for i = 1, #units do
			local unitID = units[i]
			local unitDefID = spGetUnitDefID(unitID)
			local ud = unitDefID and UnitDefs[unitDefID]
			if not spIsUnitAllied(unitID) then
				if not ud then
					enemy = enemy + options.dangerRadarDotMetal.value
				elseif IsArmed(ud) and not IsNanoframe(unitID) then
					enemy = enemy + (ud.metalCost or 0)
				end
			elseif ud and IsArmed(ud) and not IsNanoframe(unitID) then
				if ud.isImmobile then
					-- A defence can't move to help: only where it can reach.
					local ux, _, uz = spGetUnitPosition(unitID)
					local range = ud.maxWeaponRange or 0
					if ux and DistanceSq(x, z, ux, uz) <= range * range then
						defence = defence + (ud.metalCost or 0)
					end
				else
					allied = allied + (ud.metalCost or 0)
				end
			end
		end
	end
	return enemy, allied, defence
end

-- A spot's danger, in metal: armed enemies' metal less allied armed units'
-- and reaching defences' metal, never below 0. ownDefenceMetal is a defence
-- job's own metal.
local function DangerAt(x, z, ownDefenceMetal)
	local cx, cz = math.floor(x / DANGER_CELL), math.floor(z / DANGER_CELL)
	local cellKey = cx .. "," .. cz
	local sums = dangerCache[cellKey]
	if not sums then
		local enemy, allied, defence = DangerSums((cx + 0.5) * DANGER_CELL, (cz + 0.5) * DANGER_CELL)
		sums = {enemy, allied, defence}
		dangerCache[cellKey] = sums
	end
	return math.max(0, sums[1] - sums[2] - sums[3] - (ownDefenceMetal or 0))
end

-- What a spot's danger (DangerAt) adds to a job's cost: the flat
-- dangerPenalty whenever it is more than ownMetal, the metal an armed worker
-- brings with it (0 for an unarmed one).
local function DangerCost(danger, ownMetal)
	return danger > (ownMetal or 0) and options.dangerPenalty.value or 0
end

-- Every danger square on the map, for the debugDanger option. Fills
-- dangerCache as it goes, so the jobs' own lookups this update are free.
local function CollectDebugDanger()
	debugDanger = {}
	for cx = 0, math.ceil(Game.mapSizeX / DANGER_CELL) - 1 do
		for cz = 0, math.ceil(Game.mapSizeZ / DANGER_CELL) - 1 do
			local x, z = (cx + 0.5) * DANGER_CELL, (cz + 0.5) * DANGER_CELL
			local danger = DangerAt(x, z)
			local sums = dangerCache[cx .. "," .. cz]
			debugDanger[#debugDanger + 1] = {
				x, spGetGroundHeight(x, z), z,
				danger, DangerCost(danger),
				sums[1], sums[2], sums[3],
			}
		end
	end
end

-- How many workers a job wants: enough workers of average build power to
-- build it in the target finish time. From the whole build time, so it
-- doesn't change as the job progresses.
local function PreferredWorkers(unitDef, avgBuildPower)
	if not unitDef then
		return options.areaPreferred.value
	end
	local buildTime = unitDef.buildTime or unitDef.metalCost or 0
	local preferred = math.ceil(buildTime / (avgBuildPower * options.targetFinishTime.value))
	return math.max(options.minPreferred.value, math.min(options.maxPreferred.value, preferred))
end

-- waitingSince[key] = game frame since which a job has had no workers on it.
local waitingSince = {}

-- Every job in our own and our allies' lists that can still be worked on,
-- with what the cost needs precomputed once per update.
-- Backup reclaim: for each BACKUP_RECLAIM_CELL square with one of our
-- buildings in it and at least BACKUP_RECLAIM_MIN_METAL of reclaimable metal,
-- an area reclaim over the square. Which squares is worked out every
-- BACKUP_RECLAIM_FRAMES, as it looks at all our units and the features near
-- them; whether each is safe, every update. These aren't job store jobs;
-- their keys start with "r#".
local BACKUP_RECLAIM_CELL = 512
local BACKUP_RECLAIM_RADIUS = BACKUP_RECLAIM_CELL * 0.75 -- reaches the square's corners
local BACKUP_RECLAIM_MIN_METAL = 10
local BACKUP_RECLAIM_FRAMES = 5 * 30
local backupReclaimCells = {}
local backupReclaimFrame

local function FindBackupReclaimCells()
	local cells, seen = {}, {}
	local units = spGetTeamUnits(managedTeamID) or {}
	for i = 1, #units do
		local unitDefID = spGetUnitDefID(units[i])
		local ud = unitDefID and UnitDefs[unitDefID]
		local x, _, z = spGetUnitPosition(units[i])
		if ud and ud.isImmobile and x then
			local cx, cz = math.floor(x / BACKUP_RECLAIM_CELL), math.floor(z / BACKUP_RECLAIM_CELL)
			local cellKey = cx .. "," .. cz
			if not seen[cellKey] then
				seen[cellKey] = true
				local x1, z1 = cx * BACKUP_RECLAIM_CELL, cz * BACKUP_RECLAIM_CELL
				local features = Spring.GetFeaturesInRectangle(x1, z1, x1 + BACKUP_RECLAIM_CELL, z1 + BACKUP_RECLAIM_CELL)
				local metal = 0
				for j = 1, #features do
					local featureDefID = Spring.GetFeatureDefID(features[j])
					local fd = featureDefID and FeatureDefs[featureDefID]
					if fd and fd.reclaimable then
						metal = metal + (Spring.GetFeatureResources(features[j]) or 0)
					end
				end
				if metal >= BACKUP_RECLAIM_MIN_METAL then
					cells[#cells+1] = {
						key = "r#" .. cellKey,
						x = x1 + BACKUP_RECLAIM_CELL / 2,
						z = z1 + BACKUP_RECLAIM_CELL / 2,
					}
				end
			end
		end
	end
	return cells
end

local function CollectJobs(share, avgBuildPower, frame)
	local jobs = {}
	local stillWaiting = {}
	-- Every team on our side: our own (which, with commshare, holds our
	-- teammates' jobs too) and our allies'.
	local teams = Spring.GetTeamList(Spring.GetMyAllyTeamID())
	for i = 1, #teams do
		local owner = teams[i]
		do
			local jobIds = share.GetJobIds(owner)
			for j = 1, #jobIds do
				local jobId = jobIds[j]
				local cmd = share.GetCmdId(owner, jobId)
				local target = share.GetTarget(owner, jobId)
				local x, z = share.GetX(owner, jobId), share.GetZ(owner, jobId)
				local valid = true
				if target then
					if target >= Game.maxUnits then
						valid = spValidFeatureID(target - Game.maxUnits)
					elseif spValidUnitID(target) and not spGetUnitIsDead(target) then
						local ux, _, uz = spGetUnitPosition(target) -- units move
						if ux then
							x, z = ux, uz
						end
					else
						valid = false
					end
				end
				-- Build jobs: which phase they're in (see Buildings at a height,
				-- and walls). One waiting on terraform it didn't order itself
				-- (lasso's "level, then build") can't be built yet.
				local phase, elevation, wall, terraunit
				if valid and cmd and cmd < 0 and x then
					local unitDef = UnitDefs[-cmd]
					local facing = share.GetH(owner, jobId) or 0
					local jobUnitID = share.GetUnitID(owner, jobId)
					local radius = TerraformRadius(unitDef)
					elevation, wall = share.GetElevation(owner, jobId), share.GetWall(owner, jobId)
					local built = jobUnitID and spValidUnitID(jobUnitID) and not IsNanoframe(jobUnitID)
					if not jobUnitID and wall then
						built = ExistingBuildingAt(-cmd, x, z) and true
					end
					if built then
						phase = (wall and WallNeeded(unitDef, x, z, facing, wall)) and "wall" or nil
						valid = phase ~= nil
					elseif not jobUnitID and elevation and ElevationNeeded(unitDef, x, z, facing, elevation) then
						phase = "elevate"
					elseif not jobUnitID and not elevation and TerraformPendingAt(x, z, radius) then
						valid = false
					end
					if phase then
						terraunit = NearestTerraunit(x, z, radius * 2)
						local issued = terraformIssued[owner .. "#" .. jobId]
						if not terraunit and issued and frame < issued[2] + TERRAFORM_ISSUE_WAIT then
							valid = false -- just started it; wait for its terraunits
						end
					end
				end
				if valid and cmd and x then
					local key = owner .. "#" .. jobId
					local unitID = share.GetUnitID(owner, jobId)
					local progress
					if unitID and spValidUnitID(unitID) then
						local _, _, _, _, buildProgress = spGetUnitHealth(unitID)
						progress = buildProgress
					else
						unitID = nil
					end
					local unitDef = JobUnitDef(cmd, target)
					local terraform = cmd == CMD_REPAIR and target and target < Game.maxUnits
						and spGetUnitDefID(target) == terraunitDefID
					local preferred
					if terraform then
						-- From the terraform gadget's own metal estimate for it.
						local estimate = spGetUnitRulesParam(target, "terraform_estimate") or 0
						preferred = math.max(options.minPreferred.value, math.min(options.maxPreferred.value,
							math.ceil(estimate / (avgBuildPower * options.targetFinishTime.value))))
					else
						preferred = PreferredWorkers(unitDef, avgBuildPower)
					end
					local produces, econ
					if cmd < 0 then
						produces, econ = BuildCategory(unitDef)
					end
					local waitingBonus = 0
					if share.GetWorkerCount(owner, jobId) == 0 then
						local since = waitingSince[key] or frame
						stillWaiting[key] = since
						local minutes = (frame - since) / (30 * 60)
						waitingBonus = math.min(options.waitingBonusMax.value, minutes * options.waitingBonusPerMinute.value)
					end
					jobs[#jobs+1] = {
						phase = phase,
						elevation = elevation,
						wall = wall,
						terraunit = terraunit,
						waitingBonus = waitingBonus,
						produces = produces,
						econ = econ,
						danger = DangerAt(x, z, (cmd < 0 and IsDefence(unitDef)) and unitDef.metalCost or 0),
						key = key, owner = owner, jobId = jobId, cmd = cmd,
						x = x, y = share.GetY(owner, jobId), z = z,
						h = share.GetH(owner, jobId), r = share.GetR(owner, jobId),
						target = target, unitID = unitID, progress = progress,
						preferred = preferred,
						terraform = terraform,
						large = unitDef and (unitDef.metalCost or 0) >= options.largeMinMetal.value,
						priority = share.GetPriority(owner, jobId),
						-- Other players' workers on it; ours are added from ourCount,
						-- which changes as this update assigns workers.
						others = share.GetWorkerCount(owner, jobId) - (ourCount[key] or 0),
					}
				end
			end
		end
	end
	waitingSince = stillWaiting

	-- Helping each of our producing factories, as the "units" side of the
	-- economy/units split. These aren't job store jobs; their keys start
	-- with "f#". With Help factories off, they're still there as a fallback
	-- (costing factoryFallbackCost more), so workers with nothing else to do
	-- put their build power into units rather than standing idle.
	local assistFallback = not options.assistFactories.value and options.factoryFallback.value
	if options.assistFactories.value or assistFallback then
		local me = spGetMyTeamID()
		for factoryID in pairs(factories) do
			if spGetUnitIsBuilding(factoryID) then
				local fx, fy, fz = spGetUnitPosition(factoryID)
				if fx then
					jobs[#jobs+1] = {
						key = "f#" .. factoryID, owner = me, cmd = CMD_GUARD,
						x = fx, y = fy, z = fz, target = factoryID,
						preferred = options.factoryAssistPreferred.value,
						others = 0, waitingBonus = 0,
						factoryAssist = true,
						fallback = assistFallback,
						danger = DangerAt(fx, fz),
					}
				end
			end
		end
	end

	if options.backupReclaim.value then
		if not backupReclaimFrame or frame >= backupReclaimFrame + BACKUP_RECLAIM_FRAMES then
			backupReclaimCells = FindBackupReclaimCells()
			backupReclaimFrame = frame
		end
		local me = spGetMyTeamID()
		for i = 1, #backupReclaimCells do
			local cell = backupReclaimCells[i]
			if DangerAt(cell.x, cell.z) <= 0 then
				jobs[#jobs+1] = {
					key = cell.key, owner = me, cmd = CMD_RECLAIM,
					x = cell.x, z = cell.z, r = BACKUP_RECLAIM_RADIUS,
					preferred = options.areaPreferred.value,
					others = 0, waitingBonus = 0, danger = 0,
					backupReclaim = true,
				}
			end
		end
	end
	return jobs
end

-- The command a worker needs for a job: a build job whose unit has started is
-- helped with repair (which also works on an ally's unit).
local function JobCommand(job)
	if job.phase then
		return job.terraunit and CMD_REPAIR or CMD_LEVEL
	end
	if job.cmd < 0 and job.unitID then
		return CMD_REPAIR
	end
	return job.cmd
end

-- While terraforming for a job, the terraform gadget puts repair orders on
-- its terraunits ahead of CMD_LEVEL, so either is the worker still on the job.
local TERRAFORM_CMDS = {[CMD_LEVEL] = true, [CMD_REPAIR] = true}

-- How full the managed team's storage of a resource is, 0 to 1, leaving
-- out the hidden storage. nil if there's no storage to speak of.
local function StorageFullness(resource)
	local current, storage = spGetTeamResources(managedTeamID, resource)
	if not current then
		return nil
	end
	storage = storage - (HIDDEN_STORAGE or 0)
	if storage <= 0 then
		return nil
	end
	return math.max(0, math.min(1, current / storage))
end

-- 0 at or below 'from', rising to 1 when full.
local function HighAmount(fullness, from)
	if not fullness then
		return 0
	end
	if from >= 1 then
		return (fullness >= 1) and 1 or 0
	end
	return math.max(0, (fullness - from) / (1 - from))
end

-- 0 at or above 'below', rising to 1 when empty.
local function LowAmount(fullness, below)
	if not fullness or below <= 0 then
		return 0
	end
	return math.max(0, (below - fullness) / below)
end

-- How high metal is, how low metal is and how low energy is, each 0 to 1,
-- from storage. metalNeed and energyNeed, also 0 to 1, are how much more
-- metal and energy income we need, for the mex and energy bonuses. Set each
-- update.
local metalHigh, metalLow, energyLow = 0, 0, 0
local metalNeed, energyNeed = 0, 0

-- The economy/units split: economy share target minus the economy's actual
-- share of build power, from -1 to 1. Positive means economy is behind (units
-- ahead), negative that economy is ahead. Set each update.
local splitImbalance = 0
-- Beyond this, one side counts as ahead for steering build priority.
local SPLIT_DEADBAND = 0.1

local function BuildPower(unitID)
	local unitDefID = spGetUnitDefID(unitID)
	return unitDefID and UnitDefs[unitDefID].buildSpeed or 0
end

local function UpdateSplit()
	local econ, units = 0, 0
	for factoryID in pairs(factories) do
		if spGetUnitIsBuilding(factoryID) then
			units = units + BuildPower(factoryID)
		end
	end
	for unitID, side in pairs(assignedSide) do
		if side == "econ" then
			econ = econ + BuildPower(unitID)
		elseif side == "units" then
			units = units + BuildPower(unitID)
		end
	end
	local total = econ + units
	splitImbalance = (total > 0) and (options.econShare.value - econ / total) or 0
end

-- Build priority steering. Only ever Normal <-> Low; loweredByUs records
-- what we lowered, so only that is ever raised back, and playerPriority
-- records units whose priority the player set, which are never touched.
local PRIORITY_LOW, PRIORITY_NORMAL = 0, 1
local loweredByUs = {}
local playerPriority = {}

local function LowerPriority(unitID)
	if loweredByUs[unitID] or playerPriority[unitID] then
		return
	end
	if (spGetUnitRulesParam(unitID, "buildpriority") or PRIORITY_NORMAL) ~= PRIORITY_NORMAL then
		return
	end
	spGiveOrderToUnit(unitID, CMD_PRIORITY, {PRIORITY_LOW}, 0)
	loweredByUs[unitID] = true
end

local function RestorePriority(unitID)
	if not loweredByUs[unitID] then
		return
	end
	loweredByUs[unitID] = nil
	if not playerPriority[unitID] and spValidUnitID(unitID) and not spGetUnitIsDead(unitID) then
		spGiveOrderToUnit(unitID, CMD_PRIORITY, {PRIORITY_NORMAL}, 0)
	end
end

RestoreAllPriorities = function()
	for unitID in pairs(loweredByUs) do
		RestorePriority(unitID)
	end
end

-- Priority only matters while metal is short, so steer only then.
local function SteerPriority()
	local ahead
	if options.steerPriority.value and metalHigh == 0 then
		if splitImbalance > SPLIT_DEADBAND then
			ahead = "units"
		elseif splitImbalance < -SPLIT_DEADBAND then
			ahead = "econ"
		end
	end
	for factoryID in pairs(factories) do
		if ahead == "units" then
			LowerPriority(factoryID)
		else
			RestorePriority(factoryID)
		end
	end
	for unitID in pairs(loweredByUs) do
		if not factories[unitID] and not (ahead == "econ" and assignedSide[unitID] == "econ") then
			RestorePriority(unitID)
		end
	end
	if ahead == "econ" then
		for unitID, side in pairs(assignedSide) do
			if side == "econ" then
				LowerPriority(unitID)
			end
		end
	end
end

-- The share, 0 to 1, of 'wanted' that 'income' falls short of.
local function Shortfall(income, wanted)
	if not (income and wanted) or wanted <= 0 then
		return 0
	end
	return math.max(0, math.min(1, (wanted - income) / wanted))
end

-- Metal and energy income, and what build power wants in metal, per
-- second, averaged (see UpdateResources). Read each update.
local metalIncome, energyIncome, metalPull = 0, 0, 0
-- Income still to come from our metal and energy projects in progress (see
-- ProjectedIncome), per second. Set each update, and again as workers take
-- or leave those projects.
local projectedMetal, projectedEnergy = 0, 0

-- metalNeed and energyNeed, from the incomes counting the projected ones:
-- that's what they'll be once the projects in progress are done, so several
-- workers don't all start energy to make up the same shortfall.
local function UpdateNeeds()
	local metalIn = metalIncome + projectedMetal
	local energyIn = energyIncome + projectedEnergy
	-- Build power wanting more metal than comes (or is about to come) in.
	local metalShort = Shortfall(metalIn, metalPull)

	-- Building spends metal and energy about 1:1, so more of one income than
	-- the other can't be spent. How far each is behind the other, 0 within
	-- the band (about even), rising to 1 at twice the band.
	local band = options.incomeBalanceBand.value
	local function Behind(income, other)
		local short = Shortfall(income, other)
		if band <= 0 then
			return (short > 0) and 1 or 0
		end
		return math.max(0, math.min(1, (short - band) / band))
	end
	local energyBehind = Behind(energyIn, metalIn)
	local metalBehind = Behind(metalIn, energyIn)

	-- Build power wanting more than comes in calls for more of both - evenly
	-- while the incomes are about even, so neither pulls workers off the
	-- other - less of whichever income is ahead, and more of the one behind.
	-- None while metal is piling up, though: more mexes would only add to
	-- what goes to waste, however far metal income is behind energy.
	metalNeed = math.max(metalLow, metalShort * (1 - energyBehind), metalBehind) * (1 - metalHigh)
	energyNeed = math.max(energyLow, metalShort * (1 - metalBehind), energyBehind)
end

-- Incomes and pull are averaged over about this long: energy income swings
-- with the wind, and pull with what's being built, and the needs shouldn't
-- flip workers back and forth with every gust.
local INCOME_SMOOTH_SECONDS = 20
local smoothedYet = false

local function UpdateResources()
	local _, _, pull, income = spGetTeamResources(managedTeamID, "metal")
	local _, _, _, eIncome = spGetTeamResources(managedTeamID, "energy")
	pull, income, eIncome = pull or 0, income or 0, eIncome or 0
	-- The engine's energy income is what's left after overdrive
	-- (unit_mex_overdrive.lua) has put the spare into mexes. What building
	-- can use is all of it, so add the generators' income back the way the
	-- resource bar (gui_chili_resource_bars.lua) does.
	local generators = Spring.GetTeamRulesParam(managedTeamID, "OD_energyIncome")
	if generators then
		eIncome = eIncome + generators - math.max(0, Spring.GetTeamRulesParam(managedTeamID, "OD_energyChange") or 0)
	end
	if smoothedYet then
		local k = math.min(1, options.updateRate.value / INCOME_SMOOTH_SECONDS)
		metalIncome = metalIncome + (income - metalIncome) * k
		metalPull = metalPull + (pull - metalPull) * k
		energyIncome = energyIncome + (eIncome - energyIncome) * k
	else
		metalIncome, metalPull, energyIncome = income, pull, eIncome
		smoothedYet = spGetGameFrame() > 0
	end

	local metal = StorageFullness("metal")
	-- Metal only counts as high while it isn't draining, so a full storage we
	-- are spending down fast (as at the start) doesn't call for build power.
	metalHigh = HighAmount(metal, options.highMetalFrom.value) * (1 - Shortfall(metalIncome, metalPull))
	metalLow = LowAmount(metal, options.lowMetalBelow.value)
	energyLow = LowAmount(StorageFullness("energy"), options.lowEnergyBelow.value)
end


-- How short the units side is of the caretakers it should have, 0 to 1,
-- counting only those built (see QueueCaretakers), for the caretaker need
-- bonus. Set every caretaker check.
local caretakerDefID = UnitDefNames.staticcon and UnitDefNames.staticcon.id
local caretakerNeed = 0
-- The last caretaker check's figures, for the economy log.
local caretakerStats = {}

-- A job's cost to a worker, leaving out its travel time.
local function JobBaseCost(job, currentKey)
	local cost = 0

	-- Workers on it besides this one.
	local crowd = job.others + (ourCount[job.key] or 0)
	if currentKey == job.key then
		crowd = crowd - 1
	end
	local preferred = job.preferred
	local nearlyDone = job.large and job.progress and job.progress >= options.completionMinProgress.value

	if crowd < preferred then
		local started = job.unitID or crowd > 0
		if started then
			cost = cost - (preferred - crowd) * options.shortHandedBonus.value
		end
	else
		local perExtra = options.overStaffedCost.value
		if nearlyDone then
			perExtra = perExtra * (1 - job.progress)
		end
		cost = cost + (crowd - preferred + 1) * perExtra
	end

	if nearlyDone then
		cost = cost - options.completionWeight.value * job.progress
	end

	-- Repair jobs, not repair used to help build an unfinished building (that
	-- does spend metal).
	-- Terraform is carried out by repair, but spends metal like building, so
	-- the repair resource costs don't apply to it.
	if job.cmd == CMD_REPAIR and not job.terraform then
		cost = cost + options.repairHighMetalCost.value * metalHigh
			+ options.repairLowEnergyCost.value * energyLow
	elseif job.cmd == CMD_RECLAIM then
		cost = cost + options.reclaimHighMetalCost.value * metalHigh
			- options.reclaimLowMetalBonus.value * metalLow
	elseif job.cmd == CMD_RESURRECT then
		cost = cost + options.resurrectLowEnergyCost.value * energyLow
	end

	-- The need bonuses below say the job needs doing, not that it needs more
	-- workers: they're only for a worker it's still short of, so a staffed
	-- job doesn't pull extra workers off theirs from across the map.
	local needed = crowd < preferred

	if not needed then
		-- (no need bonuses)
	elseif job.produces == "metal" then
		cost = cost - options.metalNeedBonus.value * metalNeed
	elseif job.produces == "energy" then
		cost = cost - options.energyNeedBonus.value * energyNeed
	elseif job.produces == "production" or job.factoryAssist then
		cost = cost - options.productionNeedBonus.value * metalHigh
	end

	-- Our caretakers, while we're short of them: brings a worker back to base
	-- to build one rather than keeping one parked there.
	if needed and job.cmd == -caretakerDefID and job.owner == spGetMyTeamID() then
		cost = cost - options.caretakerNeedBonus.value * caretakerNeed
	end


	-- The economy/units steering: a cost for the side that's ahead always, a
	-- bonus for the side that's behind only while the job needs workers.
	local steer = 0
	if job.econ then
		steer = -options.splitWeight.value * splitImbalance
	elseif job.factoryAssist then
		steer = options.splitWeight.value * splitImbalance
	end
	if steer > 0 or needed then
		cost = cost + steer
	end

	if job.backupReclaim then
		cost = cost + options.backupReclaimCost.value
	end

	if job.fallback then
		cost = cost + options.factoryFallbackCost.value
	end

	if job.factoryAssist then
		cost = cost + options.factoryAssistCost.value
			+ options.factoryAssistLowMetalCost.value * metalNeed
	end

	-- Only for another team's jobs: what our commshare teammates queue is on
	-- our own team's list.
	if job.owner ~= spGetMyTeamID() then
		cost = cost + options.allyJobCost.value
	end

	cost = cost - job.waitingBonus

	if job.priority == 0 then
		cost = cost + options.lowPriorityCost.value
	elseif job.priority == 1 then
		cost = cost - options.highPriorityDiscount.value
	end
	return cost
end

-- The danger penalty for this worker taking this job. An armed worker (a
-- commander, a Welder) is army too: it counts its own metal against the
-- danger there, unless it is already near enough to be counted in it.
local function WorkerDangerCost(ud, wx, wz, job)
	local ownMetal = 0
	if job.danger > 0 and IsArmed(ud) then
		local cx = (math.floor(job.x / DANGER_CELL) + 0.5) * DANGER_CELL
		local cz = (math.floor(job.z / DANGER_CELL) + 0.5) * DANGER_CELL
		if DistanceSq(wx, wz, cx, cz) > options.dangerRadius.value^2 then
			ownMetal = ud.metalCost or 0
		end
	end
	return DangerCost(job.danger, ownMetal)
end

-- JobBaseCost() for a worker not on the job, worked out once per job per
-- update rather than once per worker.
local function SharedBaseCost(job)
	local cost = baseCosts[job.key]
	if not cost then
		cost = JobBaseCost(job)
		baseCosts[job.key] = cost
	end
	return cost
end

-- The only part of a job's cost that differs from worker to worker, other
-- than the worker's own job counting one fewer on it.
local function TravelCost(wx, wz, speed, buildDistance, job, travelFactor)
	local dx, dz = wx - job.x, wz - job.z
	local distance = math.sqrt(dx*dx + dz*dz) - buildDistance - (job.r or 0)
	return math.max(0, distance) / speed * travelFactor * options.travelWeight.value
end

local function Assign(unitID, job, frame)
	local oldKey = assignment[unitID]
	if oldKey then
		SetOurCount(oldKey, (ourCount[oldKey] or 1) - 1)
	end
	if job.phase then
		local issued = terraformIssued[job.key]
		if issued and job.owner == spGetMyTeamID() and job.terraunit then
			-- Join our own terraform for it by tag.
			spGiveOrderToUnit(unitID, CMD_LEVEL, {job.x, spGetGroundHeight(job.x, job.z), job.z, issued[1]}, 0)
		elseif job.terraunit then
			spGiveOrderToUnit(unitID, CMD_REPAIR, {job.terraunit}, 0)
		else
			StartTerraform(unitID, job, frame)
		end
		assignment[unitID] = job.key
		assignedCmd[unitID] = TERRAFORM_CMDS
		assignedFrame[unitID] = frame
		assignedSide[unitID] = job.econ and "econ" or nil
		assignedProduces[unitID] = job.produces
		SetOurCount(job.key, (ourCount[job.key] or 0) + 1)
		return
	end
	local cmd = JobCommand(job)
	local params
	if cmd == CMD_REPAIR and job.cmd < 0 then
		params = {job.unitID}
	elseif cmd < 0 then
		params = {job.x, job.y or spGetGroundHeight(job.x, job.z), job.z, job.h or 0}
	elseif job.target then
		params = {job.target}
	else
		params = {job.x, job.y or spGetGroundHeight(job.x, job.z), job.z, job.r or 0}
	end
	spGiveOrderToUnit(unitID, cmd, params, 0)
	assignment[unitID] = job.key
	assignedCmd[unitID] = cmd
	assignedFrame[unitID] = frame
	assignedSide[unitID] = (job.econ and "econ") or (job.factoryAssist and "units") or nil
	assignedProduces[unitID] = job.produces
	SetOurCount(job.key, (ourCount[job.key] or 0) + 1)
end

-- Whether a worker can take a job this update. Also notices a worker on a
-- job going idle (done, or gave up) or being given other orders.
local function CheckWorker(unitID, share, frame)
	if IsNanoframe(unitID) then
		return false
	end
	local key = assignment[unitID]
	if not key then
		return spGetUnitCurrentCommand(unitID) == nil -- idle, not under someone else's orders
	end
	if frame < assignedFrame[unitID] + ORDER_GRACE_FRAMES then
		return true -- our order may not have arrived yet
	end
	local cmd = spGetUnitCurrentCommand(unitID)
	if cmd == CMD_RAW_BUILD then
		cmd = spGetUnitCurrentCommand(unitID, 2) -- still walking to our order
	end
	local expected = assignedCmd[unitID]
	if cmd == expected or (type(expected) == "table" and expected[cmd]) then
		return true
	end
	if cmd then
		Unassign(unitID) -- given other orders
		return false
	end

	-- Idle after terraforming for a job: that part's done (or those
	-- terraunits are); the job goes on to its next part.
	if expected == TERRAFORM_CMDS then
		Unassign(unitID)
		return true
	end

	-- Went idle on the job. If the job is still there, the worker couldn't do
	-- it - except an area job of ours, which it goes idle on once the area has
	-- nothing left to do, so that job is done once the last of our workers on
	-- it goes idle (others may still be finishing their part of the area).
	local owner, jobId = SplitKey(key)
	local jobCmd = owner and share.GetCmdId(owner, jobId)
	-- Idle once its building is finished, with the job still there: the job
	-- is on to its wall, so the building part is done, not failed.
	local jobUnit = jobCmd and jobCmd < 0 and share.GetUnitID(owner, jobId)
	if jobUnit and spValidUnitID(jobUnit) and not IsNanoframe(jobUnit) then
		Unassign(unitID)
		return true
	end
	if jobCmd then
		local isOwnAreaJob = owner == spGetMyTeamID() and jobCmd >= 0 and not share.GetTarget(owner, jobId)
		if isOwnAreaJob and (ourCount[key] or 0) <= 1 then
			share.Delete(jobId)
		else
			failedUntil[unitID] = failedUntil[unitID] or {}
			failedUntil[unitID][key] = frame + FAILED_RETRY_FRAMES
		end
	elseif key:sub(1, 2) == "r#" then
		-- Backup reclaim: its square is done (or the rest is out of reach).
		-- The squares are only looked at again every few seconds, so don't
		-- send it straight back.
		failedUntil[unitID] = failedUntil[unitID] or {}
		failedUntil[unitID][key] = frame + FAILED_RETRY_FRAMES
	end
	Unassign(unitID)
	return true
end

-- Average build power of our GBC workers, the unit of preferred worker counts.
local DEFAULT_BUILD_POWER = 5
local function AverageBuildPower()
	local total, count = 0, 0
	for unitID in pairs(workers) do
		local unitDefID = spGetUnitDefID(unitID)
		local buildSpeed = unitDefID and UnitDefs[unitDefID].buildSpeed
		if buildSpeed and buildSpeed > 0 then
			total = total + buildSpeed
			count = count + 1
		end
	end
	return (count > 0) and (total / count) or DEFAULT_BUILD_POWER
end

local function IsCommander(unitDef)
	return unitDef.customParams.commtype or unitDef.customParams.dynamic_comm
end

-- Whether a job is in progress as far as our metal goes. Our team's job:
-- once it has a nanoframe or anyone's workers on it. An ally's: only while
-- our workers are on it, as building it spends our metal - one only its own
-- team builds doesn't compete with ours.
local function JobStarted(job)
	local ours = ourCount[job.key] or 0
	if job.owner ~= spGetMyTeamID() then
		return ours > 0
	end
	return job.unitID or job.others + ours > 0
end

-- How many large projects are in progress for us. Changes as UpdateWorkers
-- assigns workers, so it is counted again whenever a worker changes job.
local largeStarted = 0

local function CountLargeStarted(jobs)
	local count = 0
	for j = 1, #jobs do
		if jobs[j].large and JobStarted(jobs[j]) then
			count = count + 1
		end
	end
	return count
end

-- The largeConcurrentCost of starting a large project, or 0. Not part of
-- JobBaseCost, as it changes with every other large project's workers.
local function LargeStartCost(job)
	if job.large and largeStarted > 0 and not JobStarted(job) then
		return options.largeConcurrentCost.value * largeStarted
	end
	return 0
end

-- What a metal or energy building will make, per second: a mex its spot's
-- metal, a wind generator the average wind (a tidal one its fixed output),
-- anything else its energy output. Worked out once per job per update.
local function JobOutput(job)
	if job.output then
		return job.output
	end
	local ud = UnitDefs[-job.cmd]
	local cp = ud.customParams
	local output = 0
	if job.produces == "metal" then
		local best, bestDistSq = nil, 64 * 64
		local spots = WG.metalSpots or {}
		for i = 1, #spots do
			local distSq = DistanceSq(job.x, job.z, spots[i].x, spots[i].z)
			if distSq < bestDistSq then
				best, bestDistSq = spots[i], distSq
			end
		end
		output = best and (best.metal or 0) * (tonumber(cp.metal_extractor_mult) or 1) or 0
	elseif job.produces == "energy" then
		if cp.windgen and spGetGroundHeight(job.x, job.z) > 0 then
			output = ((Spring.GetGameRulesParam("WindMin") or 0) + (Spring.GetGameRulesParam("WindMax") or 0)) / 2
		else
			output = (ud.energyMake or 0) + (tonumber(cp.income_energy) or 0)
		end
	end
	job.output = output
	return output
end

-- The income still to come from our metal and energy projects in progress:
-- those with a nanoframe or workers on them. A small one counts in full as
-- soon as it's started, since it will be done soon; a large one (fusion,
-- singularity, ...) only as far as it's built, since until then it doesn't
-- stop us being short.
local function ProjectedIncome(jobs)
	local metal, energy = 0, 0
	local me = spGetMyTeamID()
	for j = 1, #jobs do
		local job = jobs[j]
		if (job.produces == "metal" or job.produces == "energy") and job.owner == me and JobStarted(job) then
			local output = JobOutput(job) * (job.large and (job.progress or 0) or 1)
			if job.produces == "metal" then
				metal = metal + output
			else
				energy = energy + output
			end
		end
	end
	return metal, energy
end

-- The jobs of the last worker AI update, by key, for the worker log.
local lastJobByKey = {}

local function UpdateWorkers(share)
	UpdateResources()
	UpdateSplit()
	dangerCache = {}
	if options.debugDanger.value then
		CollectDebugDanger()
	end
	local frame = spGetGameFrame()
	local jobs = CollectJobs(share, AverageBuildPower(), frame)
	local jobByKey = {}
	for j = 1, #jobs do
		jobByKey[jobs[j].key] = jobs[j]
	end
	lastJobByKey = jobByKey
	projectedMetal, projectedEnergy = ProjectedIncome(jobs)
	UpdateNeeds()
	baseCosts = {}
	largeStarted = CountLargeStarted(jobs)
	if options.debugCosts.value then
		debugCosts = {}
		for j = 1, #jobs do
			local job = jobs[j]
			debugCosts[j] = {job.x, job.y or spGetGroundHeight(job.x, job.z), job.z, SharedBaseCost(job) + LargeStartCost(job) + DangerCost(job.danger)}
		end
	end
	for unitID in pairs(workers) do
		local keyBefore = assignment[unitID]
		if CheckWorker(unitID, share, frame) then
			local unitDefID = spGetUnitDefID(unitID)
			local ud = unitDefID and UnitDefs[unitDefID]
			local wx, _, wz = spGetUnitPosition(unitID)
			if ud and wx and ud.speed > 0 then
				local speed = ud.speed * (spGetUnitRulesParam(unitID, "totalStaticMoveSpeedChange") or 1)
				local travelFactor = IsCommander(ud) and options.commanderTravelFactor.value or 1
				local currentKey = assignment[unitID]
				local failed = failedUntil[unitID]
				local best, bestCost, currentCost
				for j = 1, #jobs do
					local job = jobs[j]
					-- A job whose terraform a worker has just started (this
					-- update, or recently) waits for its terraunits before
					-- anyone else joins, so it isn't started twice.
					local issued = job.phase and not job.terraunit and job.key ~= currentKey and terraformIssued[job.key]
					local justStarted = issued and frame < issued[2] + TERRAFORM_ISSUE_WAIT
					if not (failed and failed[job.key] and failed[job.key] > frame)
							and not justStarted
							and spFindUnitCmdDesc(unitID, JobCommand(job)) then
						local base
						if job.key == currentKey then
							base = JobBaseCost(job, currentKey)
						else
							base = SharedBaseCost(job)
						end
						local cost = TravelCost(wx, wz, speed, ud.buildDistance, job, travelFactor) + base
							+ LargeStartCost(job) + WorkerDangerCost(ud, wx, wz, job)
						if job.key == currentKey then
							currentCost = cost
						end
						if not bestCost or cost < bestCost then
							best, bestCost = job, cost
						end
					end
				end

				if currentKey and not currentCost then
					-- Its job is gone (done, or removed): move on, or stop.
					if best then
						Assign(unitID, best, frame)
					else
						Unassign(unitID)
						spGiveOrderToUnit(unitID, CMD.STOP, {}, 0)
					end
				elseif best and best.key ~= currentKey
						and (not currentCost or bestCost + options.switchCost.value < currentCost) then
					Assign(unitID, best, frame)
				end
			end
		end
		local keyAfter = assignment[unitID]
		if keyAfter ~= keyBefore then
			largeStarted = CountLargeStarted(jobs)
			-- A metal or energy project gained or lost a worker: the incomes
			-- to come, and so the needs, change for the next worker.
			local before, after = keyBefore and jobByKey[keyBefore], keyAfter and jobByKey[keyAfter]
			if (before and before.produces) or (after and after.produces) then
				projectedMetal, projectedEnergy = ProjectedIncome(jobs)
				UpdateNeeds()
				baseCosts = {} -- every mex and energy job's cost depends on them
			end
		end
	end
	baseCosts = nil
	SteerPriority()
end

--------------------------------------------------------------------------------
-- Auto-built caretakers
--------------------------------------------------------------------------------
-- Enough caretakers beside our (producing) factories for them and the
-- factories to spend the units share of our metal income, or whatever of it
-- our GBC workers can't spend, if more: each spends up to its build power in
-- metal a second. As many are queued at once as we're short
-- (rounded to the nearest), each beside the factory with the fewest built
-- and queued, up to maxCaretakersPerFactory each.
-- Placed on a ring around the factory, within caretaker build range, and not
-- on its exit side.

local CARETAKER_CHECK_SECONDS = 5
local caretakerTimer = 0

-- Facing -> the direction units leave the factory in.
local FACING_DIR = {
	[0] = {0, 1},  -- south
	[1] = {1, 0},  -- east
	[2] = {0, -1}, -- north
	[3] = {-1, 0}, -- west
}

-- Our own caretaker jobs (not yet built) near a spot, and whether any is.
local function OwnCaretakerJobsNear(share, x, z, radius)
	local me = spGetMyTeamID()
	local jobIds = share.GetJobIds(me)
	local count = 0
	local rSq = radius * radius
	for i = 1, #jobIds do
		local jobId = jobIds[i]
		if share.GetCmdId(me, jobId) == -caretakerDefID and not share.GetUnitID(me, jobId)
				and DistanceSq(x, z, share.GetX(me, jobId), share.GetZ(me, jobId)) <= rSq then
			count = count + 1
		end
	end
	return count
end

-- Our caretakers within radius of a spot, as an array of unitIDs.
local function CaretakersNear(x, z, radius)
	local units = spGetUnitsInCylinder(x, z, radius, managedTeamID)
	local caretakers = {}
	if units then
		for i = 1, #units do
			if spGetUnitDefID(units[i]) == caretakerDefID then
				caretakers[#caretakers+1] = units[i]
			end
		end
	end
	return caretakers
end

-- A free spot for a caretaker beside a factory, or nil.
local function CaretakerSpot(factoryID, share)
	local fx, fy, fz = spGetUnitPosition(factoryID)
	local ud = UnitDefs[spGetUnitDefID(factoryID)]
	if not (fx and ud) then
		return nil
	end
	local exit = FACING_DIR[Spring.GetUnitBuildFacing(factoryID) or 0] or FACING_DIR[0]
	local halfSize = math.max(ud.xsize or 0, ud.zsize or 0) * 4
	local maxRadius = UnitDefs[caretakerDefID].buildDistance * 0.6
	for radius = halfSize + 48, math.max(halfSize + 48, maxRadius), 32 do
		for step = 0, 11 do
			local angle = step * math.pi / 6
			local dx, dz = math.sin(angle), math.cos(angle)
			-- Keep clear of the exit side (within 60 degrees of it).
			if dx * exit[1] + dz * exit[2] < 0.5 then
				local x, y, z = Spring.Pos2BuildPos(caretakerDefID, fx + dx * radius, fy, fz + dz * radius)
				if x and spTestBuildOrder(caretakerDefID, x, y, z, 0) == 2
						and OwnCaretakerJobsNear(share, x, z, 64) == 0 then
					return x, y, z
				end
			end
		end
	end
	return nil
end

local CARETAKER_NEED_FULL = 2 -- caretakers short for the full caretaker need bonus

local function QueueCaretakers(share)
	caretakerNeed = 0
	caretakerStats = {}
	if not (caretakerDefID and options.autoCaretakers.value) then
		return
	end
	local caretakerDef = UnitDefs[caretakerDefID]
	local range = caretakerDef.buildDistance
	local caretakerPower = math.max(1, caretakerDef.buildSpeed or 10)

	-- The GBC workers' build power: what the economy side can spend at most.
	-- Workers helping a factory are on the units side instead.
	local workerPower, helpingPower = 0, 0
	for unitID in pairs(workers) do
		if not IsNanoframe(unitID) then
			-- Workers only helping as a fallback (Help factories off) leave for
			-- the first job that comes up, so they count as free workers, not
			-- as standing in for caretakers.
			if assignedSide[unitID] == "units" and options.assistFactories.value then
				helpingPower = helpingPower + BuildPower(unitID)
			else
				workerPower = workerPower + BuildPower(unitID)
			end
		end
	end

	-- The build power the units side should have: the units share of our
	-- income - or more, when the workers can't spend all of the economy share,
	-- since the rest would only pile up. Only a factory can make more workers.
	-- Building spends metal and energy about 1:1, so what build power can
	-- spend is the lower of the two incomes: when energy is behind, more
	-- caretakers would only stall.
	-- Counting what's to come from mexes and energy under way (see
	-- ProjectedIncome), so caretakers are started along with the mexes and
	-- are ready when their income arrives.
	local income = math.min(metalIncome + projectedMetal, energyIncome + projectedEnergy)
	local target = math.max(income * (1 - options.econShare.value), income - workerPower)

	-- What's already spending it: the factories, the caretakers beside them
	-- (each counted once, even if beside two) and workers helping factories;
	-- then caretakers still queued, as they will.
	local power = helpingPower
	local unfinishedPower = 0 -- of those caretakers, the ones still nanoframes
	local counted = {}
	local candidates = {}
	for factoryID in pairs(factories) do
		if options.autoCaretakersIdleFactories.value or spGetUnitIsBuilding(factoryID) then
			power = power + BuildPower(factoryID)
			local fx, _, fz = spGetUnitPosition(factoryID)
			if fx then
				local near = CaretakersNear(fx, fz, range)
				for i = 1, #near do
					if not counted[near[i]] then
						counted[near[i]] = true
						power = power + caretakerPower
						if IsNanoframe(near[i]) then
							unfinishedPower = unfinishedPower + caretakerPower
						end
					end
				end
				candidates[#candidates+1] = {factoryID = factoryID, x = fx, z = fz, count = #near}
			end
		end
	end

	-- Metal piling up means the build power we have isn't spending it all,
	-- whatever it adds up to on paper (workers walking between jobs, a
	-- factory between units): then want enough more to spend what goes
	-- unspent.
	if metalHigh > 0 then
		target = math.max(target, power - unfinishedPower + math.max(0, metalIncome - metalPull))
	end

	-- How short we are of finished caretakers: queued and half-built ones
	-- still need workers to build them.
	local short = (target - (power - unfinishedPower)) / caretakerPower
	caretakerNeed = math.max(0, math.min(1, short / CARETAKER_NEED_FULL))
	caretakerStats = {target = target, have = power - unfinishedPower, workerPower = workerPower}

	power = power + OwnCaretakerJobsNear(share, 0, 0, math.huge) * caretakerPower
	-- Rounded to the nearest: half a caretaker short is enough to add one -
	-- or while metal is piling up, any shortfall at all.
	local toAdd = (target - power) / caretakerPower
	toAdd = (metalHigh > 0) and math.ceil(toAdd - 0.01) or math.floor(toAdd + 0.5)
	if toAdd <= 0 then
		return
	end
	-- As many at once as we're short, spread over the factories: each round
	-- adds one beside the factory with the fewest (built and queued), up to
	-- maxCaretakersPerFactory each.
	for i = 1, #candidates do
		candidates[i].count = candidates[i].count + OwnCaretakerJobsNear(share, candidates[i].x, candidates[i].z, range)
	end
	while toAdd > 0 do
		table.sort(candidates, function(a, b) return a.count < b.count end)
		local added = false
		for i = 1, #candidates do
			local candidate = candidates[i]
			if candidate.count < options.maxCaretakersPerFactory.value then
				local x, y, z = CaretakerSpot(candidate.factoryID, share)
				if x then
					share.Update({id = -caretakerDefID, x = x, y = y, z = z, h = 0})
					candidate.count = candidate.count + 1
					toAdd = toAdd - 1
					added = true
					break
				end
			end
		end
		if not added then
			return -- every factory is full, or has no room left
		end
	end
end

-- One infolog line on the economy, for the debugEconLog option. Build power
-- in metal a second: GBC workers by what they're on (mex, energy,
-- production - caretakers and factories -, helping a factory, anything else,
-- nothing), producing factories, and finished caretakers.
local function LogEconomy()
	local bp = {mex = 0, energy = 0, prod = 0, help = 0, other = 0, idle = 0}
	local workerTotal = 0
	for unitID in pairs(workers) do
		if not IsNanoframe(unitID) then
			local power = BuildPower(unitID)
			workerTotal = workerTotal + power
			local group
			if not assignment[unitID] then
				group = "idle"
			elseif assignedSide[unitID] == "units" then
				group = "help"
			elseif assignedProduces[unitID] == "metal" then
				group = "mex"
			elseif assignedProduces[unitID] == "energy" then
				group = "energy"
			elseif assignedProduces[unitID] == "production" then
				group = "prod"
			else
				group = "other"
			end
			bp[group] = bp[group] + power
		end
	end
	local factoryPower = 0
	for factoryID in pairs(factories) do
		if spGetUnitIsBuilding(factoryID) then
			factoryPower = factoryPower + BuildPower(factoryID)
		end
	end
	local caretakers, caretakerPower = 0, 0
	local units = spGetTeamUnits(managedTeamID) or {}
	for i = 1, #units do
		if spGetUnitDefID(units[i]) == caretakerDefID and not IsNanoframe(units[i]) then
			caretakers = caretakers + 1
			caretakerPower = caretakerPower + BuildPower(units[i])
		end
	end
	local seconds = math.floor(spGetGameFrame() / 30)
	spEcho(string.format("[GBC econ] %d:%02d"
		.. " | metal %.1f in (+%.1f coming), %.1f wanted | energy %.1f in (+%.1f coming)"
		.. " | need: metal %.2f energy %.2f, metal high %.2f, split %.2f (eco share %.2f)"
		.. " | workers %.0f: mex %.0f energy %.0f prod %.0f help %.0f other %.0f idle %.0f"
		.. " | factories %.0f, caretakers %d (%.0f)"
		.. " | caretaker target %.1f, have %.1f, need %.2f",
		seconds / 60, seconds % 60,
		metalIncome, projectedMetal, metalPull, energyIncome, projectedEnergy,
		metalNeed, energyNeed, metalHigh, splitImbalance, options.econShare.value,
		workerTotal, bp.mex, bp.energy, bp.prod, bp.help, bp.other, bp.idle,
		factoryPower, caretakers, caretakerPower,
		caretakerStats.target or 0, caretakerStats.have or 0, caretakerNeed))
end

-- What a job is, in words, for the worker log.
local function DescribeJob(job)
	local what
	if job.factoryAssist then
		what = "help factory #" .. job.target
	elseif job.backupReclaim then
		what = "backup reclaim"
	elseif job.cmd < 0 then
		what = "build " .. UnitDefs[-job.cmd].name
		if job.phase then
			what = what .. " (" .. job.phase .. ")"
		elseif job.progress then
			what = what .. string.format(" (%d%%)", job.progress * 100)
		end
	else
		local names = {[CMD_REPAIR] = "repair", [CMD_RECLAIM] = "reclaim", [CMD_RESURRECT] = "resurrect", [CMD_GUARD] = "guard"}
		what = (names[job.cmd] or ("cmd " .. job.cmd)) .. (job.target and " target" or " area")
		if job.terraform then
			what = what .. " (terraform)"
		end
	end
	if job.owner ~= spGetMyTeamID() then
		what = what .. " [ally " .. job.owner .. "]"
	end
	return what
end

-- One infolog line per GBC worker, for the debugWorkerLog option: its job,
-- the straight-line distance to it (less build range), the time that takes
-- at the worker's speed, and the job's cost (travel as weighted, plus the
-- rest).
local function LogWorkers()
	local seconds = math.floor(spGetGameFrame() / 30)
	local stamp = string.format("[GBC worker] %d:%02d", seconds / 60, seconds % 60)
	for unitID in pairs(workers) do
		local unitDefID = spGetUnitDefID(unitID)
		local ud = unitDefID and UnitDefs[unitDefID]
		local name = string.format("#%d %s", unitID, ud and ud.name or "?")
		local key = assignment[unitID]
		local job = key and lastJobByKey[key]
		local wx, _, wz = spGetUnitPosition(unitID)
		if IsNanoframe(unitID) then
			spEcho(stamp .. " " .. name .. ": unfinished")
		elseif not key then
			local cmd = spGetUnitCurrentCommand(unitID)
			spEcho(stamp .. " " .. name .. ": " .. (cmd and ("own orders (cmd " .. cmd .. ")") or "idle"))
		elseif not (job and wx and ud) then
			spEcho(stamp .. " " .. name .. ": " .. key .. " (job gone)")
		else
			local dx, dz = wx - job.x, wz - job.z
			local distance = math.max(0, math.sqrt(dx*dx + dz*dz) - ud.buildDistance - (job.r or 0))
			local speed = ud.speed * (spGetUnitRulesParam(unitID, "totalStaticMoveSpeedChange") or 1)
			local travelSeconds = speed > 0 and distance / speed or 0
			local travelFactor = IsCommander(ud) and options.commanderTravelFactor.value or 1
			local travel = TravelCost(wx, wz, speed, ud.buildDistance, job, travelFactor)
			local base = JobBaseCost(job, key) + LargeStartCost(job) + WorkerDangerCost(ud, wx, wz, job)
			spEcho(string.format("%s %s: %s | %.0f elmos, %.1fs away | cost %.1f = travel %.1f + rest %.1f",
				stamp, name, DescribeJob(job), distance, travelSeconds, travel + base, travel, base))
		end
	end
end

local ECON_LOG_SECONDS = 10
local econLogTimer = 0

local updateTimer = 0
function widget:Update(dt)
	caretakerTimer = caretakerTimer + dt
	econLogTimer = econLogTimer + dt
	updateTimer = updateTimer + dt
	if updateTimer < options.updateRate.value then
		return
	end
	updateTimer = 0
	local share = WG.GlobalBuildListShare
	if not share or spGetSpectatingState() then
		return
	end
	-- Our own jobs are ours to keep tidy even when we don't lead the team.
	CleanOwnJobs(share)
	debugCosts = nil
	debugDanger = nil
	if managedTeamID and options.workerAI.value then
		UpdateWorkers(share)
		if caretakerTimer >= CARETAKER_CHECK_SECONDS then
			caretakerTimer = 0
			QueueCaretakers(share)
		end
		if econLogTimer >= ECON_LOG_SECONDS then
			econLogTimer = 0
			if options.debugEconLog.value then
				LogEconomy()
			end
			if options.debugWorkerLog.value then
				LogWorkers()
			end
		end
	end
end

-- While GBC mode is on, offers every command our GBC workers could carry out
-- - their build options and repair/reclaim/resurrect - whatever is selected,
-- so jobs can be queued with no constructor selected. The command panel puts
-- these in the build tabs and orders like the selection's own commands, and
-- CommandNotify turns them into jobs before they reach any unit. Commands the
-- selection already has are skipped, so a selected constructor doesn't give
-- two copies of each.
--
-- Relies on the engine doing building placement (preview, facing, grid
-- snapping, line/area placement) for a widget-added build command that no
-- selected unit can build.
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

local areaMexCommands = {
	{
		id      = CMD_AREA_MEX,
		name    = 'Mex',
		action  = 'areamex',
		cursor  = 'Mex',
		tooltip = 'Area Mex: Click and drag to queue GBC mex jobs in an area.',
	},
	{
		id      = CMD_AREA_TERRA_MEX,
		name    = 'Terra Mex',
		action  = 'areaterramex',
		cursor  = 'Terramex',
		tooltip = 'Area Terra Mex: Click and drag to queue terraformed GBC mex jobs in an area.',
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
				local cmdDescs = Spring.GetUnitCmdDescs(unitID)
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

	-- Area mex (cmd_mex_placement.lua), which hands each spot to
	-- CommandNotifyMex below, when our workers can build a mex.
	for buildDefID in pairs(buildDefIDs) do
		if UnitDefs[buildDefID].customParams.ismex then
			for i = 1, #areaMexCommands do
				local command = areaMexCommands[i]
				if not existing[command.id] then
					customCommands[#customCommands+1] = {
						id      = command.id,
						type    = CMDTYPE.ICON_AREA,
						name    = command.name,
						action  = command.action,
						cursor  = command.cursor,
						tooltip = command.tooltip,
					}
					existing[command.id] = true
				end
			end
			break
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
-- Economy/units split presets, as buttons on GBC mode's orders tab.
local ECON_PRESETS = {
	{cmd = CMD_GBC_ECO, share = 0.8, name = 'Eco', action = 'gbceco',
		tooltip = 'Eco focus: spend 80% of build power on economy (mexes, energy, storage, pylons), 20% on units.'},
	{cmd = CMD_GBC_BALANCED, share = 0.5, name = 'Balanced', action = 'gbcbalanced',
		tooltip = 'Balanced: spend build power evenly between economy and units.'},
	{cmd = CMD_GBC_ARMY, share = 0.2, name = 'Army', action = 'gbcarmy',
		tooltip = 'Army focus: spend 80% of build power on units (factories and help for them), 20% on economy.'},
}

local function SetEconShare(share)
	if WG.SetWidgetOption then
		WG.SetWidgetOption(widget:GetInfo().name, options_path, 'econShare', share) -- saved like a menu change
	else
		options.econShare.value = share
	end
	Spring.ForceLayoutUpdate()
	spEcho(string.format("GBC: %d%% economy, %d%% units", share * 100 + 0.5, (1 - share) * 100 + 0.5))
end

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
		-- The command panel highlights the one in use (GetEconPreset).
		for i = 1, #ECON_PRESETS do
			local preset = ECON_PRESETS[i]
			customCommands[#customCommands+1] = {
				id      = preset.cmd,
				type    = CMDTYPE.ICON,
				tooltip = preset.tooltip,
				name    = preset.name,
				action  = preset.action,
			}
		end
		AddWorkerCommands(customCommands)
	end
end

function widget:CommandNotify(cmdID, params, opts)
	-- The player set build priority themselves: never touch those units'.
	if cmdID == CMD_PRIORITY then
		local selectedUnits = spGetSelectedUnits()
		for i = 1, #selectedUnits do
			playerPriority[selectedUnits[i]] = true
			loweredByUs[selectedUnits[i]] = nil
		end
		return false
	end

	if cmdID == CMD_GLOBAL_BUILD then
		SetGlobalBuildState(params[1])
		return true
	end

	for i = 1, #ECON_PRESETS do
		if cmdID == ECON_PRESETS[i].cmd then
			SetEconShare(ECON_PRESETS[i].share)
			return true
		end
	end

	-- Handled even if GBC mode was switched off while the command was on the
	-- cursor, so it never reaches the selected units.
	if cmdID == CMD_GBCANCEL then
		if #params >= 4 then
			RemoveJobsInCircle(params[1], params[3], params[4])
		end
		return true
	end

	if not active or not WG.GlobalBuildListShare then
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
				x, y, z = Spring.GetFeaturePosition(target - Game.maxUnits)
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

-- The command of the economy/units preset in use, or nil if the economy
-- share was set to something else.
function externalFunctions.GetEconPreset()
	for i = 1, #ECON_PRESETS do
		if math.abs(options.econShare.value - ECON_PRESETS[i].share) < 0.01 then
			return ECON_PRESETS[i].cmd
		end
	end
end

-- The toggle's current hotkey, readable, or "" if it has none.
function externalFunctions.GetHotkey()
	local hotkey = WG.crude and WG.crude.GetOptionHotkey and WG.crude.GetOptionHotkey(options.toggle.path, options.toggle)
	return hotkey or ""
end

-- How many jobs we own in the shared list.
function externalFunctions.GetJobCount()
	local share = WG.GlobalBuildListShare
	if not share then
		return 0
	end
	return #share.GetJobIds(spGetMyTeamID())
end

-- For widgets that plan several builds at once (eg. cmd_energy_grid.lua) and
-- hand them to GBC while GBC mode is on. Each returns true if the job was
-- queued, false if GBC mode is off (the caller then orders units itself).
-- elevation (optional): absolute height to level the footprint to first.
function externalFunctions.QueueBuild(cmdID, x, y, z, facing, elevation)
	if not (active and WG.GlobalBuildListShare) then
		return false
	end
	QueueJob({id = cmdID, x = x, y = y or spGetGroundHeight(x, z), z = z, h = facing or 0, elevation = elevation})
	return true
end

-- Help finish (repair) a unit, eg. an allied nanoframe.
function externalFunctions.QueueRepair(targetID)
	if not (active and WG.GlobalBuildListShare) then
		return false
	end
	local x, y, z = spGetUnitPosition(targetID)
	if not x then
		return false
	end
	QueueJob({id = CMD_REPAIR, target = targetID, x = x, y = y, z = z})
	return true
end

-- The GBC workers, as an array of unitIDs.
function externalFunctions.GetWorkers()
	local list = {}
	for unitID in pairs(workers) do
		list[#list + 1] = unitID
	end
	return list
end

-- The interface other widgets already use to talk to Global Build Command:
-- cmd_mex_placement.lua, gui_lasso_terraform.lua and
-- gui_persistent_build_height.lua offer it their orders before giving them,
-- and don't give an order it handles (returns true); gui_chili_core_selector
-- and gui_selection_hierarchy ask whether it controls a unit.
local compatibility = {
	-- Mex (and area mex) placement: queued as GBC jobs while GBC mode is on.
	-- terra (optional, from area mex's terraform modes): {elevation = ...} to
	-- bury the mex, or {wall = ...} to wall it.
	CommandNotifyMex = function(cmdID, params, cmdOpts, isAreaMex, terra)
		if not (active and WG.GlobalBuildListShare) then
			return false
		end
		QueueJob({
			id = cmdID, x = params[1], y = params[2] or spGetGroundHeight(params[1], params[3]), z = params[3], h = params[4] or 0,
			elevation = terra and terra.elevation, wall = terra and terra.wall,
		})
		return true
	end,
	-- A building at a height (persistent build height), offered before any
	-- terraform is ordered: queued as one job with that elevation.
	CommandNotifyBuildAtHeight = function(cmdID, x, y, z, facing)
		if not (active and WG.GlobalBuildListShare) then
			return false
		end
		QueueJob({id = cmdID, x = x, y = y, z = z, h = facing or 0, elevation = y})
		return true
	end,
	-- Terraform (lasso terraform): while GBC mode is on, the terraform still
	-- goes ahead (the constructor was already given CMD_TERRAFORM_INTERNAL), but
	-- no constructors are sent to it; the terraunits it creates are captured as
	-- repair jobs instead.
	CommandNotifyTF = function(unitArray, shift)
		if not (active and WG.GlobalBuildListShare and terraunitDefID) then
			return false
		end
		captureTerraformUntil = spGetGameFrame() + TERRAFORM_CAPTURE_FRAMES
		return true
	end,
	-- Lasso terraform's "level, then build": the drawn terraform is captured as
	-- above, and the building queued as a job that waits until the terraform
	-- around it is done. (Persistent build height uses
	-- CommandNotifyBuildAtHeight instead.)
	CommandNotifyRaiseAndBuild = function(unitArray, cmdID, x, y, z, facing, shift)
		if not (active and WG.GlobalBuildListShare and terraunitDefID) then
			return false
		end
		captureTerraformUntil = spGetGameFrame() + TERRAFORM_CAPTURE_FRAMES
		QueueJob({id = cmdID, x = x, y = y, z = z, h = facing or 0})
		return true
	end,
	CommandNotifyPreQue = function()
	end,
	IsControllingUnit = function(unitID)
		return options.workerAI.value and workers[unitID] ~= nil
	end,
	-- GBC doesn't change selection ranks.
	IsSelectionOverrideSet = false,
	SelectionOverrideRank = 0,
}

function widget:Initialize()
	UpdateManagedTeam(true)
	WG.GlobalBuildCommandV2 = externalFunctions
	WG.GlobalBuildCommand = compatibility
end

function widget:Shutdown()
	RestoreAllPriorities()
	WG.GlobalBuildCommandV2 = nil
	if WG.GlobalBuildCommand == compatibility then
		WG.GlobalBuildCommand = nil
	end
end

function widget:PlayerChanged(playerID)
	UpdateManagedTeam()
end

function widget:UnitCreated(unitID, unitDefID, unitTeam)
	if managedTeamID and unitTeam == managedTeamID then
		AddBuilder(unitID, unitDefID)
	end
	if unitDefID == terraunitDefID and terraunitDefID and spAreTeamsAllied(unitTeam, spGetMyTeamID()) then
		local ux, uy, uz = spGetUnitPosition(unitID)
		if ux then
			alliedTerraunits[unitID] = {ux, uz}
			if unitTeam == spGetMyTeamID() and spGetGameFrame() <= captureTerraformUntil and WG.GlobalBuildListShare then
				QueueJob({id = CMD_REPAIR, target = unitID, x = ux, y = uy, z = uz})
			end
		end
	end
	if not spGetSpectatingState() and spAreTeamsAllied(unitTeam, spGetMyTeamID()) then
		LinkNewUnit(unitID, unitDefID)
	end
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	local share = WG.GlobalBuildListShare
	if not share then
		return
	end
	local owner, jobId = share.GetJobByUnitID(unitID)
	if owner and owner == spGetMyTeamID() then
		-- A wall still to raise around it keeps the job going.
		local wall = share.GetWall(owner, jobId)
		if not (wall and WallNeeded(UnitDefs[unitDefID], share.GetX(owner, jobId), share.GetZ(owner, jobId), share.GetH(owner, jobId) or 0, wall)) then
			share.Delete(jobId)
		end
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
	-- The morphed unit carries on with the old one's orders, so its job too.
	if morphedTo and assignment[unitID] and workers[morphedTo] then
		assignment[morphedTo] = assignment[unitID]
		assignedCmd[morphedTo] = assignedCmd[unitID]
		assignedFrame[morphedTo] = assignedFrame[unitID]
		assignment[unitID] = nil
	end
	Unassign(unitID)
	failedUntil[unitID] = nil
	workers[unitID] = nil
	factories[unitID] = nil
	alliedTerraunits[unitID] = nil
	loweredByUs[unitID] = nil
	playerPriority[unitID] = nil

	-- A build job's unfinished unit was destroyed: the job goes back to
	-- needing building from scratch. (A finished one's job was removed in
	-- UnitFinished.)
	local share = WG.GlobalBuildListShare
	if share then
		local owner, jobId = share.GetJobByUnitID(unitID)
		if owner and owner == spGetMyTeamID() then
			SetOwnJobUnitID(share, jobId, nil)
		end
	end
end

function widget:UnitGiven(unitID, unitDefID, newTeam, oldTeam)
	if managedTeamID and newTeam == managedTeamID then
		AddBuilder(unitID, unitDefID)
	end
end

function widget:UnitTaken(unitID, unitDefID, oldTeam, newTeam)
	if oldTeam == managedTeamID and newTeam ~= managedTeamID then
		Unassign(unitID)
		RestorePriority(unitID)
		workers[unitID] = nil
		factories[unitID] = nil
	end
end

-- Esc cancels an area removal in progress, otherwise closes GBC mode.
function widget:KeyPress(key)
	if not (active and key == KEYSYMS.ESCAPE) then
		return false
	end
	if dragX then
		StopDrag()
	else
		Dismiss()
	end
	return true
end

-- Right-drag removes jobs in a circle; a right-click closes GBC mode.
function widget:MousePress(x, y, button)
	if not active or button ~= 3 then
		return false
	end
	local mx, mz = mousePos()
	if mx then
		dragX, dragZ, dragR = mx, mz, 0
		dragScreenX, dragScreenY = x, y
	else
		Dismiss() -- off the map there's nothing to drag over
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
	local dx, dy = x - dragScreenX, y - dragScreenY
	if dx*dx + dy*dy <= CLICK_MAX_MOVE_SQ then
		Dismiss()
	else
		RemoveJobsInCircle(dragX, dragZ, dragR)
		StopDrag()
	end
	return true
end

local DEBUG_COST_HEIGHT = 40 -- elmos above the job
local DEBUG_COST_SIZE = 16

function widget:DrawWorld()
	if dragX then
		gl.Color(1, 0.3, 0.3, 0.3)
		gl.DrawGroundCircle(dragX, spGetGroundHeight(dragX, dragZ), dragZ, dragR, 32)
		gl.Color(1, 1, 1, 1)
	end
	if debugCosts and options.debugCosts.value and not Spring.IsGUIHidden() then
		for i = 1, #debugCosts do
			local entry = debugCosts[i]
			gl.PushMatrix()
			gl.Translate(entry[1], entry[2] + DEBUG_COST_HEIGHT, entry[3])
			gl.Billboard()
			gl.Text(string.format("%.1f", entry[4]), 0, 0, DEBUG_COST_SIZE, "co")
			gl.PopMatrix()
		end
	end
	if debugDanger and options.debugDanger.value and not Spring.IsGUIHidden() then
		for i = 1, #debugDanger do
			local entry = debugDanger[i]
			gl.PushMatrix()
			gl.Translate(entry[1], entry[2] + DEBUG_COST_HEIGHT, entry[3])
			gl.Billboard()
			if entry[4] > 0 then
				gl.Color(1, 0.3, 0.3, 1)
			elseif entry[6] > 0 then
				gl.Color(1, 0.8, 0.2, 1) -- enemies, but outweighed
			else
				gl.Color(0.6, 0.6, 0.6, 0.6)
			end
			gl.Text(string.format("%.0f (%.1fs)", entry[4], entry[5]), 0, 0, DEBUG_COST_SIZE, "co")
			if entry[6] > 0 or entry[7] > 0 or entry[8] > 0 then
				gl.Text(string.format("e%.0f a%.0f d%.0f", entry[6], entry[7], entry[8]), 0, -DEBUG_COST_SIZE, DEBUG_COST_SIZE * 0.75, "co")
			end
			gl.PopMatrix()
		end
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
