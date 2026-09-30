--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--
--  file:    gui_global_build_list.lua
--  brief:   Shows the local player's own Global Build Command list, allied
--           players' lists, and (for spectators) everyone's list.
--
--  This widget is the job store for Global Build Command v2
--  (unit_global_build_command.lua): GBC v2 writes jobs through
--  WG.GlobalBuildListShare.Update()/Delete(), and this widget holds them,
--  shares them with allies and spectators, and draws them. GBC v2 doesn't
--  draw its own list - this widget draws it for the local player too, not
--  just for allies/spectators. It never touches anyone's units itself.
--
--  Job identity is assigned by this widget, not the caller: Update() derives
--  a jobId from the job's own content (BuildJobHash) and returns it. Two
--  calls describing the same job - even unrelated code, even after a
--  reload - always get the same jobId back, so there's no "hold onto a
--  handle" bookkeeping and no separate "create" vs "update" case.
--
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

function widget:GetInfo()
	return {
		name      = "Global Build List",
		desc      = "Shows your own Global Build Command list, allied players' lists, and (for spectators) every player's list. Job store for Global Build Command v2.",
		author    = "amnykon",
		date      = "September 25, 2026",
		license   = "GNU GPL, v2 or later",
		layer     = 11,
		enabled   = true, -- on by default, since it's pure information
	}
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Options -----------------------------------------------------------------

options_path = 'Settings/Unit Behaviour/Worker AI'
options_order = {
	'alwaysShow',
}
options = {
	alwaysShow = {
		name = 'Always Show Global Build Lists',
		type = 'bool',
		desc = 'Show allied (and, while spectating, all) players\' Global Build Command lists at all times.\nOtherwise they are only shown while \255\200\200\200shift\255\255\255\255 is held.\n (default = false)',
		value = false,
		advanced = true,
	},
}

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Declarations --------------------------------------------------------------

-- "Localized" API calls, because they run ~33% faster in lua.
local spGetMyPlayerID       = Spring.GetMyPlayerID
local spGetMyTeamID         = Spring.GetMyTeamID
local spGetPlayerList       = Spring.GetPlayerList
local spGetPlayerInfo       = Spring.GetPlayerInfo
local spGetMyAllyTeamID     = Spring.GetMyAllyTeamID
local spGetSpectatingState  = Spring.GetSpectatingState
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

-- Zero-K specific icons, matching the old Global Build Command's job icons.
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
-- "GBCQ|S,<nonce>" - a sync request, sent once by a newly-initialized widget
-- (a LuaUI reload, a rejoin, or the widget enabled mid-game). Anyone
-- receiving it does two things:
--   - marks all of their own currently-owned jobIds as pending (see
--     MarkAllOwnJobsPending), so they go out through the ordinary delta path
--     below rather than needing a separate "full snapshot" message shape.
--   - sends back the copy they hold of the requester's own list (see
--     SendRestore), so the requester gets its own jobs back - they only
--     lived in the widget's memory, and a reload or rejoin loses them.
-- <nonce> is a random number picked per request. Restores quote it back, and
-- the requester only accepts restores quoting its current nonce, so an old
-- restore replayed during a rejoin's catch-up (see below) is ignored.
--
-- "GBCQ|O,<ownerTeamID>,<nonce>;<U records>" - a restore: the U records
-- that follow are the requester's team's jobs, sent back by an ally holding a
-- copy. Only players on that team apply them, and only from allies (never
-- spectators, who could otherwise write into a player's own list). It
-- accepts restores from the first ally to answer and ignores the rest, since
-- every ally should hold the same copy. A big list is split over several
-- messages, each starting with the same header.
--
-- "GBCQ|<data>" - a delta. <data> is zero or more ';'-terminated records,
-- applied on top of whatever the receiver already has, each of one of three
-- forms:
--   U,<jobId>,<cmdId>,<x>,<y>,<z>,<h>,<r>,<target>,<reach>,<priority>,<unitID>,<elevation>,<wall> -- add/update a job
--   R,<jobId>                                                                 -- remove a job
--   A,<ownerTeamID>,<jobId>,<workers>                                          -- report an assist count
-- Empty optional fields (h, r, target, reach, priority, unitID, elevation,
-- wall) are encoded as "".
--   jobId    : a hash derived from the job's own identity-defining fields
--              (see BuildJobHash below), computed by the owner's own widget -
--              never the caller. Unique among that one team's jobs only, so
--              always paired with an owning teamID (implicit as the sender's
--              team for U/R, explicit for A) to address a specific job.
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
--   elevation: build jobs only - the absolute height to build the building
--              at: above the ground is a spire, below it a hole (eg. a
--              buried mex). The terraform to get there is worked out by
--              whoever carries the job out, not stored.
--   wall     : build jobs only - the height of a wall around the building,
--              above its base (eg. area mex's walls). Also worked out by
--              whoever carries the job out.
--
-- A job's worker count isn't part of the job record itself - it's the sum of
-- however many workers each interested player (the owner included) reports
-- assigning to it via "A" records, since any ally can assist a job without
-- owning it. The sender of an "A" record is always the assisting player, so
-- only the job's owning team needs naming
-- explicitly; workers = 0 means that player stopped assisting. There's no
-- ordering guarantee between a job's own "U"/"R" records and "A" records
-- about it - SendLuaUIMsg is relayed immediately by the server, not
-- attached to the deterministic simulation frame stream, so an assist
-- report can arrive before the job it refers to, or after the job's been
-- removed. Both are treated as normal, silent no-ops rather than errors.
--
-- Jobs belong to teams, not players. Normally each player has their own team,
-- so it's the same thing; with commshare, several players control one team
-- (one army), and a job any of them queues goes on that team's one list,
-- which the team leader's GBC works through. Any trusted player on a team
-- can add to, change and remove its jobs (U and R records apply to the
-- sender's team). Assist counts are still per player (A records). A team's
-- list is only cleared once no players are left on it; a player who merges
-- into another team takes their old team's list with them.
--
-- Deltas alone are enough to keep everyone in sync even for a player who joins
-- mid-game: Spring's join-in-progress catch-up replays the recorded network
-- packet stream (including SendLuaUIMsg) from the start of the game, the same
-- way demo playback does. The sync request above exists for the other case a
-- one-off full send would otherwise be needed for: a widget enabled mid-game,
-- which never received any of the deltas sent before it existed. The replay
-- doesn't restore a rejoining player's own list, since RecvLuaMsg ignores
-- our own messages - the restore above covers that, if we have allies.
--
-- Who is listened to: only players, never spectators, since a spectator's
-- jobs would otherwise reach allies' worker AIs. A player only listens to its
-- own allies; a spectator listens to every player. (The engine only delivers
-- "a" messages to allies anyway, but a message sent to everyone would reach
-- enemies too.) Sync requests are the exception: anyone may send one, since
-- spectators need the data as well and answering one only resends our own.
local MSG_PREFIX = "GBCQ|"
local MAX_UPDATES_PER_SEND = 50 -- caps how many changed jobs go out in one delta, so a big burst spreads over multiple sends rather than spiking that one frame's message count

local myPlayerID = spGetMyPlayerID()
-- Jobs belong to teams, not players (see "Jobs belong to teams" below).
local myTeamID = spGetMyTeamID()

-- The team a player is on, or nil.
local function PlayerTeam(playerID)
	local _, _, _, teamID = spGetPlayerInfo(playerID, false)
	return teamID
end

-- Our current sync request's nonce (see the network protocol comment above),
-- and the ally whose restore we accepted for it, so we don't mix copies.
-- Restores are only accepted for RESTORE_WINDOW seconds of being caught up
-- after the request, after which syncNonce is cleared.
local syncNonce = nil
local restoreFrom = nil
local restoreTimer = 0
local RESTORE_WINDOW = 30

-- Whether we're catching up to the server (a rejoin), from GameProgress, as
-- gui_recv_indicator.lua does. While catching up, messages are replays of
-- old ones, so sync requests among them aren't answered: our copy of the
-- requester's list would be from the replay's past, not the present.
local catchingUp = false
local CATCHING_UP_FRAMES = 120

-- Job data is stored as a separate flat dictionary per field (a "struct of
-- arrays"), each keyed by job id, instead of one dictionary of small per-job
-- tables. Lots of small short-lived tables is exactly the kind of thing that
-- produces needless garbage-collector pressure in Lua; a handful of flat
-- dictionaries of plain numbers avoids that, at the cost of more repetitive
-- code around them.

-- Every team's list - ours included - lives in this one set of
-- dictionaries, keyed by "<teamID>#<jobId>" rather than by jobId alone,
-- since jobId is a hash of a job's own content (see BuildJobHash) and two
-- different teams can independently produce the exact same one (eg. both
-- queuing the same building at the same spot) - the teamID prefix is what
-- keeps those from colliding into a single entry. Our own team's entries
-- (owner == myTeamID) are written directly by UpdateJob/DeleteJob, and by
-- commshare teammates' records; everyone else's arrive over the network via
-- RecvLuaMsg/ApplyRecordsData.
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
local jobElevation = {} -- absolute height to build a building at, or nil (see the network protocol comment above)
local jobWall = {} -- height of a wall around a building, or nil (see the network protocol comment above)
local jobOwner = {} -- jobOwner[key] = the owning teamID

-- Reverse index of jobUnitID, for any player's job: unitIDToOwnerKey[unitID]
-- = the owning key ("<ownerTeamID>#<jobId>"). Spring unitIDs are globally
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
-- diff. Keyed by bare jobId, not "<teamID>#<jobId>", since it only ever
-- tracks our own changes.
local pendingStatus = {}

-- Same idea as pendingStatus, but for our own assist contributions: which
-- jobs (by ownerKey, since we can assist a job without owning it) we've
-- changed our own worker count on since the last send. Populated by
-- AssistJob() and drained by BroadcastPending() alongside pendingStatus.
local pendingAssist = {}

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Encoding / Decoding ---------------------------------------------------------

local function EncodeUpsert(jobId, cmdId, x, y, z, h, r, target, reach, priority, unitID, elevation, wall)
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
		.. (unitID and floor(unitID) or "") .. ","
		.. (elevation and floor(elevation) or "") .. ","
		.. (wall and floor(wall) or "")
		.. ";"
end

local function EncodeRemove(jobId)
	return "R," .. jobId .. ";"
end

local function EncodeAssist(ownerTeamID, jobId, workers)
	return "A," .. ownerTeamID .. "," .. jobId .. "," .. floor(workers or 0) .. ";"
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
	local jobId, cmdId, x, y, z, h, r, target, reach, priority, unitID, elevation, wall =
		rest:match("^([^,]+),(-?%d+),(-?%d+),(-?%d+),(-?%d+),(%d*),(%d*),(%d*),(%d*),(%d*),(%d*),(-?%d*),(%d*)$")
	if not jobId then
		return nil
	end
	return jobId, tonumber(cmdId), tonumber(x), tonumber(y), tonumber(z),
		(h ~= "") and tonumber(h) or nil,
		(r ~= "") and tonumber(r) or nil,
		(target ~= "") and tonumber(target) or nil,
		(reach ~= "") and tonumber(reach) or nil,
		(priority ~= "") and tonumber(priority) or nil,
		(unitID ~= "") and tonumber(unitID) or nil,
		(elevation ~= "") and tonumber(elevation) or nil,
		(wall ~= "") and tonumber(wall) or nil
end

local function DecodeAssist(rest)
	local ownerTeamID, jobId, workers = rest:match("^(%d+),([^,]+),(%d+)$")
	if not ownerTeamID then
		return nil
	end
	return tonumber(ownerTeamID), jobId, tonumber(workers)
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
	local key = myTeamID .. "#" .. jobId
	return EncodeUpsert(jobId, cmdId[key], jobX[key], jobY[key], jobZ[key],
		jobH[key], jobR[key], jobTarget[key], jobReach[key], jobPriority[key], jobUnitID[key],
		jobElevation[key], jobWall[key])
end

-- Reads back our own current assist contribution to ownerKey, deriving the
-- assist storage key the same way SetAssist does.
local function EncodeLocalAssist(ownerKey)
	local ownerTeamID, jobId = ownerKey:match("^(%d+)#(.+)$")
	return EncodeAssist(ownerTeamID, jobId, assistWorkers[ownerKey .. "#" .. myPlayerID])
end

-- Marks every jobId we currently own as pending an update, in response to a
-- sync request from a newly-initialized widget elsewhere. Scanning the whole
-- (everyone's) table to find just our own entries only happens here, when
-- someone actually asks for it - never on the much more frequent
-- BroadcastPending() path below, which only ever touches pendingStatus.
local function MarkAllOwnJobsPending()
	local myKeyPrefix = myTeamID .. "#"
	for key, owner in pairs(jobOwner) do
		if owner == myTeamID then
			pendingStatus[key:sub(#myKeyPrefix + 1)] = true
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

-- Answers a sync request by sending requesterID back their team's jobs, as
-- we hold them - see the "O" message in the network protocol comment. Sends
-- nothing if we hold none. Split into messages of MAX_UPDATES_PER_SEND jobs.
local function SendRestore(requesterID, nonce)
	local requesterTeam = PlayerTeam(requesterID)
	if not requesterTeam then
		return
	end
	local header = "O," .. requesterTeam .. "," .. nonce .. ";"
	local prefix = requesterTeam .. "#"
	local records = {header}
	for key, owner in pairs(jobOwner) do
		if owner == requesterTeam then
			local jobId = key:sub(#prefix + 1)
			records[#records+1] = EncodeUpsert(jobId, cmdId[key], jobX[key], jobY[key], jobZ[key],
				jobH[key], jobR[key], jobTarget[key], jobReach[key], jobPriority[key], jobUnitID[key],
		jobElevation[key], jobWall[key])
			if #records > MAX_UPDATES_PER_SEND then
				SendBatch(records)
				records = {header}
			end
		end
	end
	if #records > 1 then
		SendBatch(records)
	end
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

-- Clears one job by its full storage key ("<teamID>#<jobId>"), whether
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
	jobElevation[key] = nil
	jobWall[key] = nil
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

-- Whether to apply records sent by playerID - see "Who is listened to" in
-- the network protocol comment.
local function IsTrustedSender(playerID)
	local _, _, isSpec, _, allyTeamID = spGetPlayerInfo(playerID, false)
	if isSpec ~= false then -- a spectator, or not a valid player
		return false
	end
	return spGetSpectatingState() or allyTeamID == spGetMyAllyTeamID()
end

-- Whether an "O" restore header, sent by playerID, is one we should apply:
-- addressed to us, for our current sync request, and from the first ally to
-- answer it.
local function AcceptRestore(playerID, rest)
	local ownerTeamID, nonce = rest:match("^(%d+),(%d+)$")
	if tonumber(ownerTeamID) ~= myTeamID or not syncNonce or nonce ~= syncNonce then
		return false
	end
	if restoreFrom and restoreFrom ~= playerID then
		return false
	end
	restoreFrom = playerID
	return true
end

local function ApplyRecordsData(playerID, data)
	-- Whose jobs "U" records are: the sender's team's, unless an "O" restore
	-- header says they're our own team's being sent back.
	local senderTeam = PlayerTeam(playerID)
	if not senderTeam then
		return
	end
	local ownerID = senderTeam
	local restoring = false
	local first = true
	for record in data:gmatch("([^;]+);") do
		local op, rest = DecodeRecord(record)
		if op == "O" then
			if not first or not AcceptRestore(playerID, rest) then
				return -- not ours, or not the first record: drop the message
			end
			restoring = true
			ownerID = myTeamID
		elseif op == "U" then
			local jobId, decodedCmdId, x, y, z, h, r, target, reach, priority, unitID, elevation, wall = DecodeUpsert(rest)
			-- A restore never overwrites a job we already have again locally.
			if jobId and not (restoring and jobOwner[ownerID .. "#" .. jobId]) then
				local key = ownerID .. "#" .. jobId
				cmdId[key] = decodedCmdId
				jobX[key] = x
				jobY[key] = y
				jobZ[key] = z
				jobH[key] = h
				jobR[key] = r
				jobTarget[key] = target
				jobReach[key] = reach
				jobPriority[key] = priority
				jobElevation[key] = elevation
				jobWall[key] = wall
				SetJobUnitID(key, unitID)
				jobOwner[key] = ownerID
			end
		elseif restoring then
			-- A restore only carries "U" records.
		elseif op == "R" then
			ClearJob(senderTeam .. "#" .. rest)
		elseif op == "A" then
			local ownerTeamID, jobId, workers = DecodeAssist(rest)
			if ownerTeamID then
				SetAssist(ownerTeamID .. "#" .. jobId, playerID, workers)
			end
		end
		first = false
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

	local nonce = rest:match("^S,(%d+)$")
	if nonce then
		if catchingUp then
			return
		end
		MarkAllOwnJobsPending()
		SendRestore(playerID, nonce)
		return
	end

	if not IsTrustedSender(playerID) then
		return
	end
	ApplyRecordsData(playerID, rest)
end

-- Precise, event-driven cleanup instead of a timeout: a player's list stops
-- mattering exactly when they leave (PlayerRemoved - disconnect/quit/kick) or
-- resign (PlayerChanged, when Spring.GetPlayerInfo now reports them as a
-- spectator), not after some guessed number of quiet seconds. This also means
-- a player who simply hasn't changed their list in a while is never
-- mistaken for one who's gone.
-- Whether any player (other than exceptPlayerID) is still on a team.
local function TeamHasPlayers(teamID, exceptPlayerID)
	local players = spGetPlayerList(teamID, true)
	if players then
		for i = 1, #players do
			local playerID = players[i]
			if playerID ~= exceptPlayerID then
				local _, _, isSpec, playerTeam = spGetPlayerInfo(playerID, false)
				if isSpec == false and playerTeam == teamID then
					return true
				end
			end
		end
	end
	return false
end

-- Clears the lists of teams nobody is on any more.
local function ClearAbandonedTeams(exceptPlayerID)
	local checked = {}
	for key, owner in pairs(jobOwner) do
		if checked[owner] == nil then
			checked[owner] = TeamHasPlayers(owner, exceptPlayerID)
		end
		if not checked[owner] then
			ClearJob(key)
		end
	end
end

local function ClearPlayerJobs(playerID)
	ClearAbandonedTeams(playerID)

	-- Drop whatever this player was assisting - ClearJob() only clears
	-- assist entries for jobs it clears, not their contributions to jobs
	-- that remain.
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

-- We joined another team (a commshare merge, or unmerge): our old team's
-- list moves with us, unless someone is still on the old team to keep it.
local function MoveOwnJobs(oldTeamID, newTeamID)
	if TeamHasPlayers(oldTeamID, myPlayerID) then
		return
	end
	local prefix = oldTeamID .. "#"
	for key, owner in pairs(jobOwner) do
		if owner == oldTeamID then
			local jobId = key:sub(#prefix + 1)
			local newKey = newTeamID .. "#" .. jobId
			if not jobOwner[newKey] then
				cmdId[newKey] = cmdId[key]
				jobX[newKey], jobY[newKey], jobZ[newKey] = jobX[key], jobY[key], jobZ[key]
				jobH[newKey], jobR[newKey], jobTarget[newKey] = jobH[key], jobR[key], jobTarget[key]
				jobReach[newKey], jobPriority[newKey] = jobReach[key], jobPriority[key]
				jobElevation[newKey], jobWall[newKey] = jobElevation[key], jobWall[key]
				jobOwner[newKey] = newTeamID
				local unitID = jobUnitID[key]
				SetJobUnitID(key, nil)
				SetJobUnitID(newKey, unitID)
				pendingStatus[jobId] = true
			end
			ClearJob(key)
		end
	end
end

function widget:PlayerChanged(playerID)
	if playerID == myPlayerID and not spGetSpectatingState() then
		local teamID = spGetMyTeamID()
		if teamID ~= myTeamID then
			local oldTeamID = myTeamID
			myTeamID = teamID
			MoveOwnJobs(oldTeamID, teamID)
		end
	end
	local _, _, isSpec = spGetPlayerInfo(playerID, false)
	if isSpec then
		ClearPlayerJobs(playerID)
	else
		ClearAbandonedTeams()
	end
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Update -----------------------------------------------------------------

function widget:GameProgress(serverFrame)
	catchingUp = (serverFrame - Spring.GetGameFrame()) > CATCHING_UP_FRAMES
end

function widget:Update(dt)
	BroadcastPending()
	if syncNonce and not catchingUp then
		restoreTimer = restoreTimer + dt
		if restoreTimer > RESTORE_WINDOW then
			syncNonce = nil
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
	if options.alwaysShow.value then
		return true
	end
	local _, _, _, shift = spGetModKeyState()
	return shift
end

-- The three helpers below hold the actual GL drawing logic for one job. Since
-- our own list and everyone else's live in the same set of dictionaries
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
		DrawJobGhost(cmdIdValue, jobX[key], jobY[key], jobZ[key], jobH[key], jobOwner[key])
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

-- Derives a job's identity purely from the fields that define what it IS,
-- mirroring the old Global Build Command's own BuildHash (which callers of
-- this widget never need to know about or replicate themselves): a build
-- job is defined by what's being built and where, a single-target repair/
-- reclaim/resurrect job by its target, and an area one by its circle.
-- Two calls describing the same job - even from unrelated code, even after
-- a widget reload - always produce the same jobId, which is what lets
-- UpdateJob() below have no separate "create" vs "update" case: calling it
-- again for a job that already exists just naturally updates that same
-- entry instead of creating a duplicate.
local function BuildJobHash(job)
	if job.id < 0 then -- build job: the site defines it
		return job.id .. "@" .. floor(job.x or 0) .. "x" .. floor(job.z or 0)
	elseif job.target then -- single-target repair/reclaim/resurrect: the target defines it
		return job.id .. "@" .. job.target
	else -- area repair/reclaim/resurrect: the circle defines it
		return job.id .. "@" .. floor(job.x or 0) .. "x" .. floor(job.z or 0) .. "z" .. floor(job.r or 0) .. "r"
	end
end

-- To be called (from unit_global_build_command.lua or similar)
-- whenever it adds a job or changes one it already has. `job` must have the
-- fields documented in the network protocol comment above (id, x, y, z, and
-- the optional h/r/target/reach/priority/unitID/elevation/wall). Returns the jobId (see
-- BuildJobHash above) - useful for a caller that wants to Delete()/Assist()
-- this exact job later without recomputing the hash itself, though it never
-- has to: calling Update() again with the same identity-defining fields
-- always resolves back to the same job.
--
-- There's no "replace everything" call: a jobId sticks around until
-- Delete() is called for it specifically, so every removal needs its own
-- explicit Delete() call - eg. GBC's own `buildQueue[hash] = nil` needs a
-- matching `WG.GlobalBuildListShare.Delete(jobId)` alongside it, not just
-- the removal of the Lua table entry.
local function UpdateJob(job)
	local jobId = BuildJobHash(job)
	if spGetSpectatingState() then
		return jobId -- spectators have no list of their own
	end
	local key = myTeamID .. "#" .. jobId
	cmdId[key] = job.id
	jobX[key] = job.x
	jobY[key] = job.y
	jobZ[key] = job.z
	jobH[key] = job.h
	jobR[key] = job.r
	jobTarget[key] = job.target
	jobReach[key] = job.reach
	jobPriority[key] = job.priority
	jobElevation[key] = job.elevation
	jobWall[key] = job.wall
	SetJobUnitID(key, job.unitID)
	jobOwner[key] = myTeamID
	pendingStatus[jobId] = true
	return jobId
end

-- To be called whenever a job is removed - eg. GBC's own
-- `buildQueue[hash] = nil` becomes `WG.GlobalBuildListShare.Delete(jobId)`,
-- using whatever jobId the matching Update() call returned.
local function DeleteJob(jobId)
	ClearJob(myTeamID .. "#" .. jobId)
	pendingStatus[jobId] = false
end

-- To be called whenever the number of workers *we* have assigned to a job
-- changes, whether it's our own job or one we're just assisting - eg. an AI
-- deciding to send 2 workers to help build something an ally queued would
-- call WG.GlobalBuildListShare.Assist(allyPlayerID, jobId, 2). Unlike
-- Update()/Delete(), the job's owner has to be named explicitly, since we're
-- reporting our own contribution to a job we don't necessarily own.
-- workers = 0 (or nil) means we've stopped assisting it.
local function AssistJob(ownerTeamID, jobId, workers)
	local ownerKey = ownerTeamID .. "#" .. jobId
	SetAssist(ownerKey, myPlayerID, workers)
	pendingAssist[ownerKey] = true
end

-- Returns one of a job's core fields (see the network protocol comment above
-- for what each means), or nil if the job doesn't exist. This is GBC's own
-- read access into any player's list, including its own - the same way
-- GetWorkerCount()/GetReach()/GetPriority()/GetUnitID() below expose the
-- rest of a job's data.
local function GetCmdId(ownerTeamID, jobId)
	return cmdId[ownerTeamID .. "#" .. jobId]
end
local function GetX(ownerTeamID, jobId)
	return jobX[ownerTeamID .. "#" .. jobId]
end
local function GetY(ownerTeamID, jobId)
	return jobY[ownerTeamID .. "#" .. jobId]
end
local function GetZ(ownerTeamID, jobId)
	return jobZ[ownerTeamID .. "#" .. jobId]
end
local function GetH(ownerTeamID, jobId)
	return jobH[ownerTeamID .. "#" .. jobId]
end
local function GetR(ownerTeamID, jobId)
	return jobR[ownerTeamID .. "#" .. jobId]
end
local function GetTarget(ownerTeamID, jobId)
	return jobTarget[ownerTeamID .. "#" .. jobId]
end

-- Returns the total number of workers everyone (owner included) has
-- currently assigned to a job, for an AI deciding what a worker should work
-- on next. 0 if nobody's reported assisting it (or it doesn't exist).
local function GetWorkerCount(ownerTeamID, jobId)
	return jobWorkersTotal[ownerTeamID .. "#" .. jobId] or 0
end

-- Returns the reach enum value the job's owner set via Update() (see the
-- network protocol comment above for what each value means), or nil if the
-- job is unrestricted or doesn't exist - another factor for an AI deciding
-- what a worker should work on next, alongside GetWorkerCount().
local function GetReach(ownerTeamID, jobId)
	return jobReach[ownerTeamID .. "#" .. jobId]
end

-- Returns the job's priority (0=low, 1=high), or nil for medium/normal - see
-- the network protocol comment above. Purely carried data, same as reach:
-- this widget doesn't act on it itself.
local function GetPriority(ownerTeamID, jobId)
	return jobPriority[ownerTeamID .. "#" .. jobId]
end

-- Returns a build job's elevation (absolute height to build the building at)
-- and wall height, each nil if it has none - see the network protocol comment.
local function GetElevation(ownerTeamID, jobId)
	return jobElevation[ownerTeamID .. "#" .. jobId]
end
local function GetWall(ownerTeamID, jobId)
	return jobWall[ownerTeamID .. "#" .. jobId]
end

-- Returns the job's actual in-world unit, or nil if none exists yet (or the
-- job doesn't exist) - eg. to check build progress directly instead of only
-- knowing the job's world position.
local function GetUnitID(ownerTeamID, jobId)
	return jobUnitID[ownerTeamID .. "#" .. jobId]
end

-- The reverse of GetUnitID: given a unit (any player's), returns the
-- ownerTeamID and jobId of the job it belongs to, or nil if it isn't
-- currently any job's unit. Doesn't require already knowing who owns it.
local function GetJobByUnitID(unitID)
	local ownerKey = unitIDToOwnerKey[unitID]
	if not ownerKey then
		return nil
	end
	local ownerTeamID, jobId = ownerKey:match("^(%d+)#(.+)$")
	return tonumber(ownerTeamID), jobId
end

-- Returns an array of every jobId currently on file for ownerTeamID (empty
-- if they have none), in no particular order. The only way to discover a
-- job without already knowing its jobId - eg. for an AI weighing whether one
-- of its own workers should help build something on an ally's list, which
-- needs to see that list's jobs at all before it can cost any of them.
-- Every other Get* function above is a point lookup by (ownerTeamID,
-- jobId); this is the one enumeration this widget exposes.
local function GetJobIds(ownerTeamID)
	local ownerPrefix = ownerTeamID .. "#"
	local jobIds = {}
	for key, owner in pairs(jobOwner) do
		if owner == ownerTeamID then
			jobIds[#jobIds+1] = key:sub(#ownerPrefix + 1)
		end
	end
	return jobIds
end

function widget:Initialize()
	myPlayerID = spGetMyPlayerID()
	myTeamID = spGetMyTeamID()
	-- Ask everyone else to (re-)send their current list, since we won't have
	-- seen any of the deltas from before we existed (eg. this widget just got
	-- enabled mid-game).
	-- The same request also gets our own list sent back by an ally, if a
	-- reload or rejoin lost it.
	syncNonce = tostring(math.random(1, 1000000000))
	restoreFrom = nil
	restoreTimer = 0
	spSendLuaUIMsg(MSG_PREFIX .. "S," .. syncNonce, "a")
	spSendLuaUIMsg(MSG_PREFIX .. "S," .. syncNonce, "s")
	WG.GlobalBuildListShare = {
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
		GetElevation = GetElevation,
		GetWall = GetWall,
		GetJobByUnitID = GetJobByUnitID,
		GetJobIds = GetJobIds,
	}
end

function widget:Shutdown()
	WG.GlobalBuildListShare = nil
end
