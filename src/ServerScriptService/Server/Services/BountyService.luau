--!strict
-- Bounty hunting. Owns Player Bounty end to end (save value, `Bounty` attribute), the wanted
-- list, the physical BountyBoard with one server-built poster per wanted player, taking a bounty
-- (a "Bounty: <name>" Tool that IS the bounty), tracking the target while the Tool is equipped,
-- and the payout when the jail imprisons a target (ClearForImprisonment).
--
-- Hunting rules, all checked here: Adventurer rank, not self, the target online and wanted, one
-- bounty at a time. The bounty ends when the Tool is lost (dropped, destroyed, death, leaving),
-- the target stops being wanted (cleared, imprisoned, left), or the hunter leaves.
--
-- The board is the first Part named Config.Bounty.BoardName ("QuestBoard", or BoardAltName) under
-- Workspace that carries a Decal named FrontDecalName; the Decal's Face is the side posters go on.
-- Without one a placeholder board is made in Workspace.BountyPlaceholders, the way MissionService
-- makes placeholder drop-offs. Posters are made by the server, not by a GUI: each is a Part (so it
-- carries its own ProximityPrompt) with a SurfaceGui for the text.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Config = require(ReplicatedStorage.Shared.Config)
local SaveSchema = require(ReplicatedStorage.Shared.SaveSchema)
local Cities = require(ReplicatedStorage.Shared.Data.Cities)
local BountyData = require(ReplicatedStorage.Shared.Data.Bounty)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local RankService = require(script.Parent.RankService)
local DevService = require(script.Parent.DevService)

local log = Log.new("BountyService")

type Data = SaveSchema.Data
type Reward = BountyData.Reward
type TrackingState = BountyData.TrackingState

export type Entry = {
	userId: number,
	name: string,
	bounty: number,
	city: string,
}

export type Hunt = {
	targetUserId: number,
	tool: Tool,
	tracking: TrackingState,
	-- Whether the last tick saw the Tool in the hunter's hands.
	equipped: boolean,
	connections: { RBXScriptConnection },
}

-- Poster id -> Part. Production owns one; tests make their own.
export type PosterSet = { [number]: Part? }

local PLACEHOLDER_BOARD_NAME = "BountyBoard_PLACEHOLDER"
local PLACEHOLDER_FOLDER_NAME = "BountyPlaceholders"
local POSTER_FOLDER_NAME = "BountyPosters"
local PLACEHOLDER_CITY = "Qarzin"
local POSTER_ROWS = 2
local POSTER_COLUMNS = math.ceil(Config.Bounty.MaxPosters / POSTER_ROWS)

local BountyService = {}

-- ==================== pure core (self-tested directly) ====================

-- Pure: adds a crime's bounty (whole numbers, never below 0). Returns the new total.
function BountyService.ApplyAdd(data: Data, amount: number): number
	data.Bounty = math.max(0, math.floor(data.Bounty + amount))
	return data.Bounty
end

-- Pure: sets the bounty outright (dev). Returns the new total.
function BountyService.ApplySet(data: Data, amount: number): number
	data.Bounty = math.max(0, math.floor(amount))
	return data.Bounty
end

-- Pure: whether a hunter may take this bounty. `targetBounty` is nil when the target is offline
-- or has no save loaded. Returns (true) or (false, reason shown to the hunter).
function BountyService.CheckTake(
	hunterRankIndex: number,
	hunterUserId: number,
	targetUserId: number,
	targetBounty: number?,
	hunterHoldsOne: boolean
): (boolean, string?)
	if hunterUserId == targetUserId then
		return false, "You cannot take a bounty on yourself."
	end
	if not BountyData.canTakeAtRank(hunterRankIndex) then
		return false, "Only an Adventurer or better may take a bounty."
	end
	if hunterHoldsOne then
		return false, "You already hold a bounty."
	end
	if targetBounty == nil or not BountyData.isWanted(targetBounty) then
		return false, "That player is no longer wanted."
	end
	return true, nil
end

-- Pure: the imprisonment payout, once. Zeroes the prisoner's bounty and returns the reward, or
-- nil when they are not wanted (so a second call, or a jailing with no bounty, pays nothing).
function BountyService.Settle(prisonerData: Data): Reward?
	local bounty = prisonerData.Bounty
	if not BountyData.isWanted(bounty) then
		return nil
	end
	prisonerData.Bounty = 0
	return BountyData.rewardFor(bounty)
end

-- Pure: poster list from candidates: wanted only, highest bounty first (name breaks ties), at
-- most `maxPosters`.
function BountyService.BuildEntries(candidates: { Entry }, maxPosters: number): { Entry }
	local wanted: { Entry } = {}
	for _, entry in candidates do
		if BountyData.isWanted(entry.bounty) then
			table.insert(wanted, entry)
		end
	end
	table.sort(wanted, function(a: Entry, b: Entry)
		if a.bounty ~= b.bounty then
			return a.bounty > b.bounty
		end
		return a.name < b.name
	end)
	while #wanted > maxPosters do
		table.remove(wanted)
	end
	return wanted
end

-- Pure: the city whose region part contains `position`, else "Unknown". Cities.Keys order decides
-- overlaps.
function BountyService.CityAt(position: Vector3, regionParts: { [string]: BasePart }): string
	for _, key in Cities.Keys do
		local part = regionParts[key]
		if part then
			local local3 = part.CFrame:PointToObjectSpace(position)
			local half = part.Size / 2
			if math.abs(local3.X) <= half.X and math.abs(local3.Y) <= half.Y and math.abs(local3.Z) <= half.Z then
				return key
			end
		end
	end
	return BountyData.UnknownCity
end

-- Pure: every hunter whose target is `targetUserId`.
function BountyService.HuntersOf(hunts: { [Player]: Hunt }, targetUserId: number): { Player }
	local hunters: { Player } = {}
	for hunter, hunt in hunts do
		if hunt.targetUserId == targetUserId then
			table.insert(hunters, hunter)
		end
	end
	return hunters
end

-- Per board face: the outward normal, and the viewer's right and up, all in the board's local
-- axes. A viewer faces the face from outside; Top/Bottom take the board's front (-Z) as up.
type FaceFrame = { normal: Vector3, right: Vector3, up: Vector3 }

local FACE_FRAMES: { [Enum.NormalId]: FaceFrame } = {
	[Enum.NormalId.Front] = { normal = Vector3.new(0, 0, -1), right = Vector3.new(-1, 0, 0), up = Vector3.new(0, 1, 0) },
	[Enum.NormalId.Back] = { normal = Vector3.new(0, 0, 1), right = Vector3.new(1, 0, 0), up = Vector3.new(0, 1, 0) },
	[Enum.NormalId.Right] = { normal = Vector3.new(1, 0, 0), right = Vector3.new(0, 0, -1), up = Vector3.new(0, 1, 0) },
	[Enum.NormalId.Left] = { normal = Vector3.new(-1, 0, 0), right = Vector3.new(0, 0, 1), up = Vector3.new(0, 1, 0) },
	[Enum.NormalId.Top] = { normal = Vector3.new(0, 1, 0), right = Vector3.new(1, 0, 0), up = Vector3.new(0, 0, -1) },
	[Enum.NormalId.Bottom] = { normal = Vector3.new(0, -1, 0), right = Vector3.new(-1, 0, 0), up = Vector3.new(0, 0, -1) },
}

local POSTER_THICKNESS = 0.1
local CANVAS_PIXELS_PER_STUD = 60
local POSTER_OFFSET = 0.03

local function absVector(v: Vector3): Vector3
	return Vector3.new(math.abs(v.X), math.abs(v.Y), math.abs(v.Z))
end

-- Pure: where poster `index` of `count` goes on `face` of `board`, as the Part's world CFrame
-- (same orientation as the board, so a SurfaceGui on the same face reads correctly) and size.
-- Posters fill a grid of POSTER_COLUMNS x POSTER_ROWS cells over the face, row by row from the
-- viewer's top left, each row centred, the block centred; a poster is Config.Bounty.Poster's size
-- or 90% of its cell, whichever is smaller, and sits just proud of the face.
function BountyService.PosterLayout(board: BasePart, face: Enum.NormalId, index: number, count: number): (CFrame, Vector3)
	local frame = FACE_FRAMES[face]
	local size = board.Size
	local width = absVector(frame.right):Dot(size)
	local height = absVector(frame.up):Dot(size)
	local depth = absVector(frame.normal):Dot(size)

	local cellW = width / POSTER_COLUMNS
	local cellH = height / POSTER_ROWS
	local posterW = math.min(Config.Bounty.Poster.Width, cellW * 0.9)
	local posterH = math.min(Config.Bounty.Poster.Height, cellH * 0.9)

	local columns = math.min(count, POSTER_COLUMNS)
	local rowsUsed = math.ceil(count / columns)
	local row = (index - 1) // columns
	local column = (index - 1) % columns
	local inRow = if row == rowsUsed - 1 then count - row * columns else columns
	local x = (column - (inRow - 1) / 2) * cellW
	local y = ((rowsUsed - 1) / 2 - row) * cellH

	local local3 = frame.right * x + frame.up * y + frame.normal * (depth / 2 + POSTER_THICKNESS / 2 + POSTER_OFFSET)
	-- Poster size in board-local axes: the tangent axes get width/height, the normal axis the thickness.
	local posterSize = absVector(frame.right) * posterW + absVector(frame.up) * posterH + absVector(frame.normal) * POSTER_THICKNESS
	return board.CFrame * CFrame.new(local3), posterSize
end

-- ==================== regions ====================

-- The `<key>REGION` part under Workspace.Regions, or nil. Shared with MissionService.
function BountyService.FindRegionPart(cityKey: string): BasePart?
	local regions = Workspace:FindFirstChild("Regions")
	local part = regions and regions:FindFirstChild(cityKey .. "REGION", true)
	if part and part:IsA("BasePart") then
		return part
	end
	return nil
end

local function regionParts(): { [string]: BasePart }
	local parts: { [string]: BasePart } = {}
	for _, key in Cities.Keys do
		local part = BountyService.FindRegionPart(key)
		if part then
			parts[key] = part
		end
	end
	return parts
end

local function rootPosition(player: Player): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

-- ==================== state ====================

local hunts: { [Player]: Hunt } = {}
local lastCity: { [Player]: string } = {}
-- Players whose release has started: no longer postered, never a target.
local leaving: { [Player]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local productionPosters: PosterSet = {}

-- A one-line player-facing notice (the client shows it as a chat system line).
function BountyService.Notify(player: Player, text: string)
	if typeof(player) == "Instance" then
		Remotes.Server.Fire("BountyNotice", player, { text = text })
	end
end

local function vectorTable(v: Vector3): { x: number, y: number, z: number }
	return { x = v.X, y = v.Y, z = v.Z }
end

-- ==================== tool ====================

-- The Tool that is the bounty. Plain: no handle, can't be dropped.
function BountyService.IssueTool(targetUserId: number, targetName: string, bounty: number, parent: Instance): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Bounty: " .. targetName
	tool.ToolTip = string.format("Wanted: %s (bounty %d)", targetName, bounty)
	tool.RequiresHandle = false
	tool.CanBeDropped = false
	tool:SetAttribute("BountyTarget", targetUserId)
	tool.Parent = parent
	return tool
end

-- Calls `onLost` once when `tool` is destroyed or ends up somewhere `isHeldAt(parent)` refuses
-- (dropped to the world, another player's hands). Returns the connection.
function BountyService.WatchTool(tool: Tool, isHeldAt: (parent: Instance) -> boolean, onLost: () -> ()): RBXScriptConnection
	local lost = false
	return tool.AncestryChanged:Connect(function()
		if lost then
			return
		end
		local parent = tool.Parent
		if parent ~= nil and tool:IsDescendantOf(game) and isHeldAt(parent) then
			return
		end
		lost = true
		onLost()
	end)
end

-- Calls `onDied` once when `humanoid` dies. A hunter's death costs them the poster (a knockout
-- does not: it never reaches Humanoid.Died).
function BountyService.WatchDeath(humanoid: Humanoid, onDied: () -> ()): RBXScriptConnection
	return humanoid.Died:Once(onDied)
end

-- ==================== board and posters ====================

local function posterFolder(): Folder
	local existing = Workspace:FindFirstChild(POSTER_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = POSTER_FOLDER_NAME
	folder.Parent = Workspace
	return folder
end

export type Board = { part: BasePart, face: Enum.NormalId }

-- The first BasePart under `root` named BoardName (or BoardAltName) with a Decal named
-- FrontDecalName; the Decal's Face is the side players look at.
function BountyService.FindBoard(root: Instance): Board?
	local rules = Config.Bounty
	for _, instance in root:GetDescendants() do
		if instance:IsA("BasePart") and (instance.Name == rules.BoardName or instance.Name == rules.BoardAltName) then
			local decal = instance:FindFirstChild(rules.FrontDecalName)
			if decal and decal:IsA("Decal") then
				return { part = instance, face = decal.Face }
			end
		end
	end
	return nil
end

local placeholderBoard: Board? = nil
local placeholderLogged = false

local function makePlaceholderBoard(): Board?
	local regionPart = BountyService.FindRegionPart(PLACEHOLDER_CITY)
	local configured: Vector3? = Config.Missions.PlaceholderDeliveryPoints[PLACEHOLDER_CITY]
	local position = if regionPart then regionPart.Position else configured
	if position == nil then
		return nil
	end

	-- Like MissionService.groundBelow: the ray starts at the region box's top and ignores it,
	-- so it finds the ground rather than the box.
	local ground: Vector3 = position
	if regionPart then
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { regionPart }
		local top = Vector3.new(position.X, position.Y + regionPart.Size.Y / 2, position.Z)
		local hit = Workspace:Raycast(top, Vector3.new(0, -(regionPart.Size.Y + 1000), 0), params)
		if hit then
			ground = hit.Position
		end
	end
	local center = ground + Vector3.new(0, 5, 0)

	local folder = Workspace:FindFirstChild(PLACEHOLDER_FOLDER_NAME)
	if folder == nil then
		folder = Instance.new("Folder")
		folder.Name = PLACEHOLDER_FOLDER_NAME
		folder.Parent = Workspace
	end

	local part = Instance.new("Part")
	part.Name = PLACEHOLDER_BOARD_NAME
	part.Size = Vector3.new(16, 8, 0.5)
	part.Anchored = true
	part.CanCollide = false
	part.Material = Enum.Material.Wood
	part.Color = Color3.fromRGB(110, 78, 48)
	part.CFrame = CFrame.new(center)
	part.Parent = folder

	if not placeholderLogged then
		placeholderLogged = true
		log:Warn(string.format("No %s board with a %s decal under Workspace - using a placeholder board at %s", Config.Bounty.BoardName, Config.Bounty.FrontDecalName, tostring(center)))
	end
	local board: Board = { part = part, face = Enum.NormalId.Front }
	return board
end

local cachedBoard: Board? = nil
local boardCheckedAt = -math.huge

-- The real board, else a placeholder (made once, reused while it exists). The workspace scan
-- repeats at most every BOARD_RESCAN_SECONDS while there is no valid board.
local BOARD_RESCAN_SECONDS = 10

local function resolveBoard(): Board?
	if cachedBoard and cachedBoard.part:IsDescendantOf(Workspace) then
		return cachedBoard
	end
	local now = os.clock()
	if now - boardCheckedAt < BOARD_RESCAN_SECONDS and cachedBoard == nil then
		return placeholderBoard
	end
	boardCheckedAt = now
	local found = BountyService.FindBoard(Workspace)
	if found then
		cachedBoard = found
		return found
	end
	cachedBoard = nil
	if placeholderBoard and placeholderBoard.part:IsDescendantOf(Workspace) then
		return placeholderBoard
	end
	placeholderBoard = makePlaceholderBoard()
	return placeholderBoard
end

local function makePoster(entry: Entry, folder: Instance, face: Enum.NormalId): Part
	local poster = Instance.new("Part")
	poster.Name = "Poster_" .. entry.userId
	poster.Anchored = true
	poster.CanCollide = false
	poster.CanQuery = false
	poster.Material = Enum.Material.SmoothPlastic
	poster.Color = Color3.fromRGB(226, 205, 160)
	poster:SetAttribute("TargetUserId", entry.userId)

	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(300, 400)
	gui.Parent = poster

	local function label(name: string, y: number, height: number, bold: boolean)
		local text = Instance.new("TextLabel")
		text.Name = name
		text.BackgroundTransparency = 1
		text.Position = UDim2.fromScale(0.05, y)
		text.Size = UDim2.fromScale(0.9, height)
		text.TextScaled = true
		text.Font = if bold then Enum.Font.Antique else Enum.Font.Gotham
		text.TextColor3 = Color3.fromRGB(60, 35, 20)
		text.Parent = gui
	end
	label("Header", 0.05, 0.2, true)
	label("Name", 0.3, 0.2, true)
	label("Bounty", 0.55, 0.17, false)
	label("City", 0.75, 0.15, false)

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Take bounty"
	prompt.ObjectText = entry.name
	prompt.HoldDuration = 0.4
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = 10
	prompt.Parent = poster
	local userId = entry.userId
	prompt.Triggered:Connect(function(player: Player)
		local ok, reason = BountyService.Take(player, userId)
		if not ok and reason then
			BountyService.Notify(player, reason)
		end
	end)

	poster.Parent = folder
	return poster
end

local function writePoster(poster: Part, entry: Entry)
	local gui = poster:FindFirstChildOfClass("SurfaceGui")
	if gui == nil then
		return
	end
	local function set(name: string, text: string)
		local label = gui:FindFirstChild(name)
		if label and label:IsA("TextLabel") then
			label.Text = text
		end
	end
	set("Header", "WANTED")
	set("Name", entry.name)
	set("Bounty", string.format("Bounty: %d", entry.bounty))
	set("City", "Last seen: " .. entry.city)

	local prompt = poster:FindFirstChildOfClass("ProximityPrompt")
	if prompt then
		prompt.ObjectText = entry.name
	end
end

-- Makes, updates and removes posters so `set` shows exactly `entries` (already sorted and capped)
-- on `board`'s face, parented under `folder`. A nil board clears every poster.
function BountyService.SyncPosters(set: PosterSet, entries: { Entry }, board: Board?, folder: Instance)
	local keep: { [number]: boolean } = {}
	if board then
		for index, entry in entries do
			keep[entry.userId] = true
			local poster: Part
			local existing = set[entry.userId]
			if existing then
				poster = existing
			else
				poster = makePoster(entry, folder, board.face)
				set[entry.userId] = poster
			end
			writePoster(poster, entry)

			local cframe, size = BountyService.PosterLayout(board.part, board.face, index, #entries)
			poster.Size = size
			poster.CFrame = cframe
			local gui = poster:FindFirstChildOfClass("SurfaceGui")
			if gui then
				gui.Face = board.face
				-- The canvas takes the poster's own proportions, so the text is never stretched.
				local frame = FACE_FRAMES[board.face]
				gui.CanvasSize = Vector2.new(absVector(frame.right):Dot(size) * CANVAS_PIXELS_PER_STUD, absVector(frame.up):Dot(size) * CANVAS_PIXELS_PER_STUD)
			end
		end
	end
	for userId, poster in set do
		if poster and not keep[userId] then
			poster:Destroy()
			set[userId] = nil
		end
	end
end

local function gatherCandidates(): { Entry }
	local candidates: { Entry } = {}
	for _, player in Players:GetPlayers() do
		local data = DataService.Get(player)
		if data and not leaving[player] then
			table.insert(candidates, {
				userId = player.UserId,
				name = player.Name,
				bounty = data.Bounty,
				city = lastCity[player] or BountyData.UnknownCity,
			})
		end
	end
	return candidates
end

-- The current wanted list: highest bounty first.
function BountyService.GetWanted(): { Entry }
	return BountyService.BuildEntries(gatherCandidates(), math.huge)
end

local syncQueued = false

local function syncPostersNow()
	local entries = BountyService.BuildEntries(gatherCandidates(), Config.Bounty.MaxPosters)
	BountyService.SyncPosters(productionPosters, entries, resolveBoard(), posterFolder())
end

local function requestSync()
	if syncQueued then
		return
	end
	syncQueued = true
	task.defer(function()
		syncQueued = false
		syncPostersNow()
	end)
end

-- ==================== hunting ====================

local function targetState(target: Player?, hunt: Hunt): { [string]: any }
	local data = if target then DataService.Get(target) else nil
	return {
		target = {
			userId = hunt.targetUserId,
			name = if target then target.Name else "",
			bounty = if data then data.Bounty else 0,
		},
		lastKnown = vectorTable(hunt.tracking.lastKnown),
		revealed = hunt.tracking.revealed,
	}
end

-- Self-tests use stand-in tables for players; only a real Player has attributes and a client.
local function isLive(player: Player): boolean
	return typeof(player) == "Instance"
end

local function fireState(hunter: Player, hunt: Hunt)
	if not isLive(hunter) then
		return
	end
	Remotes.Server.Fire("BountyState", hunter, targetState(Players:GetPlayerByUserId(hunt.targetUserId), hunt))
end

local function isEquipped(hunter: Player, hunt: Hunt): boolean
	local character = hunter.Character
	return character ~= nil and hunt.tool.Parent == character
end

-- Brings one hunter's state up to date. `advance` is true only on the tracking tick: it is the
-- one thing that moves the tracking clock. With it false (an equip or unequip event) only the
-- equipped flag changes and the current state is re-sent. Nothing is sent while the Tool is
-- unequipped except one final state clearing `revealed`, which leaves the last known spot where
-- the hunter last saw the target.
local function trackOne(hunter: Player, hunt: Hunt, advance: boolean)
	if hunts[hunter] ~= hunt then
		return
	end

	if not isEquipped(hunter, hunt) then
		if hunt.equipped then
			hunt.equipped = false
			local spot = if hunt.tracking.revealed then hunt.tracking.lastSeen else hunt.tracking.lastKnown
			hunt.tracking = { lastKnown = spot, lastSeen = spot, revealed = false, beyondSeconds = 0 }
			fireState(hunter, hunt)
		end
		return
	end

	if not advance then
		if not hunt.equipped then
			hunt.equipped = true
			fireState(hunter, hunt)
		end
		return
	end

	local hunterPos = rootPosition(hunter)
	if hunterPos == nil then
		return
	end
	local target = Players:GetPlayerByUserId(hunt.targetUserId)
	local targetPos = if target then rootPosition(target) else nil

	local old = hunt.tracking
	local new = BountyData.NextTrackingState(hunterPos, targetPos, old)
	hunt.tracking = new

	local justEquipped = not hunt.equipped
	hunt.equipped = true
	if justEquipped or new.revealed ~= old.revealed or new.lastKnown ~= old.lastKnown then
		fireState(hunter, hunt)
	end
end

local function refreshAttributes(player: Player, data: Data)
	if not isLive(player) then
		return
	end
	player:SetAttribute("Bounty", data.Bounty)
	local hunt = hunts[player]
	local target = if hunt then Players:GetPlayerByUserId(hunt.targetUserId) else nil
	player:SetAttribute("WantedTarget", if target then target.Name else "")
end

-- Ends a hunter's bounty: destroys the Tool, clears the save field, tells the client why.
function BountyService.Drop(hunter: Player, reason: string): boolean
	local hunt = hunts[hunter]
	if hunt == nil then
		return false
	end
	hunts[hunter] = nil
	for _, connection in hunt.connections do
		connection:Disconnect()
	end
	hunt.tool:Destroy()

	local data = DataService.Get(hunter)
	if data then
		data.Progress.Wanted = nil
		refreshAttributes(hunter, data)
	elseif isLive(hunter) then
		hunter:SetAttribute("WantedTarget", "")
	end
	if isLive(hunter) and hunter:IsDescendantOf(Players) and not leaving[hunter] then
		Remotes.Server.Fire("BountyState", hunter, { target = nil, revealed = false, reason = reason })
	end
	log:Info(string.format("%s dropped their bounty (%s)", hunter.Name, reason))
	return true
end

-- Drops every hunter holding `target`; `collector` (if any) gets `collectedReason`, everyone else
-- `reason`.
local function dropHuntersOf(target: Player, reason: string, collector: Player?, collectedReason: string?)
	for _, hunter in BountyService.HuntersOf(hunts, target.UserId) do
		if hunter == collector and collectedReason then
			BountyService.Drop(hunter, collectedReason)
		else
			BountyService.Drop(hunter, reason)
		end
	end
end

local function updateCity(player: Player, parts: { [string]: BasePart }): boolean
	local position = rootPosition(player)
	local city = if position then BountyService.CityAt(position, parts) else BountyData.UnknownCity
	if lastCity[player] == city then
		return false
	end
	lastCity[player] = city
	return true
end

-- Runs after every change to a player's bounty.
local function onBountyChanged(player: Player)
	local data = DataService.Get(player)
	if data == nil then
		return
	end
	refreshAttributes(player, data)

	if BountyData.isWanted(data.Bounty) then
		if lastCity[player] == nil then
			updateCity(player, regionParts())
		end
	else
		lastCity[player] = nil
		dropHuntersOf(player, string.format("%s is no longer wanted.", player.Name), nil, nil)
	end
	requestSync()
end

function BountyService.Get(player: Player): number
	local data = DataService.Get(player)
	return if data then data.Bounty else 0
end

function BountyService.IsWanted(player: Player): boolean
	return BountyData.isWanted(BountyService.Get(player))
end

-- Adds a crime's bounty (MissionService interception goes through here).
function BountyService.Add(player: Player, amount: number, reason: string)
	local data = DataService.Get(player)
	if data == nil then
		log:Warn(string.format("Add(%s, %d, %s): no save loaded", player.Name, amount, reason))
		return
	end
	local old = data.Bounty
	BountyService.ApplyAdd(data, amount)
	log:Info(string.format("%s Bounty %d -> %d (%+d, %s)", player.Name, old, data.Bounty, amount, reason))
	onBountyChanged(player)
end

-- Sets the bounty outright (dev).
function BountyService.Set(player: Player, amount: number, reason: string)
	local data = DataService.Get(player)
	if data == nil then
		log:Warn(string.format("Set(%s, %d, %s): no save loaded", player.Name, amount, reason))
		return
	end
	local old = data.Bounty
	BountyService.ApplySet(data, amount)
	log:Info(string.format("%s Bounty %d -> %d (%s)", player.Name, old, data.Bounty, reason))
	onBountyChanged(player)
end

-- Registers a hunt: the Tool is the bounty, so losing it (`isHeldAt` refuses its new parent, or it
-- is destroyed) or the hunter's death (`hunterHumanoid.Died`) drops it. A death is a drop with the
-- reason "You lost the poster."; a knockout never reaches Died, so it keeps the poster.
function BountyService.StartHunt(
	hunter: Player,
	tool: Tool,
	targetUserId: number,
	targetPos: Vector3,
	hunterHumanoid: Humanoid?,
	isHeldAt: (parent: Instance) -> boolean
): Hunt
	local hunt: Hunt = {
		targetUserId = targetUserId,
		tool = tool,
		tracking = { lastKnown = targetPos, lastSeen = targetPos, revealed = false, beyondSeconds = 0 },
		equipped = false,
		connections = {},
	}
	hunts[hunter] = hunt

	table.insert(
		hunt.connections,
		BountyService.WatchTool(tool, isHeldAt, function()
			BountyService.Drop(hunter, "You lost the bounty.")
		end)
	)
	if hunterHumanoid then
		table.insert(
			hunt.connections,
			BountyService.WatchDeath(hunterHumanoid, function()
				BountyService.Drop(hunter, "You lost the poster.")
			end)
		)
	end
	local function onEquipChange()
		task.defer(trackOne, hunter, hunt, false)
	end
	table.insert(hunt.connections, tool.Equipped:Connect(onEquipChange))
	table.insert(hunt.connections, tool.Unequipped:Connect(onEquipChange))

	fireState(hunter, hunt)
	return hunt
end

function BountyService.IsHunting(hunter: Player): boolean
	return hunts[hunter] ~= nil
end

-- Takes a bounty: returns (true) or (false, reason). The Tool goes in the Backpack.
function BountyService.Take(hunter: Player, targetUserId: number): (boolean, string?)
	local hunterData = DataService.Get(hunter)
	if hunterData == nil then
		return false, "Your save is not loaded yet."
	end
	local target = Players:GetPlayerByUserId(targetUserId)
	local targetData = if target and not leaving[target] then DataService.Get(target) else nil
	local rankIndex = RankService.GetRank(hunter)

	local ok, reason = BountyService.CheckTake(
		rankIndex,
		hunter.UserId,
		targetUserId,
		if targetData then targetData.Bounty else nil,
		hunts[hunter] ~= nil
	)
	if not ok then
		return false, reason
	end

	local backpack = hunter:FindFirstChildOfClass("Backpack")
	local targetPos = if target then rootPosition(target) else nil
	if target == nil or targetData == nil then
		return false, "That player is no longer wanted."
	end
	if backpack == nil then
		return false, "You cannot take a bounty right now."
	end
	if targetPos == nil then
		return false, "That player cannot be found right now."
	end

	local tool = BountyService.IssueTool(targetUserId, target.Name, targetData.Bounty, backpack)
	local hunterHumanoid = if hunter.Character then hunter.Character:FindFirstChildOfClass("Humanoid") else nil
	BountyService.StartHunt(hunter, tool, targetUserId, targetPos, hunterHumanoid, function(parent: Instance): boolean
		return parent == hunter:FindFirstChildOfClass("Backpack") or (hunter.Character ~= nil and parent == hunter.Character)
	end)

	hunterData.Progress.Wanted = targetUserId
	refreshAttributes(hunter, hunterData)
	log:Info(string.format("%s took the bounty on %s (%d)", hunter.Name, target.Name, targetData.Bounty))
	return true, nil
end

-- Called by the jail (M9-02) when `hunter` imprisons `prisoner`: pays the hunter once, zeroes the
-- prisoner's bounty and ends every hunt on them. Returns the reward, or nil (nothing changes)
-- when the prisoner is not wanted, is the hunter, or either save is missing.
function BountyService.ClearForImprisonment(prisoner: Player, hunter: Player): Reward?
	if prisoner == hunter then
		return nil
	end
	local prisonerData = DataService.Get(prisoner)
	if prisonerData == nil or DataService.Get(hunter) == nil then
		return nil
	end
	local reward = BountyService.Settle(prisonerData)
	if reward == nil then
		return nil
	end

	local reason = string.format("Imprisoned %s", prisoner.Name)
	EconomyService.GiveCopperValue(hunter, reward.copper, reason)
	RankService.AddMagoi(hunter, reward.magoi, reason)
	RankService.AddDeed(hunter, "Gold", reward.gold)

	dropHuntersOf(prisoner, string.format("%s is no longer wanted.", prisoner.Name), hunter, "Bounty collected.")
	BountyService.Notify(hunter, "Bounty collected.")
	onBountyChanged(prisoner)
	log:Info(string.format("%s imprisoned %s: %d Copper, %d Magoi, %d Gold Rukh", hunter.Name, prisoner.Name, reward.copper, reward.magoi, reward.gold))
	return reward
end

-- ==================== loops and lifecycle ====================

local function refreshCities()
	local parts = regionParts()
	for _, player in Players:GetPlayers() do
		if BountyService.IsWanted(player) then
			updateCity(player, parts)
		end
	end
	requestSync()
end

local function onPlayerReady(player: Player)
	local data = DataService.Get(player)
	if data == nil then
		return
	end
	-- The tool does not survive a leave, so a saved target is stale.
	data.Progress.Wanted = nil
	refreshAttributes(player, data)
	onBountyChanged(player)
end

-- A Wipe/NewLife swaps the save in place: the old life's hunt and bounty are gone.
local function onPlayerReplaced(player: Player)
	BountyService.Drop(player, "A new life begins.")
	lastCity[player] = nil
	onPlayerReady(player)
end

local function onPlayerReleasing(player: Player)
	leaving[player] = true
	BountyService.Drop(player, "Left the game.")
	dropHuntersOf(player, string.format("%s left.", player.Name), nil, nil)
	lastCity[player] = nil
	requestSync()
end

local function onToolEquippedRemote(player: Player, equipped: boolean)
	local hunt = hunts[player]
	if hunt == nil or equipped ~= isEquipped(player, hunt) then
		return
	end
	trackOne(player, hunt, false)
end

-- ==================== dev commands ====================

local function describe(entry: Entry): string
	return string.format("%s: %d (%s)", entry.name, entry.bounty, entry.city)
end

local function devBounty(caller: Player, args: { string }): string
	local sub = args[1]
	if sub == "list" then
		local entries = BountyService.GetWanted()
		if #entries == 0 then
			return "nobody is wanted"
		end
		local lines: { string } = {}
		for _, entry in entries do
			table.insert(lines, describe(entry))
		end
		return table.concat(lines, "\n")
	elseif sub == "drop" then
		return if BountyService.Drop(caller, "Dropped by dev command.") then "bounty dropped" else "you hold no bounty"
	elseif sub == "take" then
		local target, err = DevService.ResolvePlayer(caller, args[2])
		if target == nil then
			return err or "player not found"
		end
		local ok, reason = BountyService.Take(caller, target.UserId)
		return if ok then string.format("took the bounty on %s", target.Name) else (reason or "refused")
	elseif sub == "clear" then
		local target, err = DevService.ResolvePlayer(caller, args[2])
		if target == nil then
			return err or "player not found"
		end
		BountyService.Set(target, 0, "dev clear")
		return string.format("%s's bounty cleared", target.Name)
	end

	local amount = tonumber(sub)
	if amount == nil then
		return "usage: .bounty <n> [player] | list | take <player> | drop | clear [player]"
	end
	local target, err = DevService.ResolvePlayer(caller, args[2])
	if target == nil then
		return err or "player not found"
	end
	local old = BountyService.Get(target)
	BountyService.Set(target, amount, "dev set")
	return string.format("%s's bounty: %d -> %d", target.Name, old, BountyService.Get(target))
end

-- ==================== service ====================

function BountyService:Init()
	-- Replaces DevService's plain `.bounty <n> [player]` so every change goes through the service.
	DevService.Register("bounty", "<n> [player] | list | take <player> | drop | clear [player] - bounty hunting", devBounty)
end

function BountyService:Start()
	local stale = Workspace:FindFirstChild(PLACEHOLDER_FOLDER_NAME)
	if stale then
		stale:Destroy()
	end
	local stalePosters = Workspace:FindFirstChild(POSTER_FOLDER_NAME)
	if stalePosters then
		stalePosters:Destroy()
	end

	Remotes.Server.On("BountyToolEquipped", onToolEquippedRemote)

	DataService.OnReleasing(onPlayerReleasing)
	DataService.Loaded:Connect(onPlayerReady)
	DataService.Replaced:Connect(onPlayerReplaced)
	for _, player in Players:GetPlayers() do
		if DataService.IsLoaded(player) then
			onPlayerReady(player)
		end
	end

	task.spawn(function()
		local tickSeconds = Config.Bounty.Tracking.TickSeconds
		local sinceCities = 0
		while true do
			task.wait(tickSeconds)
			sinceCities += tickSeconds
			for hunter, hunt in hunts do
				trackOne(hunter, hunt, true)
			end
			if sinceCities >= Config.Bounty.CityRefreshSeconds then
				sinceCities = 0
				refreshCities()
			end
		end
	end)
end

return BountyService
