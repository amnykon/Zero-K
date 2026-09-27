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
--           button (on by default), and the worker AI assigns them to your
--           and your allies' jobs by cost (see the Worker AI section;
--           costs are under Settings/Unit Behaviour/Worker AI/Costs).
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
local spGetPlayerList     = Spring.GetPlayerList
local spGetPlayerInfo     = Spring.GetPlayerInfo
local spGetMyAllyTeamID   = Spring.GetMyAllyTeamID
local spAreTeamsAllied    = Spring.AreTeamsAllied

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
-- failedUntil[unitID][key] = game frame until which that worker won't retry a
-- job it went idle on without finishing (eg. couldn't reach it).
local failedUntil = {}
local Unassign -- defined in the Worker AI section

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
	'switchCost',
	'targetFinishTime', 'minPreferred', 'maxPreferred', 'areaPreferred',
	'shortHandedBonus', 'overStaffedCost',
	'largeMinMetal', 'completionWeight', 'completionMinProgress',
	'lowPriorityCost', 'highPriorityDiscount',
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
	completionWeight = CostOption('Large project: completion bonus',
		'Taken off a large project\'s cost, scaled by its build progress, so nearly finished ones pull workers in to finish them.', 20),
	completionMinProgress = {
		name = 'Large project: completion bonus from',
		desc = 'Build progress (0 to 1) a large project needs before the completion bonus applies and its over-staffed cost starts fading.',
		type = 'number', min = 0, max = 1, step = 0.05, value = 0.5,
		path = COSTS_PATH,
	},
	lowPriorityCost = CostOption('Low priority job cost',
		'Added to jobs marked low priority.', 15),
	highPriorityDiscount = CostOption('High priority job discount',
		'Taken off jobs the player marked high priority.', 30, 120),
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
	for unitID in pairs(assignment) do
		Unassign(unitID)
	end
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
	local share = WG.GlobalBuildQueueShare
	if not share then
		return
	end
	local myPlayerID = spGetMyPlayerID()
	local rSq = r * r
	local jobIds = share.GetJobIds(myPlayerID)
	for i = 1, #jobIds do
		local jobId = jobIds[i]
		local jx, jz = share.GetX(myPlayerID, jobId), share.GetZ(myPlayerID, jobId)
		if jx and DistanceSq(x, z, jx, jz) <= rSq then
			share.Delete(jobId)
		end
	end
end

local function QueueJob(job)
	WG.GlobalBuildQueueShare.Update(job)
end

--------------------------------------------------------------------------------
-- Callins
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Worker AI
--------------------------------------------------------------------------------
-- Every updateRate seconds, each GBC worker that is idle or on a GBC job picks
-- the job with the lowest cost, from our own and our allies' queues in the job
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
--   - priority: low priority jobs cost more, and jobs the player marked high
--     priority less. GBC never marks anything high itself.
--   - switching: a worker already on a job only moves to another one if it's
--     cheaper by more than the switch cost.
-- A worker the player (or anything else) gives other orders is left alone
-- until it's idle again. Switching a worker off (Global Build state) only
-- stops GBC managing it; it isn't stopped.
--
-- Not yet: pathing (a job across water from a land worker looks reachable
-- until the worker gives up on it), and the resource-need kickers.

-- Frames after giving an order during which the worker's current command
-- isn't checked yet, since the order takes a moment to arrive.
local ORDER_GRACE_FRAMES = 60
-- How long a worker leaves a job alone after going idle on it without
-- finishing it.
local FAILED_RETRY_FRAMES = 30 * 30
-- How close (elmos) a new unit has to be to a build job's spot to be its unit.
local LINK_DISTANCE = 24

local function IsNanoframe(unitID)
	local _, _, beingBuilt = spGetUnitIsStunned(unitID)
	return beingBuilt
end

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
	local share = WG.GlobalBuildQueueShare
	if share then
		local owner, jobId = SplitKey(key)
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
	SetOurCount(key, (ourCount[key] or 1) - 1)
end

ReleaseAllWorkers = function()
	for unitID in pairs(assignment) do
		Unassign(unitID)
	end
end

-- Rewrites one of our own jobs with a new unitID (the unit being built for
-- it, or nil), keeping its other fields - Update() derives the same jobId.
local function SetOwnJobUnitID(share, jobId, unitID)
	local me = spGetMyPlayerID()
	share.Update({
		id = share.GetCmdId(me, jobId),
		x = share.GetX(me, jobId), y = share.GetY(me, jobId), z = share.GetZ(me, jobId),
		h = share.GetH(me, jobId), r = share.GetR(me, jobId),
		target = share.GetTarget(me, jobId),
		reach = share.GetReach(me, jobId),
		priority = share.GetPriority(me, jobId),
		unitID = unitID,
	})
end

-- A new unit (anyone's on our side) that sits on one of our build jobs'
-- spots, of the right type, is that job's unit.
local function LinkNewUnit(unitID, unitDefID)
	local share = WG.GlobalBuildQueueShare
	if not share then
		return
	end
	local me = spGetMyPlayerID()
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
	local me = spGetMyPlayerID()
	local jobIds = share.GetJobIds(me)
	for i = 1, #jobIds do
		local jobId = jobIds[i]
		local cmd = share.GetCmdId(me, jobId)
		local target = share.GetTarget(me, jobId)
		local done = false
		if cmd < 0 then
			if not share.GetUnitID(me, jobId) then
				done = spTestBuildOrder(-cmd, share.GetX(me, jobId), share.GetY(me, jobId), share.GetZ(me, jobId), share.GetH(me, jobId) or 0) == 0
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

-- Every job in our own and our allies' queues that can still be worked on,
-- with what the cost needs precomputed once per update.
local function CollectJobs(share, avgBuildPower)
	local jobs = {}
	local myAllyTeamID = spGetMyAllyTeamID()
	local players = spGetPlayerList()
	for i = 1, #players do
		local owner = players[i]
		local _, _, isSpec, _, allyTeamID = spGetPlayerInfo(owner, false)
		if isSpec == false and allyTeamID == myAllyTeamID then
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
					jobs[#jobs+1] = {
						key = key, owner = owner, jobId = jobId, cmd = cmd,
						x = x, y = share.GetY(owner, jobId), z = z,
						h = share.GetH(owner, jobId), r = share.GetR(owner, jobId),
						target = target, unitID = unitID, progress = progress,
						preferred = PreferredWorkers(unitDef, avgBuildPower),
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
	return jobs
end

-- The command a worker needs for a job: a build job whose unit has started is
-- helped with repair (which also works on an ally's unit).
local function JobCommand(job)
	if job.cmd < 0 and job.unitID then
		return CMD_REPAIR
	end
	return job.cmd
end

local function JobCost(wx, wz, speed, buildDistance, job, currentKey)
	local dx, dz = wx - job.x, wz - job.z
	local distance = math.sqrt(dx*dx + dz*dz) - buildDistance - (job.r or 0)
	local cost = math.max(0, distance) / speed

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

	if job.priority == 0 then
		cost = cost + options.lowPriorityCost.value
	elseif job.priority == 1 then
		cost = cost - options.highPriorityDiscount.value
	end
	return cost
end

local function Assign(unitID, job, frame)
	local oldKey = assignment[unitID]
	if oldKey then
		SetOurCount(oldKey, (ourCount[oldKey] or 1) - 1)
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
	if cmd == assignedCmd[unitID] then
		return true
	end
	if cmd then
		Unassign(unitID) -- given other orders
		return false
	end

	-- Went idle on the job. If the job is still there, the worker couldn't do
	-- it - except an area job of ours, which it goes idle on once the area has
	-- nothing left to do, so that job is done once the last of our workers on
	-- it goes idle (others may still be finishing their part of the area).
	local owner, jobId = SplitKey(key)
	local jobCmd = share.GetCmdId(owner, jobId)
	if jobCmd then
		local isOwnAreaJob = owner == spGetMyPlayerID() and jobCmd >= 0 and not share.GetTarget(owner, jobId)
		if isOwnAreaJob and (ourCount[key] or 0) <= 1 then
			share.Delete(jobId)
		else
			failedUntil[unitID] = failedUntil[unitID] or {}
			failedUntil[unitID][key] = frame + FAILED_RETRY_FRAMES
		end
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

local function UpdateWorkers(share)
	local jobs = CollectJobs(share, AverageBuildPower())
	local frame = spGetGameFrame()
	for unitID in pairs(workers) do
		if CheckWorker(unitID, share, frame) then
			local unitDefID = spGetUnitDefID(unitID)
			local ud = unitDefID and UnitDefs[unitDefID]
			local wx, _, wz = spGetUnitPosition(unitID)
			if ud and wx and ud.speed > 0 then
				local speed = ud.speed * (spGetUnitRulesParam(unitID, "totalStaticMoveSpeedChange") or 1)
				local currentKey = assignment[unitID]
				local failed = failedUntil[unitID]
				local best, bestCost, currentCost
				for j = 1, #jobs do
					local job = jobs[j]
					if not (failed and failed[job.key] and failed[job.key] > frame)
							and spFindUnitCmdDesc(unitID, JobCommand(job)) then
						local cost = JobCost(wx, wz, speed, ud.buildDistance, job, currentKey)
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
	end
end

local updateTimer = 0
function widget:Update(dt)
	updateTimer = updateTimer + dt
	if updateTimer < options.updateRate.value then
		return
	end
	updateTimer = 0
	local share = WG.GlobalBuildQueueShare
	if not share or spGetSpectatingState() then
		return
	end
	-- Our own jobs are ours to keep tidy even when we don't lead the team.
	CleanOwnJobs(share)
	if managedTeamID and options.workerAI.value then
		UpdateWorkers(share)
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
	if not spGetSpectatingState() and spAreTeamsAllied(unitTeam, spGetMyTeamID()) then
		LinkNewUnit(unitID, unitDefID)
	end
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	local share = WG.GlobalBuildQueueShare
	if not share then
		return
	end
	local owner, jobId = share.GetJobByUnitID(unitID)
	if owner and owner == spGetMyPlayerID() then
		share.Delete(jobId)
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

	-- A build job's unfinished unit was destroyed: the job goes back to
	-- needing building from scratch. (A finished one's job was removed in
	-- UnitFinished.)
	local share = WG.GlobalBuildQueueShare
	if share then
		local owner, jobId = share.GetJobByUnitID(unitID)
		if owner and owner == spGetMyPlayerID() then
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
