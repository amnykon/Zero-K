--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--
--  file:    dbg_gbc_queue_share_test.lua
--  brief:   Manual test tool for gui_global_build_queue_ally.lua - lets you
--           queue and remove build jobs by hand, with no real GBC and no
--           worker allocation, so the sharing/networking/rendering side of
--           that widget can be exercised in a real game.
--
--  Usage:
--    Tab           - toggle test mode on/off
--    left click    - while a build command is active (select any of your own
--                    units and pick a building from its build menu, same as
--                    a normal placement), queues a build job at the cursor
--                    instead of actually ordering anything built.
--    right drag    - remove every job this tool queued inside the circle.
--    escape        - cancel an in-progress right-drag.
--
--  Not implemented (out of scope for this tool): repair/reclaim/resurrect
--  jobs, and worker assignment (Assist()) - this only exercises Update()/
--  Delete(), the part of WG.GlobalBuildQueueShare that has no real GBC yet.
--
--  Job identity is assigned by Update() itself (see gui_global_build_queue_
--  ally.lua), so this tool never computes anything like a hash - it just
--  keeps whatever jobId each Update() call hands back, to pass to Delete()
--  later. Note this means clicking the same spot twice queues two separate
--  overlapping jobs rather than replacing the first (right-drag over both
--  to clean up) - fine for a manual test tool, unlike a real GBC which
--  would want to recognize "the same job" across repeated calls itself.
--
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

function widget:GetInfo()
	return {
		name      = "GBC Queue Share Test",
		desc      = "Debug tool: manually queue/remove build jobs via WG.GlobalBuildQueueShare, with no real GBC. Tab toggles it.",
		author    = "amnykon",
		date      = "September 26, 2026",
		license   = "GNU GPL, v2 or later",
		layer     = 1001,
		enabled   = true,
	}
end

include("keysym.lua")

local spGetActiveCommand = Spring.GetActiveCommand
local spGetMouseState    = Spring.GetMouseState
local spTraceScreenRay   = Spring.TraceScreenRay
local spGetGroundHeight  = Spring.GetGroundHeight
local spEcho             = Spring.Echo

local floor = math.floor
local sqrt  = math.sqrt

local function DistanceSq(x1, z1, x2, z2)
	return (x1 - x2) * (x1 - x2) + (z1 - z2) * (z1 - z2)
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local active = false -- test mode on/off, toggled by Tab

-- Every job this tool has queued (jobId -> {x, z}), so a right-drag knows
-- what it's allowed to remove without touching anything else's jobs. jobId
-- is whatever Update() below assigned - this tool never computes one itself.
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
	spEcho("GBC Queue Share Test: " .. (active and "ON (left click to queue, right-drag to remove)" or "OFF"))
end

--------------------------------------------------------------------------------
-- Callins
--------------------------------------------------------------------------------

function widget:KeyPress(key)
	if key == KEYSYMS.TAB then
		SetActive(not active)
		return true
	end
	if active and dragX and key == KEYSYMS.ESCAPE then
		StopDrag()
		return true
	end
	return false
end

function widget:MousePress(x, y, button)
	if not active then
		return false
	end

	if button == 1 then
		local _, activeCmdID = spGetActiveCommand()
		if not (activeCmdID and activeCmdID < 0) then
			return false -- no build command active - let the click do whatever it would normally do
		end
		local mx, mz = mousePos()
		if mx then
			local x0, z0 = floor(mx), floor(mz)
			local y0 = spGetGroundHeight(x0, z0)
			if WG.GlobalBuildQueueShare then
				local jobId = WG.GlobalBuildQueueShare.Update(nil, {id = activeCmdID, x = x0, y = y0, z = z0, h = 0})
				myJobs[jobId] = {x = x0, z = z0}
			end
		end
		return true -- consumed either way, so a real selected unit never gets a real build order
	end

	if button == 3 then
		local mx, mz = mousePos()
		if mx then
			dragX, dragZ, dragR = mx, mz, 0
		end
		return true
	end

	return false
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
