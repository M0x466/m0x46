--[[
================================================================================
  M0x46 FINDER  ·  v1.0  ·  owner build
================================================================================
  A full rewrite of the "UNKNOWN / NYX Spawn Panel" architecture, owned by you.

  Two ways to run it
    1) paste the whole file into Delta → Execute   (works offline, no hosting)
    2) host it on a URL you control and run the 3-line loader:
         loadstring(game:HttpGet("https://YOUR-HOST/M0x46_Finder.lua"))()
       Do not use a raw.githubusercontent.com URL you do not own — you cannot
       edit it without pushing a commit, and a takedown kills every user at once.

  Differences from the script this is based on
    • no key system, no /validate endpoint, no obfuscated remote loadstring
    • nothing is fetched and executed at runtime — this file IS the script
    • one config block at the top, one endpoint you control
    • read-only by default: it never moves your character unless you set
      CONFIG.AUTO_JOIN = true and press JOIN yourself

  What it does
    • reads the eggs currently spawned in your server (field scan)
    • renders them as glass cards: rank, name, rarity, income/s, weight or ×scale,
      mutation glyphs, and a JOIN button
    • ALL SERVERS tab: ranked feed of every egg from every server on YOUR backend
    • broadcasts your sightings to YOUR backend (X-M0x46-Room header)
    • optional Auto Join: claims a server on your backend, then teleports you

  Game bridge
    Primary  : ReplicatedStorage.Client.EggState.ReadFieldEggs() + Data.Assets
    Fallback : attribute scan of workspace.AreaEggSlotsClient (see SCHEMA)

  Backend contract (eggfinder-server/server.js in this workspace)
    POST /v1/report  {placeId, jobId, reporterId, ttl, eggs[]}
    GET  /v1/eggs    ?placeId&localJob&limit&offset&minRate&minRank&all=1
    POST /v1/join    {placeId, jobId, uid, reporterId}
================================================================================
]]

--==============================================================================
-- CONFIG  (edit this block only)
--==============================================================================
local CONFIG = {
    ENDPOINT = "https://m0x46-iqjlgk34.back4.app",   -- your backend, no trailing slash
    ROOM_KEY = "jeDFerngBqaQhS_W%b{ExA6-GI,W&:JI",                -- must equal ROOM_KEY on the server

    HOTKEY = Enum.KeyCode.RightControl,
    SCAN_EVERY = 1,                       -- seconds between field scans
    REPORT_EVERY = 5,                     -- seconds between broadcasts
    FEED_EVERY = 6,                       -- seconds between feed refreshes
    SIGHTING_TTL = 300,                   -- seconds a sighting stays live

    MIN_RATE = 1e9,                       -- hide/ignore eggs below this /s
    MIN_RANK = 6,                         -- mythic and up
    CARD_LIMIT = 8,
    BROADCAST = true,                     -- upload sightings to your backend
    AUTO_JOIN = false,                    -- JOIN buttons do nothing unless true
    THEME_STARS = 26,
}

-- Rarity tiers: display order, rank, and colour.
local RARITIES = {
    { name = "Common",    rank = 1,  color = Color3.fromRGB(220, 225, 235) },
    { name = "Uncommon",  rank = 2,  color = Color3.fromRGB(105, 220, 120) },
    { name = "Rare",      rank = 3,  color = Color3.fromRGB(65, 165, 255) },
    { name = "Epic",      rank = 4,  color = Color3.fromRGB(255, 110, 200) },
    { name = "Legendary", rank = 5,  color = Color3.fromRGB(255, 155, 45) },
    { name = "Mythic",    rank = 6,  color = Color3.fromRGB(255, 75, 85) },
    { name = "Cosmic",    rank = 7,  color = Color3.fromRGB(190, 85, 255) },
    { name = "Secret",    rank = 8,  color = Color3.fromRGB(255, 255, 255) },
    { name = "Eternal",   rank = 9,  color = Color3.fromRGB(218, 202, 236) },
    { name = "Divine",    rank = 10, color = Color3.fromRGB(255, 205, 55) },
}
local RARITY_BY_NAME, RARITY_BY_RANK = {}, {}
for _, spec in ipairs(RARITIES) do
    RARITY_BY_NAME[spec.name:lower()] = spec
    RARITY_BY_RANK[spec.rank] = spec
end

-- Minimum-rarity cycle used by the filter button (index 1 = "Any").
local FILTERS = { { name = "Any", rank = 0 } }
for _, spec in ipairs(RARITIES) do FILTERS[#FILTERS + 1] = { name = spec.name, rank = spec.rank } end

-- Attribute names used when the game falls back to the generic scanner.
local SCHEMA = {
    UID = { "Uid", "UID", "EggUid", "Id", "ID" },
    CATEGORY = { "AssetCategory", "Category", "EggType", "Species" },
    SCALE = { "AssetScale", "Scale" },
    MUTATIONS = { "Mutations", "Mutation" },
    AREA = { "AreaId", "Area", "Biome" },
    NEST = { "NestId", "Nest" },
}

--==============================================================================
-- SERVICES / SMALL HELPERS
--==============================================================================
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
assert(player, "Join the game before running M0x46 Finder.")

local function log(...) warn("[M0x46]", ...) end

local function validNumber(value)
    return type(value) == "number" and value == value and value >= 0 and value < math.huge
end

local function money(value)
    if not validNumber(value) or value <= 0 then return "—" end
    local units = { { 1e18, "Qi" }, { 1e15, "Qa" }, { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
    for _, unit in ipairs(units) do
        if value >= unit[1] then return string.format("%.2f%s/s", value / unit[1], unit[2]) end
    end
    return string.format("%d/s", math.floor(value + 0.5))
end

local function compact(value)
    if not validNumber(value) then return "—" end
    if value >= 1e12 then return string.format("%.2fT", value / 1e12) end
    if value >= 1e9 then return string.format("%.2fB", value / 1e9) end
    if value >= 1e6 then return string.format("%.2fM", value / 1e6) end
    if value >= 1e3 then return string.format("%.2fK", value / 1e3) end
    return string.format("%.2f", value)
end

local function requirePath(root, dotted)
    local node = root
    for part in tostring(dotted):gmatch("[^.]+") do
        node = node and node:FindFirstChild(part)
        if not node then return nil end
    end
    if not node:IsA("ModuleScript") then return nil end
    local ok, result = pcall(require, node)
    return ok and result or nil
end

local function readAttribute(object, names)
    for _, name in ipairs(names) do
        local ok, value = pcall(function() return object:GetAttribute(name) end)
        if ok and value ~= nil then return value end
    end
    return nil
end

--==============================================================================
-- GAME BRIDGE
--==============================================================================
local MODULES = {
    eggState = requirePath(ReplicatedStorage, "Client.EggState"),
    assets = requirePath(ReplicatedStorage, "Data.Assets"),
    mutations = requirePath(ReplicatedStorage, "Shared.Modules.Mutations"),
    records = requirePath(ReplicatedStorage, "Shared.Util.EggRecords"),
    slotIdentity = requirePath(ReplicatedStorage, "Shared.Util.AreaEggSlotIdentity"),
    cycle = requirePath(ReplicatedStorage, "Shared.Util.AreaEggCycle"),
    states = nil,
}
do
    local types = requirePath(ReplicatedStorage, "Shared.Types.AreaEggs")
    if type(types) == "table" then MODULES.states = types.States end
end

local CAPS = {
    moduleApi = type(MODULES.eggState) == "table" and type(MODULES.eggState.ReadFieldEggs) == "function",
    cycle = type(MODULES.cycle) == "table",
    attributeScan = false,
    network = type(request) == "function" or type(http_request) == "function"
        or (type(syn) == "table" and type(syn.request) == "function"),
}

local INCOME_UNITS = { [""] = 1, k = 1e3, m = 1e6, b = 1e9, t = 1e12, qa = 1e15, q = 1e15, qi = 1e18 }

local function displayedRate(model)
    if not model then return nil end
    local best
    for _, object in ipairs(model:GetDescendants()) do
        if object:IsA("TextLabel") or object:IsA("TextButton") then
            local text = tostring(object.Text or ""):gsub("<[^>]+>", ""):gsub(",", "")
            local amount, suffix = text:match("%$?%s*(%d+%.?%d*)%s*(%a*)%s*/%s*[sS]")
            if amount then
                local unit = INCOME_UNITS[(suffix or ""):lower()]
                if unit then
                    local value = tonumber(amount) * unit
                    if value and (not best or value > best) then best = value end
                end
            end
        end
    end
    return best
end

local function modelFor(uid)
    local folder = workspace:FindFirstChild("AreaEggSlotsClient")
    local direct = folder and folder:FindFirstChild(tostring(uid))
    if direct and direct:IsA("Model") then return direct end
    local loose = workspace:FindFirstChild(tostring(uid))
    if loose and loose:IsA("Model") then return loose end
    return nil
end

local function mutationList(record, model)
    local raw = record and (record.Mutations or record.Mutation) or readAttribute(model, SCHEMA.MUTATIONS)
    local names, seen = {}, {}
    local function add(name)
        if type(name) ~= "string" then return end
        local clean = name:match("^%s*(.-)%s*$")
        if clean == "" or clean == "None" or clean == "Normal" then return end
        local key = clean:lower()
        if clean:lower() == "gold" then clean, key = "Golden", "golden" end
        if seen[key] then return end
        seen[key] = true
        names[#names + 1] = clean
    end
    if type(raw) == "table" then
        for key, value in pairs(raw) do
            if value == true and type(key) == "string" then add(key)
            elseif type(value) == "string" then add(value) end
        end
    elseif type(raw) == "string" then
        for token in raw:gmatch("[^,;|+]+") do add(token) end
    end
    table.sort(names)
    return names
end

local function cycleInfo()
    if not CAPS.cycle then return nil end
    local ok, info = pcall(function()
        local now = workspace:GetServerTimeNow()
        local running = MODULES.cycle.IsRunning and MODULES.cycle.IsRunning() or false
        local remaining
        if MODULES.cycle.SecondsUntilReset then
            remaining = MODULES.cycle.SecondsUntilReset(now)
        elseif MODULES.cycle.NextResetTime then
            remaining = MODULES.cycle.NextResetTime(now) - now
        end
        local resetAt = MODULES.cycle.NextResetTime and MODULES.cycle.NextResetTime(now) or nil
        return { running = running, remaining = remaining, resetAt = resetAt }
    end)
    return ok and info or nil
end

-- One scan => enriched entry list -------------------------------------------------
local function enrich(uid, record, model)
    local category = record and (record.AssetCategory or record.Category) or readAttribute(model, SCHEMA.CATEGORY)
    local directory = type(MODULES.assets) == "table" and MODULES.assets.Directory or nil
    local asset = (directory and category and directory[category]) or {}
    local rarity = asset.Rarity or {}
    local rarityName = rarity.DisplayName or rarity._id or "Unknown"
    local rarityRank = tonumber(rarity.Rank) or 0

    local rate = displayedRate(model)
    local estimated = false
    if not rate then
        -- Fall back to the asset's base income scaled the way the game does it.
        local base = asset.EarningRate
        local scale = validNumber(record and record.AssetScale) and record.AssetScale
            or readAttribute(model, SCHEMA.SCALE)
        local mutations = record and record.Mutations
        if validNumber(base) and validNumber(scale) and scale > 0 then
            local multiplier = 1
            if type(mutations) == "table" and next(mutations) and MODULES.mutations then
                local fn = MODULES.mutations.EarningsFor
                if type(fn) == "function" then
                    local ok, value = pcall(fn, mutations)
                    if ok and validNumber(value) then multiplier = value end
                end
            end
            local factor = scale > 5 and (scale / 5) ^ 1.2 * 19.637875755794113 or scale ^ 1.85
            rate = base * factor * multiplier
            estimated = true
        elseif validNumber(base) then
            rate = base
            estimated = true
        end
    end

    local weight
    if MODULES.records and type(MODULES.records.WeightKg) == "function" and record then
        local ok, value = pcall(MODULES.records.WeightKg, record)
        if ok and validNumber(value) then weight = value end
    end

    local scale = validNumber(record and record.AssetScale) and record.AssetScale
        or readAttribute(model, SCHEMA.SCALE)

    return {
        uid = tostring(uid),
        name = tostring(asset.DisplayName or category or (model and model.Name) or uid),
        category = category and tostring(category) or nil,
        rarity = tostring(rarityName),
        rank = rarityRank,
        rate = rate,
        estimated = estimated,
        scale = scale,
        weight = weight,
        area = record and record.AreaId and tostring(record.AreaId) or readAttribute(model, SCHEMA.AREA),
        nest = record and record.NestId,
        mutations = mutationList(record, model),
        icon = asset.Icon,
        model = model,
        isLocal = true,
    }
end

local SCAN_ROOTS = { "AreaEggSlotsClient", "EggSlots", "FieldEggs", "Eggs" }

local function scanByAttributes()
    local entries, seen = {}, {}
    for _, rootName in ipairs(SCAN_ROOTS) do
        local container = workspace:FindFirstChild(rootName)
        if container then
            for _, child in ipairs(container:GetChildren()) do
                if child:IsA("Model") then
                    local uid = readAttribute(child, SCHEMA.UID) or child.Name
                    uid = tostring(uid)
                    if not seen[uid] then
                        seen[uid] = true
                        entries[#entries + 1] = enrich(uid, nil, child)
                    end
                end
            end
        end
    end
    CAPS.attributeScan = #entries > 0
    return entries
end

local function scanOnce()
    local entries, seen = {}, {}

    if CAPS.moduleApi then
        local ok, snapshot = pcall(MODULES.eggState.ReadFieldEggs)
        if ok and type(snapshot) == "table" and type(snapshot.Records) == "table" then
            local states = MODULES.states
            for key, record in pairs(snapshot.Records) do
                if type(record) == "table" then
                    local usable = states == nil
                        or record.State == nil
                        or record.State == states.Slot
                        or record.State == states.Carried
                        or record.State == states.Dropped
                        or record.State == states.GuardCarried
                    local uid = record.Uid or key
                    if usable and uid ~= nil then
                        uid = tostring(uid)
                        if not seen[uid] then
                            seen[uid] = true
                            entries[#entries + 1] = enrich(uid, record, modelFor(uid))
                        end
                    end
                end
            end
        end
    end

    if #entries == 0 then
        for _, entry in ipairs(scanByAttributes()) do
            if not seen[entry.uid] then seen[entry.uid] = true; entries[#entries + 1] = entry end
        end
    end

    table.sort(entries, function(a, b)
        local ar, br = a.rate or -1, b.rate or -1
        if ar ~= br then return ar > br end
        if a.rank ~= b.rank then return a.rank > b.rank end
        return a.uid < b.uid
    end)
    return entries
end

--==============================================================================
-- NETWORK  (your backend only)
--==============================================================================
local BUSY = setmetatable({}, { __mode = "k" })
local MAIN_THREAD = {}

local function httpRequest(options)
    if type(request) == "function" then return request(options) end
    if type(http_request) == "function" then return http_request(options) end
    if type(syn) == "table" and type(syn.request) == "function" then return syn.request(options) end
    return nil, "no HTTP function"
end

-- Roblox runs each task.spawn on its own thread, so a single module-wide
-- "busy" flag lets the 0.25 s countdown loop starve the report/feed loops for
-- good (they see "busy" forever and never broadcast). The flag is therefore
-- per-coroutine: two calls on the same thread still cannot overlap.
local function api(method, pathAndQuery, body)
    if not CAPS.network then return nil, "HTTP unavailable" end
    local thread = coroutine.running() or MAIN_THREAD
    if BUSY[thread] then return nil, "busy" end
    BUSY[thread] = true
    local ok, response, transportError = pcall(httpRequest, {
        Url = CONFIG.ENDPOINT .. pathAndQuery,
        Method = method,
        Headers = { ["Content-Type"] = "application/json", ["X-Egg-Room"] = CONFIG.ROOM_KEY },
        Body = body and HttpService:JSONEncode(body) or nil,
        Timeout = 8,
    })
    BUSY[thread] = nil
    if not ok then return nil, tostring(response) end
    if type(response) ~= "table" then return nil, tostring(transportError or "request failed") end
    local code = tonumber(response.StatusCode or response.Status) or 0
    if code ~= 200 then return nil, "HTTP " .. code end
    local decoded = select(2, pcall(HttpService.JSONDecode, HttpService, response.Body or ""))
    if type(decoded) ~= "table" then return nil, "bad json" end
    return decoded
end

local reporterId
do
    local ok, saved = pcall(function()
        if type(readfile) == "function" then return readfile("m0x46_reporter.txt") end
    end)
    if ok and type(saved) == "string" and #saved >= 8 then
        reporterId = saved
    else
        reporterId = HttpService:GenerateGUID(false)
        pcall(function()
            if type(writefile) == "function" then writefile("m0x46_reporter.txt", reporterId) end
        end)
    end
end

local function broadcast(entries)
    if not CONFIG.BROADCAST then return nil, "broadcast off" end
    if not game.JobId or game.JobId == "" then return nil, "no server id" end
    local payload = {}
    for _, entry in ipairs(entries) do
        if entry.rate and entry.rate > 0 then
            payload[#payload + 1] = {
                uid = entry.uid,
                name = entry.name,
                category = entry.category,
                rarity = entry.rarity,
                rank = entry.rank,
                rate = entry.rate,
                scale = entry.scale,
                weight = entry.weight,
                mutations = table.concat(entry.mutations or {}, ", "),
                area = entry.area,
                estimated = entry.estimated == true,
                source = "field",
            }
        end
    end
    if #payload == 0 then return nil, "nothing to report" end
    return api("POST", "/v1/report", {
        placeId = game.PlaceId,
        jobId = game.JobId,
        reporterId = reporterId,
        ttl = CONFIG.SIGHTING_TTL * 1000,
        eggs = payload,
    })
end

local function fetchFeed(minRank, offset)
    -- all=1 -> every egg from every server (full leaderboard), not just the best
    -- egg per server. limit is the total card budget.
    return api("GET", string.format(
        "/v1/eggs?placeId=%d&localJob=%s&limit=%d&offset=%d&minRate=%d&minRank=%d&all=1",
        game.PlaceId, game.JobId or "", CONFIG.CARD_LIMIT, offset or 0,
        math.floor(CONFIG.MIN_RATE), minRank or 0
    ))
end

local function claimAndJoin(entry)
    if not CONFIG.AUTO_JOIN then return false, "AUTO_JOIN is off" end
    if not entry.jobId or entry.jobId == game.JobId then return false, "already here" end
    local claim, err = api("POST", "/v1/join", {
        placeId = entry.placeId, jobId = entry.jobId, uid = entry.uid, reporterId = reporterId,
    })
    if not claim then return false, err or "claim failed" end
    if claim.allowed ~= true then return false, "server refused (" .. tostring(claim.reason or "?") .. ")" end
    local ok, error_ = pcall(function()
        TeleportService:TeleportToPlaceInstance(entry.placeId, entry.jobId, player)
    end)
    if not ok then return false, tostring(error_) end
    return true, "teleporting…"
end

--==============================================================================
-- STATE
--==============================================================================
local STATE = {
    entries = {},
    feed = {},
    feedTotal = 0,
    status = "starting…",
    notice = nil,
    noticeUntil = 0,
    reportStatus = "connecting…",
    filterIndex = 1,
    minRank = CONFIG.MIN_RANK,
    minRate = CONFIG.MIN_RATE,
    tab = "local",
    scanAge = 0,
}

-- A short-lived message that outranks the per-scan status line, so clicking
-- JOIN / changing a setting is still readable one second later.
local function notify(message, seconds)
    STATE.notice = tostring(message)
    STATE.noticeUntil = os.clock() + (seconds or 4)
end

--==============================================================================
-- UI SHELL
--==============================================================================
local THEME = {
    bg = Color3.fromRGB(10, 7, 22),
    bgDeep = Color3.fromRGB(5, 3, 14),
    glass = Color3.fromRGB(27, 20, 48),
    glassHigh = Color3.fromRGB(46, 33, 80),
    accent = Color3.fromRGB(147, 92, 255),
    accentHot = Color3.fromRGB(213, 96, 255),
    cyan = Color3.fromRGB(56, 205, 255),
    text = Color3.fromRGB(245, 240, 255),
    muted = Color3.fromRGB(176, 162, 210),
    green = Color3.fromRGB(96, 235, 150),
    red = Color3.fromRGB(238, 96, 106),
}

local function make(class, props, parent)
    local object = Instance.new(class)
    for key, value in pairs(props or {}) do object[key] = value end
    object.Parent = parent
    return object
end

local function label(parent, text, position, size, color, textSize)
    return make("TextLabel", {
        Text = text, Position = position, Size = size, BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold, TextSize = textSize or 13,
        TextColor3 = color or THEME.text, TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, parent)
end

local oldGui = player:FindFirstChild("PlayerGui") and player.PlayerGui:FindFirstChild("M0x46Finder")
if oldGui then oldGui:Destroy() end

local gui = make("ScreenGui", {
    Name = "M0x46Finder",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    DisplayOrder = 1200,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
gui.Parent = player:WaitForChild("PlayerGui")

local panel = make("Frame", {
    Name = "Panel",
    Size = UDim2.fromOffset(404, 560),
    Position = UDim2.new(0.5, -202, 0.5, -280),
    BackgroundColor3 = THEME.bg,
    BackgroundTransparency = 0.05,
    BorderSizePixel = 0,
    Active = true,
    Visible = false,
}, gui)
make("UICorner", { CornerRadius = UDim.new(0, 12) }, panel)
local panelStroke = make("UIStroke", {
    Color = THEME.accent, Thickness = 1.5, Transparency = 0.22,
    ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
}, panel)
make("UIGradient", { Rotation = 55, Color = ColorSequence.new(THEME.accent, THEME.cyan) }, panelStroke)
make("UIGradient", {
    Rotation = 95, Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(150, 138, 190)),
}, panel)

-- starfield backdrop ---------------------------------------------------------
local starfield = make("Frame", {
    Name = "Starfield", BackgroundTransparency = 1, BorderSizePixel = 0,
    Size = UDim2.fromScale(1, 1), Active = false, ZIndex = 1,
}, panel)
local starTweens = {}
do
    local random = Random.new(4617)
    for i = 1, CONFIG.THEME_STARS do
        local dot = make("Frame", {
            Name = "Star" .. i, BorderSizePixel = 0, Active = false, ZIndex = 1,
            Position = UDim2.fromScale(random:NextNumber(0.03, 0.97), random:NextNumber(0.08, 0.96)),
            BackgroundColor3 = (i % 7 == 0) and THEME.cyan or (i % 3 == 0) and THEME.accentHot or Color3.fromRGB(232, 226, 255),
        }, starfield)
        local size = random:NextInteger(2, 3)
        dot.Size = UDim2.fromOffset(size, size)
        dot.BackgroundTransparency = random:NextNumber(0.3, 0.62)
        make("UICorner", { CornerRadius = UDim.new(1, 0) }, dot)
        local tween = TweenService:Create(dot, TweenInfo.new(random:NextNumber(1.4, 3.4), Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
            BackgroundTransparency = 0.88,
            Size = UDim2.fromOffset(size + 1, size + 1),
        })
        tween:Play()
        starTweens[#starTweens + 1] = tween
    end
end

-- header ---------------------------------------------------------------------
local header = make("Frame", {
    Name = "Header", Position = UDim2.fromOffset(1, 1), Size = UDim2.new(1, -2, 0, 46),
    BackgroundColor3 = THEME.bgDeep, BackgroundTransparency = 0.15, BorderSizePixel = 0, ZIndex = 4,
}, panel)
make("UICorner", { CornerRadius = UDim.new(0, 12) }, header)

local heading = label(panel, "M0x46 FINDER", UDim2.fromOffset(12, 6), UDim2.new(1, -110, 0, 24), THEME.text, 18)
heading.Font = Enum.Font.GothamBlack
heading.ZIndex = 5
local headingStroke = make("UIStroke", { Color = THEME.accent, Thickness = 1.2, Transparency = 0.4 }, heading)
make("UIGradient", {
    Rotation = 0,
    Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(196, 164, 255)),
}, heading)

local statusText = label(panel, "starting…", UDim2.fromOffset(12, 27), UDim2.new(1, -110, 0, 14), THEME.cyan, 11)
statusText.ZIndex = 5

local hairline = make("Frame", {
    Name = "Hairline", BorderSizePixel = 0, Active = false, BackgroundColor3 = THEME.accent,
    Position = UDim2.new(0, 12, 0, 46), Size = UDim2.new(1, -24, 0, 1), ZIndex = 5,
}, panel)
make("UIGradient", { Rotation = 0, Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.18, 0.25),
    NumberSequenceKeypoint.new(0.82, 0.25), NumberSequenceKeypoint.new(1, 1),
})}, hairline)

-- tabs -----------------------------------------------------------------------
local tabBar = make("Frame", {
    Name = "Tabs", Position = UDim2.fromOffset(10, 52), Size = UDim2.new(1, -20, 0, 30),
    BackgroundTransparency = 1, ZIndex = 4,
}, panel)
make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, tabBar)

local function styleButton(button, accent)
    make("UICorner", { CornerRadius = UDim.new(0, 8) }, button)
    button.BackgroundColor3 = accent and THEME.accent or THEME.glass
    button.BackgroundTransparency = 0.04
    button.TextColor3 = THEME.text
    button.Font = Enum.Font.GothamBold
    button.TextSize = 12
    button.BorderSizePixel = 0
    button.AutoButtonColor = false
    button.ZIndex = 5
    make("UIStroke", {
        Color = THEME.accent, Thickness = 1, Transparency = 0.3,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, button)
    return button
end

-- Named so the runtime harness / any automation can find them by name.
local localTab = styleButton(make("TextButton", { Name = "TabLocal", Text = "MY SERVER", Size = UDim2.fromOffset(120, 28), LayoutOrder = 1 }, tabBar), true)
local feedTab = styleButton(make("TextButton", { Name = "TabAll", Text = "ALL SERVERS", Size = UDim2.fromOffset(130, 28), LayoutOrder = 2 }, tabBar), false)

-- controls row ---------------------------------------------------------------
local filterButton = styleButton(make("TextButton", {
    Name = "RarityFilter", Text = "MIN RARITY: ANY",
    Position = UDim2.fromOffset(10, 88), Size = UDim2.new(0.52, -12, 0, 30),
}, panel), false)

local refreshButton = styleButton(make("TextButton", {
    Name = "Refresh", Text = "REFRESH",
    Position = UDim2.new(0.52, 2, 0, 88), Size = UDim2.new(0.28, -6, 0, 30),
}, panel), false)

local resetLabel = label(panel, "RESET --:--", UDim2.new(0.80, 2, 0, 95), UDim2.new(0.20, -12, 0, 18), THEME.muted, 11)

-- cards ----------------------------------------------------------------------
local list = make("ScrollingFrame", {
    Name = "List", Position = UDim2.fromOffset(10, 124), Size = UDim2.new(1, -20, 1, -196),
    BackgroundColor3 = THEME.panel or THEME.glass, BackgroundTransparency = 1, BorderSizePixel = 0,
    CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollBarThickness = 6, ScrollBarImageColor3 = THEME.accent, ScrollBarImageTransparency = 0.15,
    ZIndex = 4,
}, panel)
make("UIListLayout", { Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }, list)
make("UIPadding", { PaddingLeft = UDim.new(0, 2), PaddingRight = UDim.new(0, 2) }, list)

-- footer ---------------------------------------------------------------------
local broadcastButton = styleButton(make("TextButton", {
    Name = "Broadcast", Text = "BROADCAST: ON",
    Position = UDim2.new(0, 10, 1, -64), Size = UDim2.new(0.48, -13, 0, 30),
}, panel), false)

local settingsButton = styleButton(make("TextButton", {
    Name = "Settings", Text = "SETTINGS",
    Position = UDim2.new(0.52, 3, 1, -64), Size = UDim2.new(0.48, -13, 0, 30),
}, panel), false)

local noticeLabel = label(panel, "SIGHTINGS SHARED WITH YOUR OWN SERVER", UDim2.new(0, 12, 1, -30), UDim2.new(1, -24, 0, 18), THEME.muted, 10)
noticeLabel.TextXAlignment = Enum.TextXAlignment.Center
noticeLabel.TextScaled = true

--==============================================================================
-- SETTINGS OVERLAY
--==============================================================================
local overlay = make("Frame", {
    Name = "SettingsOverlay", Position = UDim2.fromScale(0, 0), Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = THEME.bg, BackgroundTransparency = 0.02, BorderSizePixel = 0,
    Visible = false, ZIndex = 30,
}, panel)
make("UICorner", { CornerRadius = UDim.new(0, 12) }, overlay)
make("UIStroke", { Color = THEME.accent, Thickness = 1.4, Transparency = 0.3 }, overlay)

local overlayTitle = label(overlay, "SETTINGS", UDim2.fromOffset(16, 14), UDim2.new(1, -80, 0, 30), THEME.text, 18)
overlayTitle.ZIndex = 31

local overlayClose = styleButton(make("TextButton", {
    Text = "X", Position = UDim2.new(1, -52, 0, 14), Size = UDim2.fromOffset(34, 30), ZIndex = 31,
}, overlay), false)
overlayClose.TextColor3 = THEME.red

local function makeToggle(text, position)
    local button = styleButton(make("TextButton", {
        Text = text, Position = position, Size = UDim2.new(1, -32, 0, 44), ZIndex = 31,
    }, overlay), false)
    return button
end

local broadcastToggle = makeToggle("BROADCAST: ON", UDim2.fromOffset(16, 60))
local autoJoinToggle = makeToggle("AUTO JOIN: OFF", UDim2.fromOffset(16, 112))

local rateBox = make("TextBox", {
    Name = "MinRate", Text = string.format("%gB", CONFIG.MIN_RATE / 1e9),
    PlaceholderText = "min income, e.g. 1.5B",
    Position = UDim2.fromOffset(16, 168), Size = UDim2.new(1, -32, 0, 40),
    BackgroundColor3 = THEME.glassHigh, TextColor3 = THEME.text, TextSize = 13,
    Font = Enum.Font.GothamBold, ClearTextOnFocus = false, BorderSizePixel = 0, ZIndex = 31,
}, overlay)
make("UICorner", { CornerRadius = UDim.new(0, 8) }, rateBox)
make("UIStroke", { Color = THEME.accent, Thickness = 1, Transparency = 0.45, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, rateBox)

local rateHint = label(overlay, "Minimum income per second (1B – 50B)", UDim2.fromOffset(18, 214), UDim2.new(1, -36, 0, 16), THEME.muted, 11)
rateHint.ZIndex = 31

local overlayInfo = label(overlay, "", UDim2.fromOffset(18, 250), UDim2.new(1, -36, 0, 90), THEME.muted, 11)
overlayInfo.TextWrapped = true
overlayInfo.TextYAlignment = Enum.TextYAlignment.Top
overlayInfo.ZIndex = 31
overlayInfo.Text = "endpoint: " .. CONFIG.ENDPOINT .. "\nreporter: " .. tostring(reporterId):sub(1, 18) ..
    "\ncards/feed limit: " .. CONFIG.CARD_LIMIT .. "\nsource: " .. (CAPS.moduleApi and "game module" or "attribute scan")

--==============================================================================
-- LAUNCHER + DRAG
--==============================================================================
local launcher = make("TextButton", {
    Name = "Launcher", Text = "M0x46",
    Size = UDim2.fromOffset(62, 62), Position = UDim2.new(0, 26, 0.5, -31),
    BackgroundColor3 = THEME.accent, TextColor3 = Color3.new(1, 1, 1),
    Font = Enum.Font.GothamBlack, TextSize = 12, BorderSizePixel = 0, AutoButtonColor = false,
    ZIndex = 20,
}, gui)
make("UICorner", { CornerRadius = UDim.new(1, 0) }, launcher)
make("UIStroke", { Color = THEME.accentHot, Thickness = 2, Transparency = 0.15, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, launcher)
make("UIGradient", { Rotation = 35, Color = ColorSequence.new(THEME.accent, THEME.cyan) }, launcher)

do
    local dragging, startMouse, startPosition = false, nil, nil
    local function beginDrag(handle, target)
        handle.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                dragging = true
                startMouse = input.Position
                startPosition = target.Position
            end
        end)
    end
    beginDrag(header, panel)
    beginDrag(launcher, launcher)
    UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - startMouse
            local target = panel.Visible and panel or launcher
            target.Position = UDim2.new(
                startPosition.X.Scale, startPosition.X.Offset + delta.X,
                startPosition.Y.Scale, startPosition.Y.Offset + delta.Y
            )
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
end

--==============================================================================
-- PROP ANIMATION (mutation / rarity gradients)
--==============================================================================
local MUTATION_PALETTE = {
    golden = { Color3.fromRGB(206, 164, 0), Color3.fromRGB(255, 191, 0), Color3.fromRGB(255, 230, 120), Color3.fromRGB(255, 191, 0) },
    silver = { Color3.fromRGB(120, 120, 120), Color3.fromRGB(200, 200, 200), Color3.fromRGB(255, 255, 255), Color3.fromRGB(200, 200, 200) },
    rainbow = { Color3.fromRGB(255, 0, 0), Color3.fromRGB(255, 200, 0), Color3.fromRGB(0, 255, 60), Color3.fromRGB(0, 190, 255), Color3.fromRGB(180, 0, 255) },
}

local liveGradients = {}

local function gradientSequence(palette, now)
    local phase = (now / 4) % 1
    local points = {}
    for i = 0, 12 do
        local sample = ((i / 12 - phase) % 1) * #palette
        local index = math.floor(sample)
        points[#points + 1] = ColorSequenceKeypoint.new(
            i / 12,
            palette[index + 1]:Lerp(palette[(index + 1) % #palette + 1], sample - index)
        )
    end
    return ColorSequence.new(points)
end

local function paintMutation(object, mutationName)
    local palette = MUTATION_PALETTE[tostring(mutationName):lower()]
    if not palette then return end
    if object:IsA("TextLabel") or object:IsA("TextButton") then
        object.TextColor3 = Color3.new(1, 1, 1)
    end
    local gradient = make("UIGradient", { Color = gradientSequence(palette, os.clock()), Rotation = 0 }, object)
    liveGradients[gradient] = palette
end

--==============================================================================
-- CARD RENDERER
--==============================================================================
local function clearList()
    for _, child in ipairs(list:GetChildren()) do
        if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then child:Destroy() end
    end
    table.clear(liveGradients)
end

local function raritySpec(entry)
    local byName = RARITY_BY_NAME[tostring(entry.rarity or ""):lower()]
    if byName then return byName end
    local byRank = RARITY_BY_RANK[tonumber(entry.rank) or 0]
    if byRank then return byRank end
    -- Unknown/renamed rarity: keep the egg visible (rank = the configured floor)
    -- instead of assigning rank 0, which the MIN_RANK filter would hide.
    -- NOTE: `tonumber(rank) or CONFIG.MIN_RANK` is not enough — a literal 0 is
    -- truthy in Lua, so an unknown egg would keep rank 0 and vanish from the panel.
    local rank = tonumber(entry.rank) or 0
    if rank <= 0 then rank = CONFIG.MIN_RANK end
    return { name = tostring(entry.rarity or "Unknown"), rank = rank, color = THEME.muted }
end

local function displayRank(entry)
    local rank = tonumber(entry.rank) or 0
    if rank > 0 then return rank end
    return raritySpec(entry).rank
end

local function weightText(entry)
    if validNumber(entry.weight) then return compact(entry.weight) .. " KG" end
    if validNumber(entry.scale) then return "×" .. compact(entry.scale) end
    return "—"
end

local function makeCard(entry, index)
    local spec = raritySpec(entry)
    local card = make("Frame", {
        Name = "Card" .. index, Size = UDim2.new(1, -4, 0, 96), BackgroundColor3 = THEME.glass,
        BackgroundTransparency = 0.1, BorderSizePixel = 0, LayoutOrder = index, ZIndex = 5,
    })
    make("UICorner", { CornerRadius = UDim.new(0, 8) }, card)
    make("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(168, 158, 200)) }, card)
    make("UIStroke", { Color = Color3.fromRGB(110, 80, 185), Transparency = 0.3, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, card)

    -- rank + name
    local rankLabel = label(card, "#" .. index, UDim2.fromOffset(10, 6), UDim2.fromOffset(34, 24), THEME.muted, 15)
    rankLabel.Font = Enum.Font.GothamBlack

    local nameLabel = label(card, tostring(entry.name), UDim2.fromOffset(48, 5), UDim2.new(1, -150, 0, 26), spec.color, 17)
    nameLabel.Font = Enum.Font.GothamBlack
    make("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = 1, Transparency = 0.5 }, nameLabel)

    -- rarity chip
    local chip = make("TextLabel", {
        Text = tostring(entry.rarity):upper(), Position = UDim2.fromOffset(10, 34), Size = UDim2.fromOffset(86, 18),
        BackgroundColor3 = spec.color, BackgroundTransparency = 0.82, BorderSizePixel = 0,
        Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = spec.color, ZIndex = 6,
    }, card)
    make("UICorner", { CornerRadius = UDim.new(0, 4) }, chip)
    make("UIStroke", { Color = spec.color, Thickness = 1, Transparency = 0.55 }, chip)

    -- income / weight
    local income = label(card, money(entry.rate), UDim2.fromOffset(102, 34), UDim2.fromOffset(120, 20), THEME.green, 15)
    income.Font = Enum.Font.GothamBlack
    local weight = label(card, weightText(entry), UDim2.fromOffset(224, 34), UDim2.new(1, -320, 0, 20), THEME.muted, 12)
    weight.TextXAlignment = Enum.TextXAlignment.Right

    -- mutations
    local mutations = entry.mutations or {}
    local strip = make("Frame", {
        Name = "Mutations", Position = UDim2.fromOffset(10, 58), Size = UDim2.new(1, -110, 0, 20), BackgroundTransparency = 1, ZIndex = 6,
    }, card)
    make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, strip)
    if #mutations == 0 then
        local none = label(strip, "no mutation", UDim2.new(), UDim2.fromOffset(90, 18), THEME.muted, 10)
        none.Font = Enum.Font.Gotham
        none.LayoutOrder = 1
    else
        for index_, mutation in ipairs(mutations) do
            local word = label(strip, tostring(mutation), UDim2.new(), UDim2.fromOffset(#mutation * 8 + 10, 18), THEME.text, 11)
            word.Font = Enum.Font.GothamBlack
            word.LayoutOrder = index_
            paintMutation(word, mutation)
        end
    end

    -- area line
    if entry.area then
        local areaLabel = label(card, "area " .. tostring(entry.area), UDim2.fromOffset(10, 78), UDim2.new(1, -120, 0, 14), THEME.muted, 10)
        areaLabel.Font = Enum.Font.Gotham
    end

    -- join / status button
    local joinable = entry.jobId ~= nil and entry.jobId ~= game.JobId
    local text = joinable and "JOIN" or "HERE"
    local button = styleButton(make("TextButton", {
        Name = "JoinStatus", Text = text, Position = UDim2.new(1, -96, 0, 30), Size = UDim2.fromOffset(86, 30), ZIndex = 7,
    }, card), joinable)
    button.BackgroundColor3 = joinable and Color3.fromRGB(40, 160, 85) or Color3.fromRGB(86, 90, 100)
    button.MouseButton1Click:Connect(function()
        if not joinable then return end
        notify("claiming " .. tostring(entry.name) .. "…", 8)
        task.spawn(function()
            local ok, message = claimAndJoin(entry)
            notify((ok and "auto join: " or "join blocked: ") .. tostring(message), 8)
            if ok then STATE.reportStatus = "teleporting" end
        end)
    end)

    -- rarity gradient on the name
    if MUTATION_PALETTE.silver then
        local gradient = make("UIGradient", { Enabled = false }, nameLabel)
        if spec.rank >= 8 then
            local palette = { spec.color, THEME.text, spec.color }
            gradient.Enabled = true
            gradient.Color = gradientSequence(palette, os.clock())
            liveGradients[gradient] = palette
        end
    end

    return card
end

local function render()
    clearList()
    local source = STATE.tab == "local" and STATE.entries or STATE.feed
    local count = math.min(#source, CONFIG.CARD_LIMIT)
    if count == 0 then
        local empty = make("TextLabel", {
            Text = STATE.tab == "local"
                and "No matching eggs in this server.\nRun the scan again, or check SCHEMA if the game renamed things."
                or "No reports yet.\nServers running your build will appear here.",
            Size = UDim2.new(1, -8, 0, 68), BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 11,
            TextColor3 = THEME.muted, TextWrapped = true, LayoutOrder = 1, ZIndex = 5,
        }, list)
        return
    end
    for index = 1, count do
        local card = makeCard(source[index], index)
        card.Parent = list
    end
end

--==============================================================================
-- UI BEHAVIOUR
--==============================================================================
local function paintTabs()
    localTab.BackgroundColor3 = STATE.tab == "local" and THEME.accent or THEME.glass
    feedTab.BackgroundColor3 = STATE.tab == "all" and THEME.accent or THEME.glass
end

local function setTab(key)
    STATE.tab = key
    paintTabs()
    render()
    if key == "all" then
        task.spawn(function()
            local data, err = fetchFeed(STATE.minRank, 0)
            if data and type(data.items) == "table" then
                STATE.feed = data.items
                STATE.feedTotal = data.total or #data.items
                STATE.status = string.format("%d servers reporting", STATE.feedTotal)
            else
                STATE.status = "feed: " .. tostring(err)
            end
            if STATE.tab == "all" then render() end
        end)
    end
end

localTab.MouseButton1Click:Connect(function() setTab("local") end)
feedTab.MouseButton1Click:Connect(function() setTab("all") end)

filterButton.MouseButton1Click:Connect(function()
    STATE.filterIndex = STATE.filterIndex % #FILTERS + 1
    local spec = FILTERS[STATE.filterIndex]
    STATE.minRank = spec.rank
    filterButton.Text = "MIN RARITY: " .. spec.name:upper()
    local rarity = RARITY_BY_NAME[spec.name:lower()]
    filterButton.TextColor3 = rarity and rarity.color or THEME.text
    render()
end)

refreshButton.MouseButton1Click:Connect(function()
    STATE.status = "scanning…"
    STATE.entries = scanOnce()
    STATE.status = string.format("%d eggs in this server", #STATE.entries)
    if STATE.tab == "local" then render() end
end)

local function paintBroadcast()
    broadcastButton.Text = CONFIG.BROADCAST and "BROADCAST: ON" or "BROADCAST: OFF"
    broadcastButton.TextColor3 = CONFIG.BROADCAST and THEME.text or THEME.red
end
broadcastButton.MouseButton1Click:Connect(function()
    CONFIG.BROADCAST = not CONFIG.BROADCAST
    paintBroadcast()
end)
paintBroadcast()

settingsButton.MouseButton1Click:Connect(function()
    overlay.Visible = not overlay.Visible
end)
overlayClose.MouseButton1Click:Connect(function() overlay.Visible = false end)

local function paintToggle(button, text, on)
    button.Text = text
    button.BackgroundColor3 = on and Color3.fromRGB(40, 135, 75) or Color3.fromRGB(155, 48, 52)
end

paintToggle(broadcastToggle, "BROADCAST: ON", CONFIG.BROADCAST)
paintToggle(autoJoinToggle, "AUTO JOIN: OFF", CONFIG.AUTO_JOIN)

broadcastToggle.MouseButton1Click:Connect(function()
    CONFIG.BROADCAST = not CONFIG.BROADCAST
    paintToggle(broadcastToggle, CONFIG.BROADCAST and "BROADCAST: ON" or "BROADCAST: OFF", CONFIG.BROADCAST)
    paintBroadcast()
    notify(CONFIG.BROADCAST and "broadcasting enabled" or "broadcasting paused")
end)

autoJoinToggle.MouseButton1Click:Connect(function()
    CONFIG.AUTO_JOIN = not CONFIG.AUTO_JOIN
    paintToggle(autoJoinToggle, CONFIG.AUTO_JOIN and "AUTO JOIN: ON" or "AUTO JOIN: OFF", CONFIG.AUTO_JOIN)
    notify(CONFIG.AUTO_JOIN and "auto join enabled — JOIN buttons will teleport" or "auto join disabled")
end)

rateBox.FocusLost:Connect(function()
    local amount = tonumber((tostring(rateBox.Text):gsub("[^%d%.]", "")))
    if amount and amount >= 0.1 and amount <= 50 then
        CONFIG.MIN_RATE = amount * 1e9
        STATE.minRate = CONFIG.MIN_RATE
        rateBox.Text = string.format("%gB", amount)
        notify("minimum income set to " .. rateBox.Text)
        render()
    else
        rateBox.Text = string.format("%gB", CONFIG.MIN_RATE / 1e9)
        notify("enter a value from 0.1B to 50B")
    end
end)

local function togglePanel()
    panel.Visible = not panel.Visible
    if panel.Visible then render() end
end
launcher.MouseButton1Click:Connect(togglePanel)
UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == CONFIG.HOTKEY then togglePanel() end
end)

--==============================================================================
-- LOOPS
--==============================================================================
task.spawn(function()
    while gui.Parent do
        local ok, entries = pcall(scanOnce)
        if ok and type(entries) == "table" then
            local filtered = {}
            for _, entry in ipairs(entries) do
                if (entry.rate or 0) >= STATE.minRate and displayRank(entry) >= STATE.minRank then
                    filtered[#filtered + 1] = entry
                end
            end
            STATE.entries = filtered
            STATE.scanAge = os.clock()
            STATE.status = string.format("%d eggs • %s", #filtered, CAPS.moduleApi and "module api" or "attribute scan")
            pcall(function()
                gui:SetAttribute("M0x46Count", #filtered)
                gui:SetAttribute("M0x46Raw", #entries)
                gui:SetAttribute("M0x46Status", STATE.status)
                gui:SetAttribute("M0x46Source", CAPS.moduleApi and "module" or "attributes")
            end)
            if panel.Visible and STATE.tab == "local" then render() end
        else
            STATE.status = "scan error: " .. tostring(entries)
        end
        task.wait(CONFIG.SCAN_EVERY)
    end
end)

task.spawn(function()
    while gui.Parent do
        task.wait(CONFIG.REPORT_EVERY)
        if CONFIG.BROADCAST and #STATE.entries > 0 then
            local data, err = broadcast(STATE.entries)
            if data then
                STATE.reportStatus = string.format("broadcast %d eggs", data.accepted or 0)
                pcall(function() gui:SetAttribute("M0x46Reported", tonumber(data.accepted) or 0) end)
            elseif err and err ~= "busy" then
                STATE.reportStatus = "broadcast: " .. tostring(err)
            end
        end
    end
end)

task.spawn(function()
    while gui.Parent do
        task.wait(CONFIG.FEED_EVERY)
        if STATE.tab == "all" then
            local data, err = fetchFeed(STATE.minRank, 0)
            if data and type(data.items) == "table" then
                STATE.feed = data.items
                STATE.feedTotal = data.total or #data.items
                if panel.Visible then render() end
            elseif err and err ~= "busy" then
                STATE.status = "feed: " .. tostring(err)
            end
        end
    end
end)

task.spawn(function()
    while gui.Parent do
        local line = STATE.status
        if STATE.notice and os.clock() < STATE.noticeUntil then line = STATE.notice end
        statusText.Text = STATE.reportStatus .. "  ·  " .. line
        local cycle = cycleInfo()
        if cycle and validNumber(cycle.remaining) then
            local seconds = math.max(0, math.ceil(cycle.remaining))
            resetLabel.Text = cycle.running == false and "RESET PAUSED"
                or string.format("RESET %02d:%02d", math.floor(seconds / 60), seconds % 60)
            resetLabel.TextColor3 = seconds <= 60 and THEME.red or seconds <= 150 and Color3.fromRGB(255, 215, 65) or THEME.muted
        else
            resetLabel.Text = "RESET --:--"
            resetLabel.TextColor3 = THEME.muted
        end
        for gradient, palette in pairs(liveGradients) do
            if gradient.Parent then
                gradient.Color = gradientSequence(palette, os.clock())
            else
                liveGradients[gradient] = nil
            end
        end
        task.wait(0.25)
    end
end)

gui.Destroying:Connect(function()
    for _, tween in ipairs(starTweens) do pcall(function() tween:Cancel() end) end
    table.clear(liveGradients)
end)

render()
paintTabs()
log("M0x46 Finder loaded — hotkey", CONFIG.HOTKEY.Name, "| source:", CAPS.moduleApi and "module" or "attributes")
