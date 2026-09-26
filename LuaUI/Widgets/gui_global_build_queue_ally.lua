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
--  WG.GlobalBuildQueueShare.Update()/Delete() yet. That hookup into
--  unit_global_build_command.lua (or any other queue-like widget) is a
--  separate, later change. This file only implements the share/receive/draw
--  side of the feature, plus its public API.
--
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

function widget:GetInfo()
	return {
		name      = "Global Build Queue",
		desc      = "Shows your own Global Build Command queue, allied players' queues, and (for spectators) every player's queue. Nothing to see yet unless something calls the Update/Delete API.",
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

-- Network protocol: two message shapes, both prefixed "GBCQ|".
--
-- "GBCQ|S" - a sync request, sent once by a newly-initialized widget. Anyone
-- receiving it marks all of their own currently-owned hashes as pending (see
-- MarkAllOwnJobsPending), so they go out through the ordinary delta path
-- below rather than needing a separate "full snapshot" message shape.
--
-- "GBCQ|<seq>|<chunkIndex>|<chunkCount>|<data>" - a delta. <data> is zero or
-- more ';'-terminated records, applied on top of whatever the receiver
-- already has, each of one of two forms:
--   U,<hash>,<cmdId>,<x>,<y>,<z>,<h>,<r>,<target>,<workers> -- add/update a job
--   R,<hash>                                               -- remove a job
-- Empty optional fields (h, r, target, workers) are encoded as "".
--   hash    : a stable identifier for the job across calls (see UpdateJob/DeleteJob)
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
-- way demo playback does. The sync request above exists for the other case a
-- one-off full send would otherwise be needed for: a widget enabled mid-game,
-- which never received any of the deltas sent before it existed.
local MSG_PREFIX = "GBCQ|"
local MAX_CHUNK_DATA_LEN = 800
local DELTA_INTERVAL = 0.5 -- seconds between checks for changes to broadcast
local MAX_UPDATES_PER_SEND = 50 -- caps how many changed hashes go out in one delta, so a big burst spreads over multiple sends rather than spiking that one frame's message count

local myPlayerID = spGetMyPlayerID()

-- Job data is stored as a separate flat dictionary per field (a "struct of
-- arrays"), each keyed by job id, instead of one dictionary of small per-job
-- tables. Lots of small short-lived tables is exactly the kind of thing that
-- produces needless garbage-collector pressure in Lua; a handful of flat
-- dictionaries of plain numbers avoids that, at the cost of more repetitive
-- code around them.

-- Every player's queue - ours included - lives in this one set of
-- dictionaries, keyed by "<playerID>#<hash>" rather than by hash alone,
-- since two different players can otherwise end up with the exact same hash
-- (eg. both queuing the same building at the same spot) and would then
-- collide into a single entry. Our own entries (owner == myPlayerID) are
-- written directly by UpdateJob/DeleteJob; everyone else's arrive over the
-- network via RecvLuaMsg/ApplyRecordsData.
local cmdId = {}
local jobX = {}
local jobY = {}
local jobZ = {}
local jobH = {}
local jobR = {}
local jobTarget = {}
local jobWorkers = {}
local jobOwner = {} -- jobOwner[key] = the owning playerID

-- Which of our own hashes have changed since the last send, and how: true
-- means UpdateJob() was called (so the fields above already hold the new
-- values, ready to encode), false means DeleteJob() was called. Populated
-- directly by the public API (see the bottom of this file) rather than by
-- comparing against a second full copy of our own data every send tick - the
-- caller already knows exactly when something changed, so there's nothing to
-- diff. Keyed by bare hash, not "<playerID>#<hash>", since it only ever
-- tracks our own changes.
local pendingStatus = {}

local sendSeq = 0 -- transfer id for the chunked messages we send
local deltaTimer = 0

-- Per-player bookkeeping. This is naturally one entry per player rather than
-- per job, so it stays as a small dictionary. Gets one entry for us too (set
-- once in widget:Initialize()), purely so our own ghost buildings can use the
-- same ownerTeamID[jobOwner[key]] lookup as everyone else's rather than a
-- special case.
local ownerTeamID = {}
local pendingChunks = {} -- pendingChunks[playerID] = {seq=, count=, parts={}, received=}

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

local function SendBatch(records)
	sendSeq = sendSeq + 1
	local chunks = BuildChunks(records)
	for i = 1, #chunks do
		local msg = MSG_PREFIX .. sendSeq .. "|" .. i .. "|" .. #chunks .. "|" .. chunks[i]
		spSendLuaUIMsg(msg, "a")
		spSendLuaUIMsg(msg, "s")
	end
end

-- Reads back one of our own jobs by its bare hash, deriving the storage key
-- the same way UpdateJob does.
local function EncodeLocalUpsert(hash)
	local key = myPlayerID .. "#" .. hash
	return EncodeUpsert(hash, cmdId[key], jobX[key], jobY[key], jobZ[key],
		jobH[key], jobR[key], jobTarget[key], jobWorkers[key])
end

-- Marks every hash we currently own as pending an update, in response to a
-- sync request from a newly-initialized widget elsewhere. Scanning the whole
-- (everyone's) table to find just our own entries only happens here, when
-- someone actually asks for it - never on the much more frequent
-- BroadcastPending() path below, which only ever touches pendingStatus.
local function MarkAllOwnJobsPending()
	local myKeyPrefix = myPlayerID .. "#"
	for key, owner in pairs(jobOwner) do
		if owner == myPlayerID then
			pendingStatus[key:sub(#myKeyPrefix + 1)] = true
		end
	end
end

-- Drains up to MAX_UPDATES_PER_SEND of whatever UpdateJob()/DeleteJob() have
-- queued up since the last send, removing only the hashes actually included
-- this time - anything past the cap just stays in pendingStatus for the next
-- send to pick up (or gets overwritten first if it changes again before
-- then), so one big burst spreads across multiple ticks instead of spiking a
-- single frame's message count.
local function BroadcastPending()
	local records
	local sent = 0
	for hash, isUpdate in pairs(pendingStatus) do
		if sent >= MAX_UPDATES_PER_SEND then
			break
		end
		records = records or {}
		if isUpdate then
			records[#records+1] = EncodeLocalUpsert(hash)
		else
			records[#records+1] = EncodeRemove(hash)
		end
		pendingStatus[hash] = nil
		sent = sent + 1
	end

	if not records then
		return
	end
	SendBatch(records)
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Receiving -----------------------------------------------------------------

-- Clears one job by its full storage key ("<playerID>#<hash>"), whether it's
-- ours or another player's - shared by DeleteJob() and the receiving code
-- below.
local function ClearJob(key)
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

local function ApplyRecordsData(playerID, teamID, data)
	ownerTeamID[playerID] = teamID

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
			elseif op == "R" then
				ClearJob(key)
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
	local rest = msg:sub(#MSG_PREFIX + 1)

	if rest == "S" then
		MarkAllOwnJobsPending()
		return
	end

	local seqStr, idxStr, countStr, data = rest:match("^(%d+)|(%d+)|(%d+)|(.*)$")
	if not seqStr then
		return
	end
	local seq, idx, count = tonumber(seqStr), tonumber(idxStr), tonumber(countStr)

	local pending = pendingChunks[playerID]
	if not pending or pending.seq ~= seq then
		pending = {seq = seq, count = count, parts = {}, received = 0}
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
		ApplyRecordsData(playerID, teamID, fullData)
	end
end

-- Precise, event-driven cleanup instead of a timeout: a player's queue stops
-- mattering exactly when they leave (PlayerRemoved - disconnect/quit/kick) or
-- resign (PlayerChanged, when Spring.GetPlayerInfo now reports them as a
-- spectator), not after some guessed number of quiet seconds. This also means
-- a player who simply hasn't changed their queue in a while is never
-- mistaken for one who's gone.
local function ClearPlayerJobs(playerID)
	ownerTeamID[playerID] = nil
	for key, owner in pairs(jobOwner) do
		if owner == playerID then
			ClearJob(key)
		end
	end
end

function widget:PlayerRemoved(playerID)
	ClearPlayerJobs(playerID)
end

function widget:PlayerChanged(playerID)
	local _, _, isSpec = spGetPlayerInfo(playerID, false)
	if isSpec then
		ClearPlayerJobs(playerID)
	end
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Update -----------------------------------------------------------------

function widget:Update(dt)
	deltaTimer = deltaTimer + dt
	if deltaTimer >= DELTA_INTERVAL then
		deltaTimer = 0
		BroadcastPending()
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

-- The three helpers below hold the actual GL drawing logic for one job. Since
-- our own queue and everyone else's live in the same set of dictionaries
-- (see where cmdId/jobX/... are declared), the widget:DrawX() callins below
-- only need one loop each over the whole table, rather than one loop per
-- source.

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

	glDepthTest(true)
	glColor(1, 1, 1, 0.4)
	for key, cmdIdValue in pairs(cmdId) do
		DrawJobGhost(cmdIdValue, jobX[key], jobY[key], jobZ[key], jobH[key], ownerTeamID[jobOwner[key]])
	end
	glDepthTest(false)

	glColor(1, 1, 1, 0.7)
	for key, cmdIdValue in pairs(cmdId) do
		DrawJobIcon(cmdIdValue, jobX[key], jobY[key], jobZ[key], jobTarget[key])
	end

	glTexture(false)
	glColor(1, 1, 1, 1)
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Public API ------------------------------------------------------------------

-- To be called (later, from unit_global_build_command.lua or similar)
-- whenever it adds a job or changes one it already has - eg. GBC's own
-- `buildQueue[hash] = myCmd` becomes `WG.GlobalBuildQueueShare.Update(hash,
-- myCmd)`. `job` must have the fields documented in the network protocol
-- comment above (id, x, y, z, and the optional h/r/target/workers). `hash`
-- must be a stable identifier for this exact job across calls (GBC's own
-- BuildHash(cmd) already is one).
--
-- There's no "replace everything" call: a hash sticks around until Delete()
-- is called for it specifically, so every removal needs its own explicit
-- Delete() call - eg. GBC's own `buildQueue[hash] = nil` needs a matching
-- `WG.GlobalBuildQueueShare.Delete(hash)` alongside it, not just the removal
-- of the Lua table entry.
local function UpdateJob(hash, job)
	local key = myPlayerID .. "#" .. hash
	cmdId[key] = job.id
	jobX[key] = job.x
	jobY[key] = job.y
	jobZ[key] = job.z
	jobH[key] = job.h
	jobR[key] = job.r
	jobTarget[key] = job.target
	jobWorkers[key] = job.workers
	jobOwner[key] = myPlayerID
	pendingStatus[hash] = true
end

-- To be called whenever a job is removed - eg. GBC's own
-- `buildQueue[hash] = nil` becomes `WG.GlobalBuildQueueShare.Delete(hash)`.
local function DeleteJob(hash)
	ClearJob(myPlayerID .. "#" .. hash)
	pendingStatus[hash] = false
end

function widget:Initialize()
	myPlayerID = spGetMyPlayerID()
	-- So our own ghost buildings get colored correctly by the same
	-- ownerTeamID[jobOwner[key]] lookup used for everyone else's, without
	-- special-casing "is this actually me" in the draw loop.
	ownerTeamID[myPlayerID] = spGetMyTeamID()
	-- Ask everyone else to (re-)send their current queue, since we won't have
	-- seen any of the deltas from before we existed (eg. this widget just got
	-- enabled mid-game).
	spSendLuaUIMsg(MSG_PREFIX .. "S", "a")
	spSendLuaUIMsg(MSG_PREFIX .. "S", "s")
	WG.GlobalBuildQueueShare = {
		Update = UpdateJob,
		Delete = DeleteJob,
	}
end

function widget:Shutdown()
	WG.GlobalBuildQueueShare = nil
end
