--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--
--  file:    gui_global_build_queue_ally.lua
--  brief:   Shows the local player's own Global Build Command queue, allied
--           players' queues, and (for spectators) everyone's queue.
--
--  Unlike "Global Build Command" itself, this widget is on by default: it only
--  displays information, and never touches anyone's units. GBC itself no
--  longer draws its own queue - this widget replaces that display for the
--  local player too, not just for allies/spectators.
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
		name      = "Global Build Queue",
		desc      = "Shows your own Global Build Command queue, allied players' queues, and (for spectators) every player's queue. Nothing to see yet unless something calls the SetLocalQueue API.",
		author    = "amnykon",
		date      = "September 25, 2026",
		license   = "GNU GPL, v2 or later",
		layer     = 11, -- draws after unit_global_build_command.lua (layer 10)
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
local spGetMyTeamID         = Spring.GetMyTeamID
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
--   U,<hash>,<cmdId>,<x>,<y>,<z>,<h>,<r>,<target>,<workers> -- add/update a job
--   R,<hash>                                               -- remove a job
-- A full snapshot ('F') contains only "U" records and replaces the receiver's
-- entire stored queue for that sender. A delta ('D') applies its "U"/"R"
-- records on top of whatever the receiver already has. Empty optional fields
-- (h, r, target, workers) are encoded as "".
--   hash    : a stable identifier for the job across calls (see SetLocalQueue)
--   cmdId   : negative unitDefID for a build job, or CMD.REPAIR/RECLAIM/RESURRECT
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

-- Job data is stored as a separate flat dictionary per field (a "struct of
-- arrays"), each keyed by job id, instead of one dictionary of small per-job
-- tables. Lots of small short-lived tables is exactly the kind of thing that
-- produces needless garbage-collector pressure in Lua; a handful of flat
-- dictionaries of plain numbers avoids that, at the cost of more repetitive
-- code around them.

-- Our own queue, as given to us through the public API (see bottom of file),
-- keyed by a stable per-job hash (see SetLocalQueue for where this comes from).
local localCmdId = {}
local localJobX = {}
local localJobY = {}
local localJobZ = {}
local localJobH = {}
local localJobR = {}
local localJobTarget = {}
local localJobWorkers = {}

-- What we last told everyone we have - the diff baseline - same layout as
-- the localJob* set above, and always keyed the same way (by hash).
local sentCmdId = {}
local sentJobX = {}
local sentJobY = {}
local sentJobZ = {}
local sentJobH = {}
local sentJobR = {}
local sentJobTarget = {}
local sentJobWorkers = {}

local sendSeq = 0 -- transfer id for the chunked messages we send
local deltaTimer = 0
local resyncTimer = 0

-- Other players' queues, as received over the network. Every sender shares
-- the same flat dictionaries, keyed by "<playerID>#<hash>" rather than by
-- hash alone, since two different players can otherwise end up with the
-- exact same hash (eg. both queuing the same building at the same spot) and
-- would then collide into a single entry.
local cmdId = {}
local jobX = {}
local jobY = {}
local jobZ = {}
local jobH = {}
local jobR = {}
local jobTarget = {}
local jobWorkers = {}
local jobOwner = {} -- jobOwner[key] = the owning playerID

-- Per-player bookkeeping. This is naturally one entry per player rather than
-- per job, so it stays as small dictionaries.
local ownerTeamID = {}
local ownerUpdatedAt = {}
local pendingChunks = {} -- pendingChunks[playerID] = {type=, seq=, count=, parts={}, received=}

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Encoding / Decoding ---------------------------------------------------------

local function EncodeUpsert(hash, cmdId, x, y, z, h, r, target, workers)
	return "U," .. hash .. ","
		.. (cmdId or 0) .. ","
		.. floor(x or 0) .. ","
		.. floor(y or 0) .. ","
		.. floor(z or 0) .. ","
		.. (h and floor(h) or "") .. ","
		.. (r and floor(r) or "") .. ","
		.. (target and floor(target) or "") .. ","
		.. (workers and floor(workers) or "")
		.. ";"
end

local function EncodeRemove(hash)
	return "R," .. hash .. ";"
end

-- Returns op ("U" or "R"), hash, and (for "U") the decoded scalar fields -
-- deliberately not packed into a job table, to avoid allocating one per
-- record decoded.
local function DecodeRecord(record)
	local op, rest = record:match("^(%a),(.*)$")
	if op == "R" then
		return "R", rest
	elseif op == "U" then
		local hash, cmdId, x, y, z, h, r, target, workers =
			rest:match("^([^,]+),(-?%d+),(-?%d+),(-?%d+),(-?%d+),(%d*),(%d*),(%d*),(%d*)$")
		if not hash then
			return nil
		end
		return "U", hash,
			tonumber(cmdId), tonumber(x), tonumber(y), tonumber(z),
			(h ~= "") and tonumber(h) or nil,
			(r ~= "") and tonumber(r) or nil,
			(target ~= "") and tonumber(target) or nil,
			(workers ~= "") and tonumber(workers) or nil
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

local function EncodeLocalUpsert(hash)
	return EncodeUpsert(hash, localCmdId[hash], localJobX[hash], localJobY[hash], localJobZ[hash],
		localJobH[hash], localJobR[hash], localJobTarget[hash], localJobWorkers[hash])
end

local function CopyLocalJobToSent(hash)
	sentCmdId[hash] = localCmdId[hash]
	sentJobX[hash] = localJobX[hash]
	sentJobY[hash] = localJobY[hash]
	sentJobZ[hash] = localJobZ[hash]
	sentJobH[hash] = localJobH[hash]
	sentJobR[hash] = localJobR[hash]
	sentJobTarget[hash] = localJobTarget[hash]
	sentJobWorkers[hash] = localJobWorkers[hash]
end

local function ClearSentJob(hash)
	sentCmdId[hash] = nil
	sentJobX[hash] = nil
	sentJobY[hash] = nil
	sentJobZ[hash] = nil
	sentJobH[hash] = nil
	sentJobR[hash] = nil
	sentJobTarget[hash] = nil
	sentJobWorkers[hash] = nil
end

local function LocalJobChanged(hash)
	return sentCmdId[hash] == nil
		or sentCmdId[hash] ~= localCmdId[hash]
		or sentJobX[hash] ~= localJobX[hash]
		or sentJobY[hash] ~= localJobY[hash]
		or sentJobZ[hash] ~= localJobZ[hash]
		or sentJobH[hash] ~= localJobH[hash]
		or sentJobR[hash] ~= localJobR[hash]
		or sentJobTarget[hash] ~= localJobTarget[hash]
		or sentJobWorkers[hash] ~= localJobWorkers[hash]
end

local function BroadcastFull()
	local records = {}
	for hash in pairs(localCmdId) do
		records[#records+1] = EncodeLocalUpsert(hash)
	end
	SendBatch("F", records)

	-- Reset the baseline to exactly match localJob*, mutating sentJob* in
	-- place (clearing an existing field mid-traversal is safe per the Lua
	-- manual; adding a new one isn't, which is why these stay separate loops).
	for hash in pairs(sentCmdId) do
		if not localCmdId[hash] then
			ClearSentJob(hash)
		end
	end
	for hash in pairs(localCmdId) do
		CopyLocalJobToSent(hash)
	end
end

-- Which hashes need an upsert or a removal this tick. Reused and cleared in
-- place every tick (table.clear() is a Spring extension, also used by GBC
-- itself) rather than reallocated, so naming the two sets explicitly doesn't
-- bring back the per-tick table churn we removed earlier.
local jobsToUpdate = {}
local jobsToDelete = {}

local function BroadcastDeltaIfChanged()
	table.clear(jobsToUpdate)
	table.clear(jobsToDelete)

	for hash in pairs(sentCmdId) do
		if not localCmdId[hash] then
			jobsToDelete[hash] = true
		end
	end
	for hash in pairs(localCmdId) do
		if LocalJobChanged(hash) then
			jobsToUpdate[hash] = true
		end
	end

	if next(jobsToUpdate) == nil and next(jobsToDelete) == nil then
		return
	end

	local records = {}
	for hash in pairs(jobsToDelete) do
		records[#records+1] = EncodeRemove(hash)
		ClearSentJob(hash)
	end
	for hash in pairs(jobsToUpdate) do
		records[#records+1] = EncodeLocalUpsert(hash)
		CopyLocalJobToSent(hash)
	end
	SendBatch("D", records)
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Receiving -----------------------------------------------------------------

local function ClearReceivedJob(key)
	cmdId[key] = nil
	jobX[key] = nil
	jobY[key] = nil
	jobZ[key] = nil
	jobH[key] = nil
	jobR[key] = nil
	jobTarget[key] = nil
	jobWorkers[key] = nil
	jobOwner[key] = nil
end

local function ApplyRecordsData(playerID, teamID, isFull, data)
	ownerTeamID[playerID] = teamID
	ownerUpdatedAt[playerID] = os.clock()

	-- For a full snapshot, track which keys it mentions so we can prune
	-- anything else already stored for this owner (eg. a job they had before
	-- but have since finished/cancelled without us seeing the delta for it).
	local newKeys = isFull and {} or nil

	for record in data:gmatch("([^;]+);") do
		local op, hash, decodedCmdId, x, y, z, h, r, target, workers = DecodeRecord(record)
		if op then
			local key = playerID .. "#" .. hash
			if op == "U" then
				cmdId[key] = decodedCmdId
				jobX[key] = x
				jobY[key] = y
				jobZ[key] = z
				jobH[key] = h
				jobR[key] = r
				jobTarget[key] = target
				jobWorkers[key] = workers
				jobOwner[key] = playerID
				if newKeys then
					newKeys[key] = true
				end
			elseif op == "R" then
				ClearReceivedJob(key)
			end
		end
	end

	if newKeys then
		for key, owner in pairs(jobOwner) do
			if owner == playerID and not newKeys[key] then
				ClearReceivedJob(key)
			end
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
	for playerID, updatedAt in pairs(ownerUpdatedAt) do
		if now - updatedAt > EXPIRE_TIME then
			ownerUpdatedAt[playerID] = nil
			ownerTeamID[playerID] = nil
			for key, owner in pairs(jobOwner) do
				if owner == playerID then
					ClearReceivedJob(key)
				end
			end
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

-- The three helpers below hold the actual GL drawing logic for one job, so
-- that our own queue (localCmdId/localJobX/...) and everyone else's queues
-- (cmdId/jobX/... keyed by "<playerID>#<hash>") can share it: they're stored
-- separately (see the comments where those dictionaries are declared), but
-- there's no reason the drawing code should be duplicated for each source.

local function DrawJobOutline(cmdId, x, y, z, h, r, target)
	if cmdId < 0 then -- build job outline
		if spIsAABBInView(x-1, y-1, z-1, x+1, y+1, z+1) then
			glColor(1.0, 0.5, 0.1, 1)
			glBeginEnd(GL_LINE_STRIP, DrawOutline, -cmdId, x, y, z, h or 0)
		end
	elseif not target then -- area job circle
		r = r or 0
		if spIsSphereInView(x, y, z, r+25) then
			if cmdId == CMD_REPAIR then
				glColor(rep_color)
			elseif cmdId == CMD_RECLAIM then
				glColor(rec_color)
			else
				glColor(res_color)
			end
			glGroundCircle(x, y, z, r, 32)
		end
	end
end

local function DrawJobGhost(cmdId, x, y, z, h, teamID)
	if cmdId < 0 then -- build job ghost
		if spIsAABBInView(x-1, y-1, z-1, x+1, y+1, z+1) then
			glPushMatrix()
			glLoadIdentity()
			glTranslate(x, y, z)
			glRotate((h or 0) * 90, 0, 1.0, 0)
			glUnitShape(-cmdId, teamID, false, false, false)
			glPopMatrix()
		end
	end
end

local function DrawJobIcon(cmdId, x, y, z, target)
	if cmdId >= 0 and target then -- single-target repair/reclaim/resurrect
		local ix, iy, iz
		if target >= Game.maxUnits then
			if spValidFeatureID(target - Game.maxUnits) then
				ix, iy, iz = spGetFeaturePosition(target - Game.maxUnits)
			end
		elseif spValidUnitID(target) then
			ix, iy, iz = spGetUnitPosition(target)
		end
		ix, iy, iz = ix or x, iy or y, iz or z
		if spIsSphereInView(ix, iy, iz, 100) then
			if cmdId == CMD_REPAIR then
				DrawIcon(rep_icon, ix, iy, iz, 66)
			elseif cmdId == CMD_RECLAIM then
				DrawIcon(rec_icon, ix, iy, iz, 66)
			else
				DrawIcon(res_icon, ix, iy, iz, 66)
			end
		end
	end
end

function widget:DrawWorldPreUnit()
	if not ShouldShow() then
		return
	end

	glLineWidth(2)
	for hash, localCmdIdValue in pairs(localCmdId) do
		DrawJobOutline(localCmdIdValue, localJobX[hash], localJobY[hash], localJobZ[hash],
			localJobH[hash], localJobR[hash], localJobTarget[hash])
	end
	for key, cmdIdValue in pairs(cmdId) do
		DrawJobOutline(cmdIdValue, jobX[key], jobY[key], jobZ[key], jobH[key], jobR[key], jobTarget[key])
	end
	glColor(1, 1, 1, 1)
	glLineWidth(1)
end

function widget:DrawWorld()
	if not ShouldShow() then
		return
	end

	local myTeamID = spGetMyTeamID()

	glDepthTest(true)
	glColor(1, 1, 1, 0.4)
	for hash, localCmdIdValue in pairs(localCmdId) do
		DrawJobGhost(localCmdIdValue, localJobX[hash], localJobY[hash], localJobZ[hash], localJobH[hash], myTeamID)
	end
	for key, cmdIdValue in pairs(cmdId) do
		DrawJobGhost(cmdIdValue, jobX[key], jobY[key], jobZ[key], jobH[key], ownerTeamID[jobOwner[key]])
	end
	glDepthTest(false)

	glColor(1, 1, 1, 0.7)
	for hash, localCmdIdValue in pairs(localCmdId) do
		DrawJobIcon(localCmdIdValue, localJobX[hash], localJobY[hash], localJobZ[hash], localJobTarget[hash])
	end
	for key, cmdIdValue in pairs(cmdId) do
		DrawJobIcon(cmdIdValue, jobX[key], jobY[key], jobZ[key], jobTarget[key])
	end

	glTexture(false)
	glColor(1, 1, 1, 1)
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Public API ------------------------------------------------------------------

local function ClearLocalJob(hash)
	localCmdId[hash] = nil
	localJobX[hash] = nil
	localJobY[hash] = nil
	localJobZ[hash] = nil
	localJobH[hash] = nil
	localJobR[hash] = nil
	localJobTarget[hash] = nil
	localJobWorkers[hash] = nil
end

-- To be called (later, from unit_global_build_command.lua or similar) every
-- time the caller's own build queue changes. Unlike a live table reference,
-- this copies the given fields out immediately into our own flat per-field
-- dictionaries, so call it again whenever anything changes rather than
-- expecting us to notice an in-place edit to a table you handed us earlier.
--
-- `jobs` must be a dict keyed by a stable per-job identifier that stays the
-- same for the same logical job across calls (GBC's own buildQueue is already
-- keyed exactly this way, by BuildHash(cmd)), mapping to a job table with the
-- fields documented in the network protocol comment above.
local function SetLocalQueue(jobs)
	jobs = jobs or {}
	for hash in pairs(localCmdId) do
		if not jobs[hash] then
			ClearLocalJob(hash)
		end
	end
	for hash, job in pairs(jobs) do
		localCmdId[hash] = job.id
		localJobX[hash] = job.x
		localJobY[hash] = job.y
		localJobZ[hash] = job.z
		localJobH[hash] = job.h
		localJobR[hash] = job.r
		localJobTarget[hash] = job.target
		localJobWorkers[hash] = job.workers
	end
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
