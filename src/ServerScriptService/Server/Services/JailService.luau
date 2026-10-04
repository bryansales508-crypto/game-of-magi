--!strict
-- The jail. A hunter carrying a wanted player stands at a JailDrop and hands them over
-- (JailDeliver): the hunter is paid once (BountyService.ClearForImprisonment), the prisoner is put
-- in the cell and serves a sentence set by their bounty. The sentence is a timestamp on the save
-- (Progress.JailUntil, os.time()), so leaving does not skip it: a rejoin or respawn while serving
-- appears in the cell. No bail, no escape; a prisoner who strays past the cell radius is put back.
--
-- Bryan places a Model named `Jail` per city with parts `JailDrop` (the door, outside) and
-- `JailSpawn` (inside). A city flagged `hasJail` in Data/Cities with no such model gets a
-- placeholder cell in Workspace.MissionPlaceholders, made on first use.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Config = require(ReplicatedStorage.Shared.Config)
local Cities = require(ReplicatedStorage.Shared.Data.Cities)
local JailData = require(ReplicatedStorage.Shared.Data.Jail)
local DataService = require(script.Parent.DataService)
local PlayerService = require(script.Parent.PlayerService)
local StatusService = require(script.Parent.StatusService)
local CarryService = require(script.Parent.CarryService)
local BountyService = require(script.Parent.BountyService)
local DevService = require(script.Parent.DevService)

local log = Log.new("JailService")

export type JailSite = {
	city: string,
	drop: BasePart,
	spawn: BasePart,
}

local PLACEHOLDER_FOLDER_NAME = "MissionPlaceholders"
local SITE_CACHE_SECONDS = 10
local SPAWN_RAISE = 4

local JailService = {}

-- ==================== pure core ====================

-- Pure: whether a delivery may go ahead. Returns (true) or (false, the one-line reply).
function JailService.CheckDeliver(carrying: boolean, nearJailDrop: boolean, prisonerWanted: boolean): (boolean, string?)
	if not carrying then
		return false, "You are not carrying anyone."
	end
	if not nearJailDrop then
		return false, "There is no jail here."
	end
	if not prisonerWanted then
		return false, "They are not wanted."
	end
	return true, nil
end

-- Pure: the site whose JailDrop is within ReachStuds of `position`, nearest first.
function JailService.SiteNear(position: Vector3, sites: { JailSite }): JailSite?
	local best: JailSite? = nil
	local bestDistance = Config.Bounty.Jail.ReachStuds
	for _, site in sites do
		local distance = (site.drop.Position - position).Magnitude
		if distance <= bestDistance then
			best = site
			bestDistance = distance
		end
	end
	return best
end

-- ==================== sites ====================

local function regionCity(position: Vector3): string
	local parts: { [string]: BasePart } = {}
	for _, key in Cities.Keys do
		local part = BountyService.FindRegionPart(key)
		if part then
			parts[key] = part
		end
	end
	return BountyService.CityAt(position, parts)
end

local function partNamed(model: Instance, name: string): BasePart?
	local found = model:FindFirstChild(name, true)
	if found and found:IsA("BasePart") then
		return found
	end
	return nil
end

local placeholders: { [string]: JailSite? } = {}

-- A cell for a city with no Jail model: an anchored, mostly transparent box with a magenta floor,
-- JailSpawn inside and JailDrop outside the south wall.
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
	part("JailFloor", Vector3.new(24, 1, 24), center, Color3.fromRGB(255, 0, 200), 0, true)
	part("WallN", Vector3.new(24, 14, 1), center + Vector3.new(0, 7.5, -12), glass, 0.8, true)
	part("WallS", Vector3.new(24, 14, 1), center + Vector3.new(0, 7.5, 12), glass, 0.8, true)
	part("WallE", Vector3.new(1, 14, 24), center + Vector3.new(12, 7.5, 0), glass, 0.8, true)
	part("WallW", Vector3.new(1, 14, 24), center + Vector3.new(-12, 7.5, 0), glass, 0.8, true)
	part("Roof", Vector3.new(24, 1, 24), center + Vector3.new(0, 15, 0), glass, 0.8, true)
	local spawn = part("JailSpawn", Vector3.new(4, 1, 4), center + Vector3.new(0, 1, 0), Color3.fromRGB(255, 255, 255), 1, false)
	local drop = part("JailDrop", Vector3.new(4, 1, 4), center + Vector3.new(0, 1, 16), Color3.fromRGB(255, 0, 200), 0.5, false)
	model.Parent = folder

	log:Warn(string.format("No Jail model for %s - using a placeholder cell at %s", cityKey, tostring(center)))
	local site: JailSite = { city = cityKey, drop = drop, spawn = spawn }
	return site
end

local cachedSites: { JailSite } = {}
local cachedAt = -math.huge

-- Every jail: the real Jail models, then a placeholder for each hasJail city without one. Cached
-- for SITE_CACHE_SECONDS; a site whose parts were destroyed is rebuilt.
function JailService.Sites(): { JailSite }
	local now = os.clock()
	if now - cachedAt < SITE_CACHE_SECONDS then
		local valid = true
		for _, site in cachedSites do
			if not site.spawn:IsDescendantOf(Workspace) or not site.drop:IsDescendantOf(Workspace) then
				valid = false
				break
			end
		end
		if valid then
			return cachedSites
		end
	end

	local sites: { JailSite } = {}
	local covered: { [string]: boolean } = {}
	for _, instance in Workspace:GetDescendants() do
		if instance:IsA("Model") and instance.Name == "Jail" then
			local drop = partNamed(instance, "JailDrop")
			local spawn = partNamed(instance, "JailSpawn")
			if drop and spawn then
				local city = regionCity(drop.Position)
				covered[city] = true
				table.insert(sites, { city = city, drop = drop, spawn = spawn })
			end
		end
	end
	for _, city in Cities.List do
		if city.hasJail and not covered[city.key] then
			local site = placeholders[city.key]
			if site == nil or not site.spawn:IsDescendantOf(Workspace) then
				site = makePlaceholder(city.key)
				placeholders[city.key] = site
			end
			if site then
				table.insert(sites, site)
			end
		end
	end

	cachedSites = sites
	cachedAt = now
	return sites
end

-- Where a rejoining or respawning prisoner appears: the first jail.
local function defaultSite(): JailSite?
	return JailService.Sites()[1]
end

local function cellCFrame(site: JailSite): CFrame
	return site.spawn.CFrame + Vector3.new(0, site.spawn.Size.Y / 2 + SPAWN_RAISE, 0)
end

-- ==================== state ====================

local jailedAt: { [Player]: JailSite } = {}

local function tell(player: Player, text: string)
	Remotes.Server.Fire("DevReply", player, text)
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
	data.Progress.JailUntil = os.time() + math.floor(seconds)
	enterCell(player, target)
	log:Info(string.format("%s jailed for %d s in %s", player.Name, seconds, target.city))
	return true
end

-- Ends the sentence: free, back at the city spawn.
function JailService.Release(player: Player, reason: string): boolean
	local data = DataService.Get(player)
	if data == nil or data.Progress.JailUntil == 0 then
		return false
	end
	data.Progress.JailUntil = 0
	jailedAt[player] = nil
	player:SetAttribute("JailUntil", 0)
	local character = player.Character
	if character then
		StatusService.Remove(character, "Jailed")
		local spawn = PlayerService.GetSpawnCFrame()
		if spawn then
			character:PivotTo(spawn)
		end
	end
	tell(player, reason)
	log:Info(string.format("%s released (%s)", player.Name, reason))
	return true
end

-- A hunter hands over the player they carry.
function JailService.Deliver(hunter: Player): (boolean, string?)
	local prisoner = CarryService.GetCarried(hunter)
	local root = if hunter.Character then hunter.Character:FindFirstChild("HumanoidRootPart") else nil
	local site = if root and root:IsA("BasePart") then JailService.SiteNear(root.Position, JailService.Sites()) else nil
	local wanted = prisoner ~= nil and BountyService.IsWanted(prisoner)

	local ok, reason = JailService.CheckDeliver(prisoner ~= nil, site ~= nil, wanted)
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
	if known and known.spawn:IsDescendantOf(Workspace) then
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
	if (root.Position - site.spawn.Position).Magnitude > Config.Bounty.Jail.CellRadius then
		character:PivotTo(cellCFrame(site))
	end
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
	if seconds == nil then
		return "usage: .jail <seconds> [player] | release [player]"
	end
	return if JailService.Imprison(target, seconds, nil) then string.format("%s jailed for %d s", target.Name, seconds) else "no save or no jail"
end

function JailService:Init()
	DevService.Register("jail", "<seconds> [player] | release [player] - jail a player", devJail)
	-- A jailed player's respawn, and a rejoin mid-sentence, appear in the cell.
	PlayerService.SetSpawnOverride(function(player: Player): CFrame?
		if not JailService.IsJailed(player) then
			return nil
		end
		local site = defaultSite()
		return if site then cellCFrame(site) else nil
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
