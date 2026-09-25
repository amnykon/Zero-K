--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--
--  file:    gui_global_build_queue_ally.lua
--  brief:   Shows allied players' (and, for spectators, everyone's) Global Build
--           Command queue jobs.
--
--  Unlike "Global Build Command" itself, this widget is on by default: it only
--  displays information, and never touches anyone's units.
--
--  Note: This widget currently has nothing to display, because nothing calls
--  WG.GlobalBuildQueueShare.SetLocalQueue() yet. That hookup into
--  unit_global_build_command.lua (or any other queue-like widget) is a
--  separate, later change. This file only implements the share/receive/draw
--  side of the feature, plus its public API.
--
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

function widget:GetInfo()
	return {
		name      = "Global Build Queue (Ally View)",
		desc      = "Shows allied players' Global Build Command queues (and, for spectators, every player's). Nothing to see yet unless something calls the SetLocalQueue API.",
		author    = "amnykon",
		date      = "September 25, 2026",
		license   = "GNU GPL, v2 or later",
		layer     = 11, -- after unit_global_build_command.lua's own drawing (layer 10)
		enabled   = true, -- on by default, since it's pure information
	}
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Options -----------------------------------------------------------------

options_path = 'Settings/Unit Behaviour/Worker AI'
options_order = {
	'allyQueueAlwaysShow',
}
options = {
	allyQueueAlwaysShow = {
		name = 'Always Show Ally Build Queue',
		type = 'bool',
		desc = 'Show allied (and, while spectating, all) players\' Global Build Command queues at all times.\nOtherwise they are only shown while \255\200\200\200shift\255\255\255\255 is held.\n (default = false)',
		value = false,
	},
}

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Declarations --------------------------------------------------------------

-- "Localized" API calls, because they run ~33% faster in lua.
local spGetMyPlayerID       = Spring.GetMyPlayerID
local spGetPlayerInfo       = Spring.GetPlayerInfo
local spSendLuaUIMsg        = Spring.SendLuaUIMsg
local spGetUnitPosition     = Spring.GetUnitPosition
local spGetFeaturePosition  = Spring.GetFeaturePosition
local spValidUnitID         = Spring.ValidUnitID
local spValidFeatureID      = Spring.ValidFeatureID
local spIsGUIHidden         = Spring.IsGUIHidden
local spGetModKeyState      = Spring.GetModKeyState
local spIsAABBInView        = Spring.IsAABBInView
local spIsSphereInView      = Spring.IsSphereInView

local glColor        = gl.Color
local glTexture       = gl.Texture
local glTexRect       = gl.TexRect
local glBillboard     = gl.Billboard
local glPushMatrix    = gl.PushMatrix
local glPopMatrix     = gl.PopMatrix
local glLoadIdentity  = gl.LoadIdentity
local glTranslate     = gl.Translate
local glRotate        = gl.Rotate
local glUnitShape     = gl.UnitShape
local glVertex        = gl.Vertex
local glBeginEnd      = gl.BeginEnd
local glGroundCircle  = gl.DrawGroundCircle
local glLineWidth     = gl.LineWidth
local glDepthTest     = gl.DepthTest
local GL_LINE_STRIP   = GL.LINE_STRIP

local CMD_REPAIR    = CMD.REPAIR
local CMD_RECLAIM   = CMD.RECLAIM
local CMD_RESURRECT = CMD.RESURRECT

local floor = math.floor

-- Zero-K specific icons, matching unit_global_build_command.lua's own job icons.
local rep_icon = "LuaUI/Images/commands/Bold/repair.png"
local rec_icon = "LuaUI/Images/commands/Bold/reclaim.png"
local res_icon = "LuaUI/Images/commands/Bold/resurrect.png"
local rep_color = {0.0, 0.8, 0.4, 1.0}
local rec_color = {0.6, 0.0, 1.0, 1.0}
local res_color = {0.4, 0.8, 1.0, 1.0}

-- Network protocol: "GBCQ|<type>|<seq>|<chunkIndex>|<chunkCount>|<data>"
-- <type> is "F" (full snapshot) or "D" (delta). <data> is zero or more
-- ';'-terminated records, each of one of two forms:
--   U,<hash>,<id>,<x>,<y>,<z>,<h>,<r>,<target>,<workers>   -- add/update a job
--   R,<hash>                                               -- remove a job
-- A full snapshot ('F') contains only "U" records and replaces the receiver's
-- entire stored queue for that sender. A delta ('D') applies its "U"/"R"
-- records on top of whatever the receiver already has. Empty optional fields
-- (h, r, target, workers) are encoded as "".
--   hash    : a stable identifier for the job across calls (see SetLocalQueue)
--   id      : negative unitDefID for a build job, or CMD.REPAIR/RECLAIM/RESURRECT
--   x, y, z : world position (for build jobs, area jobs, and cached feature positions)
--   h       : build facing (0-3), build jobs only
--   r       : area radius, area repair/reclaim/resurrect jobs only
--   target  : unit or feature ID (Game.maxUnits + featureID), single-target jobs only
--   workers : number of workers currently assigned to the job (purely informational)
--
-- Deltas alone are enough to keep everyone in sync even for a player who joins
-- mid-game: Spring's join-in-progress catch-up replays the recorded network
-- packet stream (including SendLuaUIMsg) from the start of the game, the same
-- way demo playback does. The periodic full snapshot below exists only as a
-- cheap safety net (e.g. for a widget that gets enabled mid-game, or to bound
-- the damage from a dropped/malformed message), not for late joiners.
local MSG_PREFIX = "GBCQ|"
local MAX_CHUNK_DATA_LEN = 800
local DELTA_INTERVAL = 0.5 -- seconds between checks for changes to broadcast
local RESYNC_INTERVAL = 30.0 -- seconds between unconditional full-snapshot resyncs
local EXPIRE_TIME = 3 * RESYNC_INTERVAL -- time without any update before we drop a player's queue

local myPlayerID = spGetMyPlayerID()

-- Our own queue, as given to us through the public API (see bottom of file).
-- Keyed by a stable per-job hash, exactly like GBC's own buildQueue table.
local localJobs = {}
local lastSentJobs = {} -- what we last told everyone we have, keyed the same way
local sendSeq = 0 -- transfer id for the chunked messages we send
local deltaTimer = 0
local resyncTimer = 0

-- Other players' queues, as received over the network.
local allyQueues = {} -- allyQueues[playerID] = {teamID=, jobs={[hash]=job}, updatedAt=os.clock()}
local pendingChunks = {} -- pendingChunks[playerID] = {type=, seq=, count=, parts={}, received=}

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Encoding / Decoding ---------------------------------------------------------

local function EncodeUpsert(hash, job)
	return "U," .. hash .. ","
		.. (job.id or 0) .. ","
		.. floor(job.x or 0) .. ","
		.. floor(job.y or 0) .. ","
		.. floor(job.z or 0) .. ","
		.. (job.h and floor(job.h) or "") .. ","
		.. (job.r and floor(job.r) or "") .. ","
		.. (job.target and floor(job.target) or "") .. ","
		.. (job.workers and floor(job.workers) or "")
		.. ";"
end

local function EncodeRemove(hash)
	return "R," .. hash .. ";"
end

-- A snapshot of just the fields we care about. Callers such as GBC mutate
-- their command tables in place (eg. updating a "workers assigned" count on
-- the same table), so lastSentJobs must not hold onto the caller's live
-- table by reference - if it did, a later in-place edit would silently
-- change what we think we already sent, and we'd never broadcast the update.
local function SnapshotJob(job)
	return {
		id = job.id, x = job.x, y = job.y, z = job.z,
		h = job.h, r = job.r, target = job.target, workers = job.workers,
	}
end

-- Returns op ("U" or "R"), hash, and (for "U") the decoded job table.
local function DecodeRecord(record)
	local op, rest = record:match("^(%a),(.*)$")
	if op == "R" then
		return "R", rest
	elseif op == "U" then
		local hash, id, x, y, z, h, r, target, workers =
			rest:match("^([^,]+),(-?%d+),(-?%d+),(-?%d+),(-?%d+),(%d*),(%d*),(%d*),(%d*)$")
		if not hash then
			return nil
		end
		return "U", hash, {
			id = tonumber(id),
			x = tonumber(x), y = tonumber(y), z = tonumber(z),
			h = (h ~= "") and tonumber(h) or nil,
			r = (r ~= "") and tonumber(r) or nil,
			target = (target ~= "") and tonumber(target) or nil,
			workers = (workers ~= "") and tonumber(workers) or nil,
		}
	end
	return nil
end

-- Splits already-encoded (';'-terminated) records into chunk strings, never
-- splitting a record across a chunk boundary.
local function BuildChunks(records)
	local chunks = {}
	local current = {}
	local currentLen = 0
	for i = 1, #records do
		local record = records[i]
		if currentLen > 0 and currentLen + #record > MAX_CHUNK_DATA_LEN then
			chunks[#chunks+1] = table.concat(current)
			current = {}
			currentLen = 0
		end
		current[#current+1] = record
		currentLen = currentLen + #record
	end
	if currentLen > 0 or #chunks == 0 then
		chunks[#chunks+1] = table.concat(current)
	end
	return chunks
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Sending -----------------------------------------------------------------

local function SendBatch(typeChar, records)
	sendSeq = sendSeq + 1
	local chunks = BuildChunks(records)
	for i = 1, #chunks do
		local msg = MSG_PREFIX .. typeChar .. "|" .. sendSeq .. "|" .. i .. "|" .. #chunks .. "|" .. chunks[i]
		spSendLuaUIMsg(msg, "a")
		spSendLuaUIMsg(msg, "s")
	end
end

local function BroadcastFull()
	local records = {}
	for hash, job in pairs(localJobs) do
		records[#records+1] = EncodeUpsert(hash, job)
	end
	SendBatch("F", records)

	-- Reset the baseline to exactly match localJobs, mutating lastSentJobs in
	-- place rather than discarding and reallocating it (clearing an existing
	-- field mid-traversal is safe per the Lua manual; adding a new one isn't,
	-- which is why the two loops below stay separate).
	for hash in pairs(lastSentJobs) do
		if not localJobs[hash] then
			lastSentJobs[hash] = nil
		end
	end
	for hash, job in pairs(localJobs) do
		lastSentJobs[hash] = SnapshotJob(job)
	end
end

local function JobsEqual(a, b)
	return a.id == b.id and a.x == b.x and a.y == b.y and a.z == b.z
		and a.h == b.h and a.r == b.r and a.target == b.target and a.workers == b.workers
end

-- `records` is only allocated once we know there's actually something to
-- send, since most ticks have no changes at all.
local function BroadcastDeltaIfChanged()
	local records

	for hash in pairs(lastSentJobs) do
		if not localJobs[hash] then
			records = records or {}
			records[#records+1] = EncodeRemove(hash)
			lastSentJobs[hash] = nil
		end
	end
	for hash, job in pairs(localJobs) do
		local prev = lastSentJobs[hash]
		if not prev or not JobsEqual(prev, job) then
			records = records or {}
			records[#records+1] = EncodeUpsert(hash, job)
			lastSentJobs[hash] = SnapshotJob(job)
		end
	end

	if not records then
		return
	end
	SendBatch("D", records)
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Receiving -----------------------------------------------------------------

local function ApplyRecordsData(playerID, teamID, isFull, data)
	local entry = allyQueues[playerID]
	if isFull or not entry then
		entry = {teamID = teamID, jobs = {}, updatedAt = os.clock()}
		allyQueues[playerID] = entry
	end
	entry.teamID = teamID
	entry.updatedAt = os.clock()

	for record in data:gmatch("([^;]+);") do
		local op, hash, job = DecodeRecord(record)
		if op == "U" then
			entry.jobs[hash] = job
		elseif op == "R" then
			entry.jobs[hash] = nil
		end
	end
end

function widget:RecvLuaMsg(msg, playerID)
	if playerID == myPlayerID then
		return
	end
	if msg:sub(1, #MSG_PREFIX) ~= MSG_PREFIX then
		return
	end

	local typeChar, seqStr, idxStr, countStr, data =
		msg:sub(#MSG_PREFIX + 1):match("^(%a)|(%d+)|(%d+)|(%d+)|(.*)$")
	if not typeChar then
		return
	end
	local seq, idx, count = tonumber(seqStr), tonumber(idxStr), tonumber(countStr)

	local pending = pendingChunks[playerID]
	if not pending or pending.seq ~= seq then
		pending = {type = typeChar, seq = seq, count = count, parts = {}, received = 0}
		pendingChunks[playerID] = pending
	end
	if not pending.parts[idx] then
		pending.parts[idx] = data
		pending.received = pending.received + 1
	end

	if pending.received >= pending.count then
		pendingChunks[playerID] = nil
		local fullData = table.concat(pending.parts, "", 1, pending.count)
		local _, _, _, teamID = spGetPlayerInfo(playerID, false)
		ApplyRecordsData(playerID, teamID, pending.type == "F", fullData)
	end
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Update / Expiry -------------------------------------------------------------

function widget:Update(dt)
	deltaTimer = deltaTimer + dt
	resyncTimer = resyncTimer + dt

	if resyncTimer >= RESYNC_INTERVAL then
		resyncTimer = 0
		deltaTimer = 0
		BroadcastFull()
	elseif deltaTimer >= DELTA_INTERVAL then
		deltaTimer = 0
		BroadcastDeltaIfChanged()
	end

	local now = os.clock()
	for playerID, data in pairs(allyQueues) do
		if now - data.updatedAt > EXPIRE_TIME then
			allyQueues[playerID] = nil
		end
	end
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Drawing -----------------------------------------------------------------

local function DrawOutline(unitDefID, x, y, z, h)
	local ud = UnitDefs[unitDefID]
	local baseX = ud.xsize * 4
	local baseZ = ud.zsize * 4
	if h == 1 or h == 3 then
		baseX, baseZ = baseZ, baseX
	end
	glVertex(x-baseX, y, z-baseZ)
	glVertex(x-baseX, y, z+baseZ)
	glVertex(x+baseX, y, z+baseZ)
	glVertex(x+baseX, y, z-baseZ)
	glVertex(x-baseX, y, z-baseZ)
end

local function DrawIcon(texture, x, y, z, size)
	glTexture(texture)
	glPushMatrix()
	glTranslate(x - size*0.5, y, z + size*0.5)
	glBillboard()
	glTexRect(0, 0, size, size)
	glPopMatrix()
end

local function ShouldShow()
	if spIsGUIHidden() then
		return false
	end
	if options.allyQueueAlwaysShow.value then
		return true
	end
	local _, _, _, shift = spGetModKeyState()
	return shift
end

function widget:DrawWorldPreUnit()
	if not ShouldShow() then
		return
	end

	glLineWidth(2)
	for playerID, data in pairs(allyQueues) do
		for hash, job in pairs(data.jobs) do
			if job.id < 0 then -- build job outline
				if spIsAABBInView(job.x-1, job.y-1, job.z-1, job.x+1, job.y+1, job.z+1) then
					glColor(1.0, 0.5, 0.1, 1)
					glBeginEnd(GL_LINE_STRIP, DrawOutline, -job.id, job.x, job.y, job.z, job.h or 0)
				end
			elseif not job.target then -- area job circle
				if spIsSphereInView(job.x, job.y, job.z, (job.r or 0)+25) then
					if job.id == CMD_REPAIR then
						glColor(rep_color)
					elseif job.id == CMD_RECLAIM then
						glColor(rec_color)
					else
						glColor(res_color)
					end
					glGroundCircle(job.x, job.y, job.z, job.r or 0, 32)
				end
			end
		end
	end
	glColor(1, 1, 1, 1)
	glLineWidth(1)
end

function widget:DrawWorld()
	if not ShouldShow() then
		return
	end

	glDepthTest(true)
	glColor(1, 1, 1, 0.4)
	for playerID, data in pairs(allyQueues) do
		local teamID = data.teamID
		for hash, job in pairs(data.jobs) do
			if job.id < 0 then -- build job ghost
				local unitDefID = -job.id
				if spIsAABBInView(job.x-1, job.y-1, job.z-1, job.x+1, job.y+1, job.z+1) then
					glPushMatrix()
					glLoadIdentity()
					glTranslate(job.x, job.y, job.z)
					glRotate((job.h or 0) * 90, 0, 1.0, 0)
					glUnitShape(unitDefID, teamID, false, false, false)
					glPopMatrix()
				end
			end
		end
	end
	glDepthTest(false)

	glColor(1, 1, 1, 0.7)
	for playerID, data in pairs(allyQueues) do
		for hash, job in pairs(data.jobs) do
			if job.id >= 0 and job.target then -- single-target repair/reclaim/resurrect
				local x, y, z
				if job.target >= Game.maxUnits then
					if spValidFeatureID(job.target - Game.maxUnits) then
						x, y, z = spGetFeaturePosition(job.target - Game.maxUnits)
					end
				elseif spValidUnitID(job.target) then
					x, y, z = spGetUnitPosition(job.target)
				end
				x, y, z = x or job.x, y or job.y, z or job.z
				if x and spIsSphereInView(x, y, z, 100) then
					if job.id == CMD_REPAIR then
						DrawIcon(rep_icon, x, y, z, 66)
					elseif job.id == CMD_RECLAIM then
						DrawIcon(rec_icon, x, y, z, 66)
					else
						DrawIcon(res_icon, x, y, z, 66)
					end
				end
			end
		end
	end

	glTexture(false)
	glColor(1, 1, 1, 1)
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Public API ------------------------------------------------------------------

-- To be called (later, from unit_global_build_command.lua or similar) whenever
-- the caller's own build queue changes, or once with a live table reference
-- that the caller keeps mutating in place (eg. GBC's own buildQueue) - either
-- way works, since this widget only reads from `jobs` on its own timer rather
-- than reacting to the call itself.
--
-- `jobs` must be a dict keyed by a stable per-job identifier that stays the
-- same for the same logical job across calls (GBC's own buildQueue is already
-- keyed exactly this way, by BuildHash(cmd)), mapping to a job table with the
-- fields documented in the network protocol comment above.
local function SetLocalQueue(jobs)
	localJobs = jobs or {}
end

function widget:Initialize()
	myPlayerID = spGetMyPlayerID()
	WG.GlobalBuildQueueShare = {
		SetLocalQueue = SetLocalQueue,
	}
end

function widget:Shutdown()
	WG.GlobalBuildQueueShare = nil
end
