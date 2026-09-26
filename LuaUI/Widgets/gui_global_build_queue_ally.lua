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
--  Job identity is assigned by this widget, not the caller: Update() returns
--  a jobId (creating one if none is passed in), and the caller holds onto it
--  to update or delete that same job later. This widget doesn't care what a
--  job "means" to its caller, only that the id is stable across calls.
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

-- Network protocol: two message shapes, both prefixed "GBCQ|", and both
-- always sent whole in a single SendLuaUIMsg call - Spring's NETMSG_LUAMSG
-- uses a uint16 size field (~65KB ceiling), and MAX_UPDATES_PER_SEND already
-- keeps a batch to a few KB at most, so there's no need to split a send
-- across multiple messages or reassemble one on the receiving end.
--
-- "GBCQ|S" - a sync request, sent once by a newly-initialized widget. Anyone
-- receiving it marks all of their own currently-owned jobIds as pending (see
-- MarkAllOwnJobsPending), so they go out through the ordinary delta path
-- below rather than needing a separate "full snapshot" message shape.
--
-- "GBCQ|<data>" - a delta. <data> is zero or more ';'-terminated records,
-- applied on top of whatever the receiver already has, each of one of three
-- forms:
--   U,<jobId>,<cmdId>,<x>,<y>,<z>,<h>,<r>,<target>,<reach>,<priority>,<unitID> -- add/update a job
--   R,<jobId>                                                                 -- remove a job
--   A,<ownerPlayerID>,<jobId>,<workers>                                        -- report an assist count
-- Empty optional fields (h, r, target, reach, priority, unitID) are encoded as "".
--   jobId    : assigned by the owner's own widget (see UpdateJob), unique
--              among that one player's jobs only - always paired with an
--              ownerPlayerID (implicit as the sender for U/R, explicit for
--              A) to address a specific job, the same way a hash would.
--   cmdId    : negative unitDefID for a build job, or CMD.REPAIR/RECLAIM/RESURRECT
--   x, y, z  : world position (for build jobs, area jobs, and cached feature positions)
--   h        : build facing (0-3), build jobs only
--   r        : area radius, area repair/reclaim/resurrect jobs only
--   target   : unit or feature ID (Game.maxUnits + featureID), single-target jobs only
--   reach    : which movers can reach the job's spot, as a small enum matching
--              cmd_spot_reach_flags.lua's REACH_TYPES *keys* on the energyGrid
--              branch (matched by key, not that array's position, since it can
--              be reordered/extended independently of this file):
--                0 = none, 1 = air, 2 = water, 3 = spider, 4 = slope, 5 = land
--              absent means unrestricted (that widget's "all"/default). This is
--              the job's own reach as its owner assessed it, not something
--              recomputed locally per ally - allies may not have flagged the
--              same spots themselves.
--   priority : 0 = low, 1 = high; absent means medium/normal, the default
--              most jobs won't override. Not something this widget acts on
--              itself - it's just carried for whatever AI picks a worker's
--              next job to weigh alongside reach/worker count.
--   unitID   : the actual in-world unit for this job, once one exists (eg.
--              construction has started on a build job) - lets a worker AI
--              query it directly (health, build progress) instead of only
--              having a world position. Unlike target, this isn't limited to
--              single-target jobs; absent means no unit exists for it yet.
--              GetJobByUnitID(unitID) below is the reverse direction: given
--              a unit (eg. from a UnitFinished/UnitDestroyed callin), find
--              which job (any player's) it belongs to, without needing to
--              already know its owner or jobId.
--
-- A job's worker count isn't part of the job record itself - it's the sum of
-- however many workers each interested player (the owner included) reports
-- assigning to it via "A" records, since any ally can assist a job without
-- owning it. The sender of an "A" record is always the assisting player (the
-- same convention "U"/"R" use), so only the job's owner needs naming
-- explicitly; workers = 0 means that player stopped assisting. There's no
-- ordering guarantee between a job's own "U"/"R" records and "A" records
-- about it - SendLuaUIMsg is relayed immediately by the server, not
-- attached to the deterministic simulation frame stream, so an assist
-- report can arrive before the job it refers to, or after the job's been
-- removed. Both are treated as normal, silent no-ops rather than errors.
--
-- Deltas alone are enough to keep everyone in sync even for a player who joins
-- mid-game: Spring's join-in-progress catch-up replays the recorded network
-- packet stream (including SendLuaUIMsg) from the start of the game, the same
-- way demo playback does. The sync request above exists for the other case a
-- one-off full send would otherwise be needed for: a widget enabled mid-game,
-- which never received any of the deltas sent before it existed.
local MSG_PREFIX = "GBCQ|"
local MAX_UPDATES_PER_SEND = 50 -- caps how many changed jobs go out in one delta, so a big burst spreads over multiple sends rather than spiking that one frame's message count

local myPlayerID = spGetMyPlayerID()

-- The next jobId UpdateJob() will assign when called without one. Seeded
-- from the current sim frame (see widget:Initialize()) rather than starting
-- at 1 every time, so a widget reload mid-game can't reissue a jobId one of
-- our earlier broadcasts already used - every other client would otherwise
-- silently treat a brand new job as an update to that old, unrelated one,
-- since from their side ownerPlayerID+jobId is all that identifies it.
local nextJobId = 1

-- Job data is stored as a separate flat dictionary per field (a "struct of
-- arrays"), each keyed by job id, instead of one dictionary of small per-job
-- tables. Lots of small short-lived tables is exactly the kind of thing that
-- produces needless garbage-collector pressure in Lua; a handful of flat
-- dictionaries of plain numbers avoids that, at the cost of more repetitive
-- code around them.

-- Every player's queue - ours included - lives in this one set of
-- dictionaries, keyed by "<playerID>#<jobId>" rather than by jobId alone,
-- since two different players' jobIds aren't related to each other at all
-- (each player assigns their own, starting near 1) and would otherwise
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
local jobReach = {} -- reach enum for the job's spot, or nil for unrestricted (see the network protocol comment above)
local jobPriority = {} -- 0=low, 1=high, or nil for medium/normal (see the network protocol comment above)
local jobUnitID = {} -- the job's actual in-world unit, or nil if none exists yet
local jobOwner = {} -- jobOwner[key] = the owning playerID

-- Reverse index of jobUnitID, for any player's job: unitIDToOwnerKey[unitID]
-- = the owning key ("<ownerPlayerID>#<jobId>"). Spring unitIDs are globally
-- unique (not per-team), so one flat table works for every player's jobs at
-- once - GetJobByUnitID() below is the only reader, SetJobUnitID() the only
-- writer, kept in sync with jobUnitID wherever it changes.
local unitIDToOwnerKey = {}

-- How many workers each player has individually assigned to a given job,
-- independent of who owns it - an ally can assist a job without becoming
-- its owner, and the owner's own workers are just another contribution
-- alongside theirs. Keyed by "<ownerKey>#<assistingPlayerID>" so multiple
-- players' contributions to the same job don't collide.
local assistWorkers = {}

-- jobWorkersTotal[ownerKey] = the sum of assistWorkers[ownerKey.."#"..p] over
-- every assisting player p, maintained incrementally by SetAssist() as
-- contributions change rather than re-summed by scanning on every read.
local jobWorkersTotal = {}

-- Which of our own jobIds have changed since the last send, and how: true
-- means UpdateJob() was called (so the fields above already hold the new
-- values, ready to encode), false means DeleteJob() was called. Populated
-- directly by the public API (see the bottom of this file) rather than by
-- comparing against a second full copy of our own data every send tick - the
-- caller already knows exactly when something changed, so there's nothing to
-- diff. Keyed by bare jobId (a number), not "<playerID>#<jobId>", since it
-- only ever tracks our own changes.
local pendingStatus = {}

-- Same idea as pendingStatus, but for our own assist contributions: which
-- jobs (by ownerKey, since we can assist a job without owning it) we've
-- changed our own worker count on since the last send. Populated by
-- AssistJob() and drained by BroadcastPending() alongside pendingStatus.
local pendingAssist = {}

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Encoding / Decoding ---------------------------------------------------------

local function EncodeUpsert(jobId, cmdId, x, y, z, h, r, target, reach, priority, unitID)
	return "U," .. jobId .. ","
		.. (cmdId or 0) .. ","
		.. floor(x or 0) .. ","
		.. floor(y or 0) .. ","
		.. floor(z or 0) .. ","
		.. (h and floor(h) or "") .. ","
		.. (r and floor(r) or "") .. ","
		.. (target and floor(target) or "") .. ","
		.. (reach and floor(reach) or "") .. ","
		.. (priority and floor(priority) or "") .. ","
		.. (unitID and floor(unitID) or "")
		.. ";"
end

local function EncodeRemove(jobId)
	return "R," .. jobId .. ";"
end

local function EncodeAssist(ownerPlayerID, jobId, workers)
	return "A," .. ownerPlayerID .. "," .. jobId .. "," .. floor(workers or 0) .. ";"
end

-- Splits a record into its op char and everything after the first comma,
-- without otherwise interpreting it - the op-specific Decode* functions
-- below do that, so a caller only pays for parsing the shape it actually got.
local function DecodeRecord(record)
	return record:match("^(%a),(.*)$")
end

-- Returns the decoded scalar fields for a "U" record's rest (deliberately
-- not packed into a job table, to avoid allocating one per record decoded).
local function DecodeUpsert(rest)
	local jobId, cmdId, x, y, z, h, r, target, reach, priority, unitID =
		rest:match("^(%d+),(-?%d+),(-?%d+),(-?%d+),(-?%d+),(%d*),(%d*),(%d*),(%d*),(%d*),(%d*)$")
	if not jobId then
		return nil
	end
	return tonumber(jobId), tonumber(cmdId), tonumber(x), tonumber(y), tonumber(z),
		(h ~= "") and tonumber(h) or nil,
		(r ~= "") and tonumber(r) or nil,
		(target ~= "") and tonumber(target) or nil,
		(reach ~= "") and tonumber(reach) or nil,
		(priority ~= "") and tonumber(priority) or nil,
		(unitID ~= "") and tonumber(unitID) or nil
end

local function DecodeAssist(rest)
	local ownerPlayerID, jobId, workers = rest:match("^(%d+),(%d+),(%d+)$")
	if not ownerPlayerID then
		return nil
	end
	return tonumber(ownerPlayerID), tonumber(jobId), tonumber(workers)
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Sending -----------------------------------------------------------------

-- Sent whole, in one SendLuaUIMsg call - see the network protocol comment
-- above for why that's safe.
local function SendBatch(records)
	local msg = MSG_PREFIX .. table.concat(records)
	spSendLuaUIMsg(msg, "a")
	spSendLuaUIMsg(msg, "s")
end

-- Reads back one of our own jobs by its bare jobId, deriving the storage key
-- the same way UpdateJob does.
local function EncodeLocalUpsert(jobId)
	local key = myPlayerID .. "#" .. jobId
	return EncodeUpsert(jobId, cmdId[key], jobX[key], jobY[key], jobZ[key],
		jobH[key], jobR[key], jobTarget[key], jobReach[key], jobPriority[key], jobUnitID[key])
end

-- Reads back our own current assist contribution to ownerKey, deriving the
-- assist storage key the same way SetAssist does.
local function EncodeLocalAssist(ownerKey)
	local ownerPlayerID, jobId = ownerKey:match("^(%d+)#(%d+)$")
	return EncodeAssist(ownerPlayerID, jobId, assistWorkers[ownerKey .. "#" .. myPlayerID])
end

-- Marks every jobId we currently own as pending an update, in response to a
-- sync request from a newly-initialized widget elsewhere. Scanning the whole
-- (everyone's) table to find just our own entries only happens here, when
-- someone actually asks for it - never on the much more frequent
-- BroadcastPending() path below, which only ever touches pendingStatus.
local function MarkAllOwnJobsPending()
	local myKeyPrefix = myPlayerID .. "#"
	for key, owner in pairs(jobOwner) do
		if owner == myPlayerID then
			-- tonumber() here matters: pendingStatus is keyed by the same
			-- number type UpdateJob()/DeleteJob() use directly, and a string
			-- substring of key wouldn't equal that number as a table key.
			pendingStatus[tonumber(key:sub(#myKeyPrefix + 1))] = true
		end
	end

	-- Our own assist contributions are just as much "our data" as our own
	-- jobs are - a fresh widget elsewhere won't have seen those either.
	local mySuffix = "#" .. myPlayerID
	for assistKey in pairs(assistWorkers) do
		if assistKey:sub(-#mySuffix) == mySuffix then
			pendingAssist[assistKey:sub(1, -#mySuffix - 1)] = true
		end
	end
end

-- Drains up to MAX_UPDATES_PER_SEND of whatever UpdateJob()/DeleteJob() have
-- queued up since the last send, removing only the jobIds actually included
-- this time - anything past the cap just stays in pendingStatus for the next
-- send to pick up (or gets overwritten first if it changes again before
-- then), so one big burst spreads across multiple ticks instead of spiking a
-- single frame's message count.
local function BroadcastPending()
	local records
	local sent = 0
	for jobId, isUpdate in pairs(pendingStatus) do
		if sent >= MAX_UPDATES_PER_SEND then
			break
		end
		records = records or {}
		if isUpdate then
			records[#records+1] = EncodeLocalUpsert(jobId)
		else
			records[#records+1] = EncodeRemove(jobId)
		end
		pendingStatus[jobId] = nil
		sent = sent + 1
	end

	for ownerKey in pairs(pendingAssist) do
		if sent >= MAX_UPDATES_PER_SEND then
			break
		end
		records = records or {}
		records[#records+1] = EncodeLocalAssist(ownerKey)
		pendingAssist[ownerKey] = nil
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

-- Applies one player's reported assist contribution to a job (ownerKey,
-- since the job may belong to someone else entirely), adjusting the job's
-- running total by the difference rather than re-summing every contributor.
-- Shared by AssistJob() (our own contribution) and ApplyRecordsData() below
-- (everyone else's). A dangling contribution to a job that doesn't exist
-- (yet, or anymore - see the network protocol comment on ordering) is stored
-- exactly the same as any other: it costs nothing to hold, and resolves
-- itself if the job later shows up or is cleaned up alongside it.
local function SetAssist(ownerKey, assistingPlayerID, workers)
	local assistKey = ownerKey .. "#" .. assistingPlayerID
	local old = assistWorkers[assistKey] or 0
	workers = workers or 0
	assistWorkers[assistKey] = (workers ~= 0) and workers or nil
	local total = (jobWorkersTotal[ownerKey] or 0) - old + workers
	jobWorkersTotal[ownerKey] = (total ~= 0) and total or nil
end

-- Sets (or clears, with unitID=nil) a job's in-world unit, keeping
-- unitIDToOwnerKey in sync - the only place either jobUnitID or the reverse
-- index gets written, so they can never drift apart.
local function SetJobUnitID(key, unitID)
	local old = jobUnitID[key]
	if old == unitID then
		return
	end
	if old then
		unitIDToOwnerKey[old] = nil
	end
	jobUnitID[key] = unitID
	if unitID then
		unitIDToOwnerKey[unitID] = key
	end
end

-- Clears one job by its full storage key ("<playerID>#<jobId>"), whether
-- it's ours or another player's - shared by DeleteJob() and the receiving
-- code below. Also drops every assist contribution to it (ours and anyone
-- else's) and its worker total, since none of that means anything once the
-- job's gone. This is an O(assistWorkers size) scan, same tradeoff
-- ClearPlayerJobs below already makes: fine for a rare, per-job event, not
-- something that runs on the frequent send/receive path.
local function ClearJob(key)
	cmdId[key] = nil
	jobX[key] = nil
	jobY[key] = nil
	jobZ[key] = nil
	jobH[key] = nil
	jobR[key] = nil
	jobTarget[key] = nil
	jobReach[key] = nil
	jobPriority[key] = nil
	SetJobUnitID(key, nil)
	jobOwner[key] = nil
	jobWorkersTotal[key] = nil
	local prefix = key .. "#"
	for assistKey in pairs(assistWorkers) do
		if assistKey:sub(1, #prefix) == prefix then
			assistWorkers[assistKey] = nil
		end
	end
end

local function ApplyRecordsData(playerID, data)
	for record in data:gmatch("([^;]+);") do
		local op, rest = DecodeRecord(record)
		if op == "U" then
			local jobId, decodedCmdId, x, y, z, h, r, target, reach, priority, unitID = DecodeUpsert(rest)
			if jobId then
				local key = playerID .. "#" .. jobId
				cmdId[key] = decodedCmdId
				jobX[key] = x
				jobY[key] = y
				jobZ[key] = z
				jobH[key] = h
				jobR[key] = r
				jobTarget[key] = target
				jobReach[key] = reach
				jobPriority[key] = priority
				SetJobUnitID(key, unitID)
				jobOwner[key] = playerID
			end
		elseif op == "R" then
			ClearJob(playerID .. "#" .. rest)
		elseif op == "A" then
			local ownerPlayerID, jobId, workers = DecodeAssist(rest)
			if ownerPlayerID then
				SetAssist(ownerPlayerID .. "#" .. jobId, playerID, workers)
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

	ApplyRecordsData(playerID, rest)
end

-- Precise, event-driven cleanup instead of a timeout: a player's queue stops
-- mattering exactly when they leave (PlayerRemoved - disconnect/quit/kick) or
-- resign (PlayerChanged, when Spring.GetPlayerInfo now reports them as a
-- spectator), not after some guessed number of quiet seconds. This also means
-- a player who simply hasn't changed their queue in a while is never
-- mistaken for one who's gone.
local function ClearPlayerJobs(playerID)
	for key, owner in pairs(jobOwner) do
		if owner == playerID then
			ClearJob(key)
		end
	end

	-- Also drop whatever this player was assisting, even jobs they didn't own
	-- themselves - ClearJob() above only cleared assist entries for jobs
	-- *they* owned, not their contributions to everyone else's.
	local suffix = "#" .. playerID
	for assistKey, workers in pairs(assistWorkers) do
		if assistKey:sub(-#suffix) == suffix then
			local ownerKey = assistKey:sub(1, -#suffix - 1)
			local total = (jobWorkersTotal[ownerKey] or 0) - workers
			jobWorkersTotal[ownerKey] = (total ~= 0) and total or nil
			assistWorkers[assistKey] = nil
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
	BroadcastPending()
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

-- Ghost buildings are colored by player, not a teamID we'd have to keep
-- correct ourselves - the same GetPlayerInfo(...).team lookup GBC's own
-- helpers elsewhere use for "this player's color", not a cached team we
-- picked up whenever we last happened to receive something from them (which
-- could otherwise go stale after a mid-game team change, since nothing here
-- listens for widget:TeamChanged). `cache` is a plain table the caller
-- creates fresh once per draw call and passes into every DrawJobGhost() this
-- frame, so a player with many queued jobs only costs one real lookup, not
-- one per job.
local function GetOwnerTeamID(ownerPlayerID, cache)
	local teamID = cache[ownerPlayerID]
	if teamID == nil then
		local _, _, _, t = spGetPlayerInfo(ownerPlayerID, false)
		teamID = t or false
		cache[ownerPlayerID] = teamID
	end
	return teamID or nil
end

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
	local teamIDCache = {}
	for key, cmdIdValue in pairs(cmdId) do
		DrawJobGhost(cmdIdValue, jobX[key], jobY[key], jobZ[key], jobH[key], GetOwnerTeamID(jobOwner[key], teamIDCache))
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
-- whenever it adds a job or changes one it already has. `job` must have the
-- fields documented in the network protocol comment above (id, x, y, z, and
-- the optional h/r/target/reach/priority/unitID).
--
-- Unlike a caller-derived hash, jobId is assigned BY THIS WIDGET: pass nil to
-- create a new job (a fresh jobId is returned - hold onto it), or an
-- existing jobId to update that same job in place (returned back unchanged,
-- so the call always tells you which job it touched either way). GBC's own
-- `buildQueue[hash] = myCmd` becomes tracking the returned jobId itself
-- (eg. in its own per-command bookkeeping) instead of computing a hash.
--
-- There's no "replace everything" call: a jobId sticks around until
-- Delete() is called for it specifically, so every removal needs its own
-- explicit Delete() call - eg. GBC's own `buildQueue[hash] = nil` needs a
-- matching `WG.GlobalBuildQueueShare.Delete(jobId)` alongside it, not just
-- the removal of the Lua table entry.
local function UpdateJob(jobId, job)
	if not jobId then
		jobId = nextJobId
		nextJobId = nextJobId + 1
	end
	local key = myPlayerID .. "#" .. jobId
	cmdId[key] = job.id
	jobX[key] = job.x
	jobY[key] = job.y
	jobZ[key] = job.z
	jobH[key] = job.h
	jobR[key] = job.r
	jobTarget[key] = job.target
	jobReach[key] = job.reach
	jobPriority[key] = job.priority
	SetJobUnitID(key, job.unitID)
	jobOwner[key] = myPlayerID
	pendingStatus[jobId] = true
	return jobId
end

-- To be called whenever a job is removed - eg. GBC's own
-- `buildQueue[hash] = nil` becomes `WG.GlobalBuildQueueShare.Delete(jobId)`,
-- using whatever jobId the matching Update() call returned.
local function DeleteJob(jobId)
	ClearJob(myPlayerID .. "#" .. jobId)
	pendingStatus[jobId] = false
end

-- To be called whenever the number of workers *we* have assigned to a job
-- changes, whether it's our own job or one we're just assisting - eg. an AI
-- deciding to send 2 workers to help build something an ally queued would
-- call WG.GlobalBuildQueueShare.Assist(allyPlayerID, jobId, 2). Unlike
-- Update()/Delete(), the job's owner has to be named explicitly, since we're
-- reporting our own contribution to a job we don't necessarily own.
-- workers = 0 (or nil) means we've stopped assisting it.
local function AssistJob(ownerPlayerID, jobId, workers)
	local ownerKey = ownerPlayerID .. "#" .. jobId
	SetAssist(ownerKey, myPlayerID, workers)
	pendingAssist[ownerKey] = true
end

-- Returns one of a job's core fields (see the network protocol comment above
-- for what each means), or nil if the job doesn't exist. This is GBC's own
-- read access into any player's queue, including its own - the same way
-- GetWorkerCount()/GetReach()/GetPriority()/GetUnitID() below expose the
-- rest of a job's data.
local function GetCmdId(ownerPlayerID, jobId)
	return cmdId[ownerPlayerID .. "#" .. jobId]
end
local function GetX(ownerPlayerID, jobId)
	return jobX[ownerPlayerID .. "#" .. jobId]
end
local function GetY(ownerPlayerID, jobId)
	return jobY[ownerPlayerID .. "#" .. jobId]
end
local function GetZ(ownerPlayerID, jobId)
	return jobZ[ownerPlayerID .. "#" .. jobId]
end
local function GetH(ownerPlayerID, jobId)
	return jobH[ownerPlayerID .. "#" .. jobId]
end
local function GetR(ownerPlayerID, jobId)
	return jobR[ownerPlayerID .. "#" .. jobId]
end
local function GetTarget(ownerPlayerID, jobId)
	return jobTarget[ownerPlayerID .. "#" .. jobId]
end

-- Returns the total number of workers everyone (owner included) has
-- currently assigned to a job, for an AI deciding what a worker should work
-- on next. 0 if nobody's reported assisting it (or it doesn't exist).
local function GetWorkerCount(ownerPlayerID, jobId)
	return jobWorkersTotal[ownerPlayerID .. "#" .. jobId] or 0
end

-- Returns the reach enum value the job's owner set via Update() (see the
-- network protocol comment above for what each value means), or nil if the
-- job is unrestricted or doesn't exist - another factor for an AI deciding
-- what a worker should work on next, alongside GetWorkerCount().
local function GetReach(ownerPlayerID, jobId)
	return jobReach[ownerPlayerID .. "#" .. jobId]
end

-- Returns the job's priority (0=low, 1=high), or nil for medium/normal - see
-- the network protocol comment above. Purely carried data, same as reach:
-- this widget doesn't act on it itself.
local function GetPriority(ownerPlayerID, jobId)
	return jobPriority[ownerPlayerID .. "#" .. jobId]
end

-- Returns the job's actual in-world unit, or nil if none exists yet (or the
-- job doesn't exist) - eg. to check build progress directly instead of only
-- knowing the job's world position.
local function GetUnitID(ownerPlayerID, jobId)
	return jobUnitID[ownerPlayerID .. "#" .. jobId]
end

-- The reverse of GetUnitID: given a unit (any player's), returns the
-- ownerPlayerID and jobId of the job it belongs to, or nil if it isn't
-- currently any job's unit. Doesn't require already knowing who owns it.
local function GetJobByUnitID(unitID)
	local ownerKey = unitIDToOwnerKey[unitID]
	if not ownerKey then
		return nil
	end
	local ownerPlayerID, jobId = ownerKey:match("^(%d+)#(%d+)$")
	return tonumber(ownerPlayerID), tonumber(jobId)
end

function widget:Initialize()
	myPlayerID = spGetMyPlayerID()
	-- Seeds jobId assignment so a widget reload mid-game can't reissue one
	-- of our own earlier jobIds (see nextJobId's declaration above) - the
	-- sim frame only ever increases, and is the same for every client, so
	-- this is safely higher than anything issued before this Initialize().
	nextJobId = Spring.GetGameFrame() * 1000000 + 1
	-- Ask everyone else to (re-)send their current queue, since we won't have
	-- seen any of the deltas from before we existed (eg. this widget just got
	-- enabled mid-game).
	spSendLuaUIMsg(MSG_PREFIX .. "S", "a")
	spSendLuaUIMsg(MSG_PREFIX .. "S", "s")
	WG.GlobalBuildQueueShare = {
		Update = UpdateJob,
		Delete = DeleteJob,
		Assist = AssistJob,
		GetCmdId = GetCmdId,
		GetX = GetX,
		GetY = GetY,
		GetZ = GetZ,
		GetH = GetH,
		GetR = GetR,
		GetTarget = GetTarget,
		GetWorkerCount = GetWorkerCount,
		GetReach = GetReach,
		GetPriority = GetPriority,
		GetUnitID = GetUnitID,
		GetJobByUnitID = GetJobByUnitID,
	}
end

function widget:Shutdown()
	WG.GlobalBuildQueueShare = nil
end
