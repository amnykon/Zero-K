--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--
--  file:    dbg_gbc_queue_share_test.lua
--  brief:   Start of a new Global Build Command. While GBC mode is on, every
--           build/repair/reclaim/resurrect order you give is queued into
--           WG.GlobalBuildQueueShare (gui_global_build_queue_ally.lua)
--           instead of being handed to the selected units, so you can keep
--           an army selected and still queue jobs for your constructors.
--           No worker allocation yet.
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
--    escape        - cancel an in-progress right-drag.
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
		name      = "GBC Queue Share Test",
		desc      = "Start of a new Global Build Command: while toggled on (Tab by default), build/repair/reclaim/resurrect orders are queued into WG.GlobalBuildQueueShare instead of given to the selected units.",
		author    = "amnykon",
		date      = "September 26, 2026",
		license   = "GNU GPL, v2 or later",
		layer     = 1001, -- CommandNotify runs from the highest layer down, so this sees orders before most other widgets
		enabled   = true,
	}
end

include("keysym.lua")

local spGetMouseState     = Spring.GetMouseState
local spTraceScreenRay    = Spring.TraceScreenRay
local spGetGroundHeight   = Spring.GetGroundHeight
local spGetUnitPosition   = Spring.GetUnitPosition
local spGetFeaturePosition = Spring.GetFeaturePosition
local spEcho              = Spring.Echo

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

-- Queues one job and remembers it for right-drag removal.
local function QueueJob(job)
	local jobId = WG.GlobalBuildQueueShare.Update(job)
	myJobs[jobId] = {x = job.x, z = job.z}
end

--------------------------------------------------------------------------------
-- Callins
--------------------------------------------------------------------------------

function widget:CommandNotify(cmdID, params, opts)
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
	if WG.GlobalBuildQueueShare then
		local rSq = dragR * dragR
		for jobId, pos in pairs(myJobs) do
			if DistanceSq(dragX, dragZ, pos.x, pos.z) <= rSq then
				WG.GlobalBuildQueueShare.Delete(jobId)
				myJobs[jobId] = nil
			end
		end
	end
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
	local hotkey = WG.crude and WG.crude.GetOptionHotkey and WG.crude.GetOptionHotkey(options.toggle.path, options.toggle)
	local label = "GBC"
	if hotkey and hotkey ~= "" then
		label = label .. " (" .. hotkey .. ")"
	end
	gl.Color(1.0, 0.8, 0.2, 1)
	gl.Text(label, mx + 18, my - 28, 14, "o")
	gl.Color(1, 1, 1, 1)
end
