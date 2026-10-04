--!strict
-- The jail. A hunter carrying a wanted player stands at a JailDrop and hands them over
-- (JailDeliver): the hunter is paid once (BountyService.ClearForImprisonment), the prisoner is put
-- in the cell and serves a sentence set by their bounty. The sentence is a timestamp on the save
-- (Progress.JailUntil, os.time()), so leaving does not skip it: a rejoin or respawn while serving
-- appears in the cell. No bail, no escape; a prisoner who strays past the cell radius is put back.
--
-- Bryan's jail is a Folder named `Jail` (Config.Bounty.Jail names) holding a `JailDropoff` part
-- (the zone a hunter stands in) and a `LargeCell` folder with a `JailSpawn` part inside the cell.
-- The cell's bounds are the bounding box of every part under LargeCell, grown by BoundsMargin: a
-- prisoner outside it is put back at JailSpawn (the bars have gaps, so this is the real wall). If
-- no such folder exists, a `hasJail` city gets a placeholder cell in Workspace.MissionPlaceholders,
-- made on first use. A hunter's bounty is on one player: only the carried player they hold the
-- bounty on can be handed over.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Config = require(ReplicatedStorage.Shared.Config)
local Cities = require(ReplicatedStorage.Shared.Data.Cities)
local JailData = require(ReplicatedStorage.Shared.Data.Jail)
local SaveSchema = require(ReplicatedStorage.Shared.SaveSchema)
local DataService = require(script.Parent.DataService)
local PlayerService = require(script.Parent.PlayerService)
local StatusService = require(script.Parent.StatusService)
local CarryService = require(script.Parent.CarryService)
local BountyService = require(script.Parent.BountyService)
local DevService = require(script.Parent.DevService)

local log = Log.new("JailService")

export type Bounds = { min: Vector3, max: Vector3 }

export type JailSite = {
	city: string,
	dropoff: BasePart,
	spawn: BasePart,
	bounds: Bounds,
}

local PLACEHOLDER_FOLDER_NAME = "MissionPlaceholders"
local SITE_RESCAN_SECONDS = 10
local SPAWN_RAISE = 3
local PLACEHOLDER_CITY = "Qarzin"

local JailService = {}

-- ==================== pure core ====================

-- Pure: whether a delivery may go ahead. Returns (true) or (false, the one-line reply).
function JailService.CheckDeliver(carrying: boolean, nearDropoff: boolean, targetIsHunted: boolean, prisonerWanted: boolean): (boolean, string?)
	if not carrying then
		return false, "You are not carrying anyone."
	end
	if not nearDropoff then
		return false, "There is no jail here."
	end
	if not targetIsHunted then
		return false, "That is not the person your bounty is on."
	end
	if not prisonerWanted then
		return false, "They are not wanted."
	end
	return true, nil
end

-- Pure: the world-space box around `parts`, grown by `margin` studs on every side. Nil for no parts.
function JailService.BoundsOf(parts: { BasePart }, margin: number): Bounds?
	local lo: Vector3? = nil
	local hi: Vector3? = nil
	for _, part in parts do
		local cf = part.CFrame
		local half = part.Size / 2
		-- The half-extent of a rotated box along each world axis.
		local extent = Vector3.new(
			math.abs(cf.RightVector.X) * half.X + math.abs(cf.UpVector.X) * half.Y + math.abs(cf.LookVector.X) * half.Z,
			math.abs(cf.RightVector.Y) * half.X + math.abs(cf.UpVector.Y) * half.Y + math.abs(cf.LookVector.Y) * half.Z,
			math.abs(cf.RightVector.Z) * half.X + math.abs(cf.UpVector.Z) * half.Y + math.abs(cf.LookVector.Z) * half.Z
		)
		local partLo = cf.Position - extent
		local partHi = cf.Position + extent
		lo = if lo then lo:Min(partLo) else partLo
		hi = if hi then hi:Max(partHi) else partHi
	end
	if lo == nil or hi == nil then
		return nil
	end
	local grow = Vector3.new(margin, margin, margin)
	return { min = lo - grow, max = hi + grow }
end

-- Pure: whether `point` is inside `bounds`.
function JailService.Contains(bounds: Bounds, point: Vector3): boolean
	return point.X >= bounds.min.X
		and point.X <= bounds.max.X
		and point.Y >= bounds.min.Y
		and point.Y <= bounds.max.Y
		and point.Z >= bounds.min.Z
		and point.Z <= bounds.max.Z
end

-- Pure: how far `point` is from the part's box (0 inside it).
function JailService.DistanceToBox(part: BasePart, point: Vector3): number
	local localPoint = part.CFrame:PointToObjectSpace(point)
	local half = part.Size / 2
	local outside = Vector3.new(
		math.max(math.abs(localPoint.X) - half.X, 0),
		math.max(math.abs(localPoint.Y) - half.Y, 0),
		math.max(math.abs(localPoint.Z) - half.Z, 0)
	)
	return outside.Magnitude
end

-- Pure: the site whose dropoff box is within ReachStuds of `position`, nearest first.
function JailService.SiteNear(position: Vector3, sites: { JailSite }): JailSite?
	local best: JailSite? = nil
	local bestDistance = Config.Bounty.Jail.ReachStuds
	for _, site in sites do
		local distance = JailService.DistanceToBox(site.dropoff, position)
		if distance <= bestDistance then
			best = site
			bestDistance = distance
		end
	end
	return best
end

-- Pure: a hunter's bounty is on `target` when their saved target is that player.
function JailService.IsHunted(hunterWanted: number?, targetUserId: number): boolean
	return hunterWanted ~= nil and hunterWanted == targetUserId
end

-- Pure: the sentence on the save (os.time() end, 0 = free).
function JailService.ApplyImprison(data: SaveSchema.Data, seconds: number, now: number)
	data.Progress.JailUntil = now + math.floor(JailData.SafeSeconds(seconds))
end

-- Pure: frees the save. Returns whether it was serving.
function JailService.ApplyRelease(data: SaveSchema.Data): boolean
	if data.Progress.JailUntil == 0 then
		return false
	end
	data.Progress.JailUntil = 0
	return true
end

-- ==================== sites ====================

local function partNamed(parent: Instance, name: string): BasePart?
	local found = parent:FindFirstChild(name)
	if found and found:IsA("BasePart") then
		return found
	end
	return nil
end

local function partsUnder(folder: Instance): { BasePart }
	local parts: { BasePart } = {}
	for _, descendant in folder:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

-- Bryan's jail folder under `root`: the first descendant named JailFolderName with a DropoffName
-- part, a CellFolderName folder, and a SpawnName part inside that folder or directly under the
-- jail folder. Scans `root`, so callers cache the result.
function JailService.FindJailFolder(root: Instance): Instance?
	local names = Config.Bounty.Jail
	for _, instance in root:GetDescendants() do
		if instance.Name == names.JailFolderName and not instance:IsA("BasePart") then
			local cell = instance:FindFirstChild(names.CellFolderName)
			local spawn = (if cell then partNamed(cell, names.SpawnName) else nil) or partNamed(instance, names.SpawnName)
			if partNamed(instance, names.DropoffName) and cell and spawn then
				return instance
			end
		end
	end
	return nil
end

-- Measures a jail folder found by FindJailFolder. Parts are found by name only where the name is
-- unique (the cell's walls are all one name, so they are never looked up).
function JailService.SiteFromFolder(folder: Instance): JailSite?
	local names = Config.Bounty.Jail
	local dropoff = partNamed(folder, names.DropoffName)
	local cell = folder:FindFirstChild(names.CellFolderName)
	local spawn = (if cell then partNamed(cell, names.SpawnName) else nil) or partNamed(folder, names.SpawnName)
	if dropoff == nil or cell == nil or spawn == nil then
		return nil
	end
	local bounds = JailService.BoundsOf(partsUnder(cell), names.BoundsMargin)
	if bounds == nil then
		return nil
	end
	return { city = PLACEHOLDER_CITY, dropoff = dropoff, spawn = spawn, bounds = bounds }
end

function JailService.FindJail(root: Instance): JailSite?
	local folder = JailService.FindJailFolder(root)
	return if folder then JailService.SiteFromFolder(folder) else nil
end

local placeholders: { [string]: JailSite? } = {}

-- A cell for a city with no jail: an anchored, mostly transparent box with a magenta floor,
-- JailSpawn inside and JailDropoff outside.
local function makePlaceholder(cityKey: string): JailSite?
	local regionPart = BountyService.FindRegionPart(cityKey)
	local base: Vector3? = if regionPart then regionPart.Position else Config.Missions.PlaceholderDeliveryPoints[cityKey]
	if base == nil then
		return nil
	end
	local center = base + Config.Bounty.Jail.PlaceholderOffset

	local folder = Workspace:FindFirstChild(PLACEHOLDER_FOLDER_NAME)
	if folder == nil then
		folder = Instance.new("Folder")
		folder.Name = PLACEHOLDER_FOLDER_NAME
		folder.Parent = Workspace
	end

	local model = Instance.new("Model")
	model.Name = "Jail_PLACEHOLDER_" .. cityKey

	local function part(name: string, size: Vector3, position: Vector3, color: Color3, transparency: number, collide: boolean): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.Position = position
		p.Anchored = true
		p.CanCollide = collide
		p.Color = color
		p.Transparency = transparency
		p.Material = Enum.Material.SmoothPlastic
		p.Parent = model
		return p
	end

	local glass = Color3.fromRGB(180, 180, 200)
	local cellParts: { BasePart } = {
		part("JailFloor", Vector3.new(24, 1, 24), center, Color3.fromRGB(255, 0, 200), 0, true),
		part("WallN", Vector3.new(24, 14, 1), center + Vector3.new(0, 7.5, -12), glass, 0.8, true),
		part("WallS", Vector3.new(24, 14, 1), center + Vector3.new(0, 7.5, 12), glass, 0.8, true),
		part("WallE", Vector3.new(1, 14, 24), center + Vector3.new(12, 7.5, 0), glass, 0.8, true),
		part("WallW", Vector3.new(1, 14, 24), center + Vector3.new(-12, 7.5, 0), glass, 0.8, true),
		part("Roof", Vector3.new(24, 1, 24), center + Vector3.new(0, 15, 0), glass, 0.8, true),
	}
	local spawn = part(Config.Bounty.Jail.SpawnName, Vector3.new(4, 1, 2), center + Vector3.new(0, 1, 0), Color3.fromRGB(255, 255, 255), 1, false)
	local dropoff = part(Config.Bounty.Jail.DropoffName, Vector3.new(12, 1, 8), center + Vector3.new(0, 1, 20), Color3.fromRGB(255, 0, 200), 0.5, false)
	model.Parent = folder

	local bounds = JailService.BoundsOf(cellParts, Config.Bounty.Jail.BoundsMargin)
	if bounds == nil then
		return nil
	end
	log:Warn(string.format("No %s folder found under Workspace - using a placeholder cell for %s at %s", Config.Bounty.Jail.JailFolderName, cityKey, tostring(center)))
	local site: JailSite = { city = cityKey, dropoff = dropoff, spawn = spawn, bounds = bounds }
	return site
end

local function siteValid(site: JailSite): boolean
	return site.spawn:IsDescendantOf(Workspace) and site.dropoff:IsDescendantOf(Workspace)
end

-- The resolved Bryan jail folder and its measured site, kept until the folder leaves the
-- workspace or something under it changes (then only the measuring repeats, not the Workspace
-- scan). With no folder, Workspace is rescanned at most every SITE_RESCAN_SECONDS.
local jailFolder: Instance? = nil
local jailSite: JailSite? = nil
local jailDirty = false
local jailConnections: { RBXScriptConnection } = {}
local lastScanAt = -math.huge

local function forgetJail()
	for _, connection in jailConnections do
		connection:Disconnect()
	end
	table.clear(jailConnections)
	jailFolder = nil
	jailSite = nil
	jailDirty = false
	lastScanAt = -math.huge
end

local function adoptJail(folder: Instance)
	forgetJail()
	jailFolder = folder
	jailDirty = true
	table.insert(jailConnections, folder.AncestryChanged:Connect(forgetJail))
	table.insert(jailConnections, folder.DescendantAdded:Connect(function()
		jailDirty = true
	end))
	table.insert(jailConnections, folder.DescendantRemoving:Connect(function()
		jailDirty = true
	end))
end

local function realSite(): JailSite?
	if jailFolder and not jailFolder:IsDescendantOf(Workspace) then
		forgetJail()
	end
	if jailFolder == nil then
		local now = os.clock()
		if now - lastScanAt < SITE_RESCAN_SECONDS then
			return nil
		end
		lastScanAt = now
		local found = JailService.FindJailFolder(Workspace)
		if found == nil then
			return nil
		end
		adoptJail(found)
	end
	if jailDirty and jailFolder then
		jailDirty = false
		jailSite = JailService.SiteFromFolder(jailFolder)
	end
	return jailSite
end

-- The jail(s): Bryan's, else a placeholder for each hasJail city.
function JailService.Sites(): { JailSite }
	local real = realSite()
	if real then
		return { real }
	end
	local sites: { JailSite } = {}
	for _, city in Cities.List do
		if city.hasJail then
			local site = placeholders[city.key]
			if site == nil or not siteValid(site) then
				site = makePlaceholder(city.key)
				placeholders[city.key] = site
			end
			if site then
				table.insert(sites, site)
			end
		end
	end
	return sites
end

-- Where a rejoining or respawning prisoner appears: the first jail.
local function defaultSite(): JailSite?
	return JailService.Sites()[1]
end

local function cellCFrame(site: JailSite): CFrame
	return site.spawn.CFrame + Vector3.new(0, site.spawn.Size.Y / 2 + SPAWN_RAISE, 0)
end

-- Puts a prisoner back at the cell spawn if they are outside its bounds. Returns whether it did.
function JailService.EnforceCell(character: Model, site: JailSite): boolean
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") or JailService.Contains(site.bounds, root.Position) then
		return false
	end
	character:PivotTo(cellCFrame(site))
	return true
end

-- Pure: the cell spawn a player appears at, or nil when not serving at `now`.
function JailService.SpawnCFrameFor(jailUntil: number, now: number, site: JailSite?): CFrame?
	if site == nil or not JailData.IsServing(jailUntil, now) then
		return nil
	end
	return cellCFrame(site)
end

-- ==================== state ====================

local jailedAt: { [Player]: JailSite } = {}

local function tell(player: Player, text: string)
	BountyService.Notify(player, text)
end

-- A prisoner cannot jump (the cell's bars have gaps; the bounds check is the real wall). The
-- humanoid's own values are put back on release. A new character (respawn) records its own.
local savedJump: { [Humanoid]: { power: number, height: number } } = setmetatable({}, { __mode = "k" }) :: any

-- Stops a prisoner jumping, remembering the humanoid's own values.
function JailService.LockJump(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end
	if savedJump[humanoid] == nil then
		savedJump[humanoid] = { power = humanoid.JumpPower, height = humanoid.JumpHeight }
	end
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0
end

-- Puts the humanoid's own jump values back.
function JailService.UnlockJump(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local saved = if humanoid then savedJump[humanoid] else nil
	if humanoid and saved then
		humanoid.JumpPower = saved.power
		humanoid.JumpHeight = saved.height
		savedJump[humanoid] = nil
	end
end

function JailService.IsJailed(player: Player): boolean
	local data = DataService.Get(player)
	return data ~= nil and JailData.IsServing(data.Progress.JailUntil, os.time())
end

-- Marks the player as a prisoner of `site` now: status, attribute, and a teleport into the cell.
local function enterCell(player: Player, site: JailSite)
	jailedAt[player] = site
	local data = DataService.Get(player)
	if data then
		player:SetAttribute("JailUntil", data.Progress.JailUntil)
	end
	local character = player.Character
	if character then
		StatusService.Apply(character, "Jailed")
		JailService.LockJump(character)
		character:PivotTo(cellCFrame(site))
	end
end

-- Sentences `player` to `seconds` in `site` (default: the first jail). Returns whether it did.
function JailService.Imprison(player: Player, seconds: number, site: JailSite?): boolean
	local data = DataService.Get(player)
	local target = site or defaultSite()
	if data == nil or target == nil then
		return false
	end
	JailService.ApplyImprison(data, seconds, os.time())
	-- A prisoner stops hunting from the cell.
	BountyService.Drop(player, "You are in jail.")
	enterCell(player, target)
	log:Info(string.format("%s jailed for %d s in %s", player.Name, seconds, target.city))
	return true
end

-- Ends the sentence: free, back at the city spawn.
function JailService.Release(player: Player, reason: string): boolean
	local data = DataService.Get(player)
	if data == nil or not JailService.ApplyRelease(data) then
		return false
	end
	jailedAt[player] = nil
	player:SetAttribute("JailUntil", 0)
	local character = player.Character
	if character then
		StatusService.Remove(character, "Jailed")
		JailService.UnlockJump(character)
		local spawn = PlayerService.GetSpawnCFrame()
		if spawn then
			character:PivotTo(spawn)
		end
	end
	tell(player, reason)
	log:Info(string.format("%s released (%s)", player.Name, reason))
	return true
end

-- Pure: whether a hunter whose bounty is on `hunterWanted` could hand `targetUserId` over, and the
-- dropoff's full name (given whenever a jail exists). Feeds CarryState.
function JailService.DeliveryInfo(hunterWanted: number?, targetUserId: number, site: JailSite?): (boolean, string?)
	if site == nil then
		return false, nil
	end
	return JailService.IsHunted(hunterWanted, targetUserId), site.dropoff:GetFullName()
end

local function deliveryInfo(hunter: Player, target: Player): (boolean, string?)
	local hunterData = DataService.Get(hunter)
	return JailService.DeliveryInfo(if hunterData then hunterData.Progress.Wanted else nil, target.UserId, JailService.Sites()[1])
end

-- A hunter hands over the player they carry.
function JailService.Deliver(hunter: Player): (boolean, string?)
	local prisoner = CarryService.GetCarried(hunter)
	local root = if hunter.Character then hunter.Character:FindFirstChild("HumanoidRootPart") else nil
	local site = if root and root:IsA("BasePart") then JailService.SiteNear(root.Position, JailService.Sites()) else nil
	local hunterData = DataService.Get(hunter)
	local hunted = prisoner ~= nil and hunterData ~= nil and JailService.IsHunted(hunterData.Progress.Wanted, prisoner.UserId)
	local wanted = prisoner ~= nil and BountyService.IsWanted(prisoner)

	local ok, reason = JailService.CheckDeliver(prisoner ~= nil, site ~= nil, hunted, wanted)
	if not ok or prisoner == nil or site == nil then
		if reason then
			tell(hunter, reason)
		end
		return false, reason
	end

	local bounty = BountyService.Get(prisoner)
	local reward = BountyService.ClearForImprisonment(prisoner, hunter)
	if reward == nil then
		tell(hunter, "They are not wanted.")
		return false, "They are not wanted."
	end

	CarryService.Drop(hunter, "jailed", cellCFrame(site))
	JailService.Imprison(prisoner, JailData.SentenceSeconds(bounty), site)
	tell(
		hunter,
		string.format("%s is behind bars. Reward: %d Copper, %d Magoi, %d Gold Rukh.", prisoner.Name, reward.copper, reward.magoi, reward.gold)
	)
	return true, nil
end

-- ==================== loop and lifecycle ====================

local function checkPlayer(player: Player)
	local data = DataService.Get(player)
	if data == nil then
		return
	end
	local now = os.time()
	local jailUntil = data.Progress.JailUntil
	if jailUntil == 0 then
		return
	end
	if not JailData.IsServing(jailUntil, now) then
		JailService.Release(player, "You have served your sentence.")
		return
	end

	local known = jailedAt[player]
	local site: JailSite
	if known and siteValid(known) then
		site = known
	else
		local fallback = defaultSite()
		if fallback == nil then
			return
		end
		site = fallback
		jailedAt[player] = fallback
	end
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if character == nil or root == nil or not root:IsA("BasePart") then
		return
	end
	if not StatusService.Has(character, "Jailed") then
		StatusService.Apply(character, "Jailed")
	end
	JailService.LockJump(character)
	JailService.EnforceCell(character, site)
end

local function devJail(caller: Player, args: { string }): string
	local target, err = DevService.ResolvePlayer(caller, args[2])
	if target == nil then
		return err or "player not found"
	end
	if args[1] == "release" then
		return if JailService.Release(target, "You were released.") then string.format("%s released", target.Name) else string.format("%s is not jailed", target.Name)
	end
	local seconds = tonumber(args[1])
	if seconds == nil or seconds ~= seconds or seconds < 0 or seconds == math.huge then
		return "usage: .jail <seconds> [player] | release [player] (seconds is a finite number, 0 or more)"
	end
	seconds = math.min(seconds, Config.Bounty.Jail.MaxSeconds)
	return if JailService.Imprison(target, seconds, nil) then string.format("%s jailed for %d s", target.Name, seconds) else "no save or no jail"
end

function JailService:Init()
	CarryService.SetDeliveryInfo(deliveryInfo)
	DevService.Register("jail", "<seconds> [player] | release [player] - jail a player", devJail)
	-- A jailed player's respawn, and a rejoin mid-sentence, appear in the cell.
	PlayerService.SetSpawnOverride(function(player: Player): CFrame?
		local data = DataService.Get(player)
		if data == nil or not JailData.IsServing(data.Progress.JailUntil, os.time()) then
			return nil
		end
		return JailService.SpawnCFrameFor(data.Progress.JailUntil, os.time(), defaultSite())
	end)
end

function JailService:Start()
	Remotes.Server.On("JailDeliver", function(player: Player)
		JailService.Deliver(player)
	end)

	-- Connected after every Init, so StatusService has already registered the character.
	PlayerService.Ready:Connect(function(player: Player, _character: Model)
		local data = DataService.Get(player)
		if data and JailData.IsServing(data.Progress.JailUntil, os.time()) then
			local site = defaultSite()
			if site then
				enterCell(player, site)
			end
		end
	end)

	-- A wipe/new life frees the prisoner (the save is back to the template).
	DataService.Replaced:Connect(function(player: Player)
		jailedAt[player] = nil
		player:SetAttribute("JailUntil", 0)
		local character = player.Character
		if character then
			StatusService.Remove(character, "Jailed")
			JailService.UnlockJump(character)
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		jailedAt[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(Config.Bounty.Jail.TickSeconds)
			for _, player in Players:GetPlayers() do
				checkPlayer(player)
			end
		end
	end)
end

return JailService
