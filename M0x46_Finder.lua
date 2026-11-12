--[[
================================================================================
  M0x46 FINDER  ·  v2.4  ·  owner build
================================================================================
  M0x46-owned mobile client with an authorised NYX shared-feed adapter.
  It has no third-party gate, validation worker, remote-code loader, or
  automatic teleport machinery.

  Run it by pasting this complete, reviewed file into Delta and pressing Execute.
  This client intentionally contains no automatic remote-code loader: host a copy
  only for distribution, then review/download the exact source you choose to run.

  What it does
    • scans eggs physically spawned in your current server (game module, else attrs)
    • MY SERVER  : those local scans, filtered live
    • ALL SERVERS: genuine NYX reports first; your X-Egg-Room backend is an
                   optional fallback when NYX is off, empty, or unavailable
    • JOIN       : claim against the source that served the row, then a real
                   TeleportService join only with a valid foreign JobId

  Guarantees
    • no key system, no validation worker, no obfuscated remote execution
    • NYX config JSON is fetched as data only — nothing remote is executed
    • never fabricates eggs, servers or income: an unavailable feed says so
    • read-only: it does not move your character unless you explicitly confirm JOIN

  Data flow (single source of truth)
      scanOnce()    -> STATE.raw    (deduped local observations)
      ingestFeed()  -> STATE.feed   (NYX, then own fallback; provenance retained)
                          │
                          └─ visibleList() applies the income/rarity floor on
                             every render; NYX is also re-queried when that
                             server-side floor changes.

  Own-backend contract (eggfinder-server/server.js in this workspace)
    POST /v1/report  {placeId, jobId, reporterId, ttl, eggs[]}   header X-Egg-Room
    GET  /v1/eggs    ?placeId&localJob&excludeJob&limit&offset&minRate&minRank&all=1
    POST /v1/join    {placeId, jobId, uid, reporterId}
    Custom headers for your own server: X-Egg-Room  (also sends X-M0x46-Room)

  NYX is configured from CONFIG.NYX.CONFIG_URL at runtime; its X-NYX-Room
  authentication is retained and no endpoint/key is committed below.

  Game bridge
    Primary  : ReplicatedStorage.Client.EggState.ReadFieldEggs() + Data.Assets
    Fallback : attribute scan of workspace.AreaEggSlotsClient (see SCHEMA)
================================================================================
]]

--==============================================================================
-- CONFIG  (edit this block only)
--==============================================================================
local CONFIG = {
    -- Your established X-Egg-Room backend remains the optional fallback.
    -- NYX is tried first; its separate credential is NEVER stored in this file.
    ENDPOINT = "https://m0x46-iqjlgk34.back4.app", -- own backend, no trailing slash
    ROOM_KEY = tostring((type(getgenv) == "function" and getgenv() or _G).M0x46_ROOM_KEY or ""), -- set this locally before running

    HOTKEY = Enum.KeyCode.RightControl,

    -- loop cadence (seconds)
    SCAN_EVERY = 1,                       -- field scan while the panel is open
    HIDDEN_SCAN_EVERY = 5,                -- field scan while minimised (saves FPS)
    REPORT_EVERY = 5,                     -- broadcast to your backend
    FEED_EVERY = 6,                       -- ALL SERVERS refresh
    UI_TICK = 0.5,                        -- one timer loop drives everything

    SIGHTING_TTL = 300,                   -- seconds a sighting stays live

    -- filters: 1e9 = 1B/s, MIN_RANK 5 = Legendary and up (6 = Mythic and up)
    MIN_RATE = 1e9,                       -- 1B/s default, as requested
    MIN_RANK = 0,                         -- 0 = show every rarity (button cycles up)

    CARD_LIMIT = 12,                      -- max rows drawn in MY SERVER
    FEED_LIMIT = 40,                      -- max rows fetched from the backend

    BROADCAST = true,                     -- upload sightings to your backend
    AUTO_JOIN = false,                    -- OFF by default; only teleports after a claim allows it
    AUTO_FORCE = false,                   -- OFF by default; explicit arming is required in the UI
    REMOTE_ONLY = true,                   -- ALL SERVERS hides your own server
    FEED_PAGES = 3,                       -- pages x FEED_LIMIT rows per own-backend refresh

    -- NYX shared feed (cross-server network, used with the owner's permission).
    -- No NYX endpoint or room key is stored here: both are read as runtime data
    -- from NYX's public config. Leave local overrides empty for a public repo.
    NYX = {
        ENABLED = true,
        CONFIG_URL = "https://raw.githubusercontent.com/syss1211/Tenshi-script/main/NYX-Finder-Config.json",
        ENDPOINT = "",          -- "" = take it from CONFIG_URL
        ROOM_KEY = "",          -- "" = take it from CONFIG_URL (never commit one)
        TIER = "public",
        PAGES = 2,              -- normal NYX page budget
        MAX_PAGES = 5,          -- bounded extra pages when early pages are only unavailable
        EXPAND_UNAVAILABLE = true,
        FALLBACK = true,        -- fall back to your own backend when NYX is down/empty
    },
    THEME_STARS = 16,                     -- backdrop dots (0 disables)
}

--==============================================================================
-- RARITY TABLE
--==============================================================================
local RARITIES = {
    { name = "Common",    rank = 1,  color = Color3.fromRGB(214, 220, 232) },
    { name = "Uncommon",  rank = 2,  color = Color3.fromRGB(104, 222, 138) },
    { name = "Rare",      rank = 3,  color = Color3.fromRGB(80, 168, 255) },
    { name = "Epic",      rank = 4,  color = Color3.fromRGB(196, 118, 255) },
    { name = "Legendary", rank = 5,  color = Color3.fromRGB(255, 160, 60) },
    { name = "Mythic",    rank = 6,  color = Color3.fromRGB(255, 86, 108) },
    { name = "Cosmic",    rank = 7,  color = Color3.fromRGB(168, 96, 255) },
    { name = "Secret",    rank = 8,  color = Color3.fromRGB(255, 255, 255) },
    { name = "Eternal",   rank = 9,  color = Color3.fromRGB(226, 210, 246) },
    { name = "Divine",    rank = 10, color = Color3.fromRGB(255, 210, 70) },
}
local RARITY_BY_NAME, RARITY_BY_RANK = {}, {}
for _, spec in ipairs(RARITIES) do
    RARITY_BY_NAME[spec.name:lower()] = spec
    RARITY_BY_RANK[spec.rank] = spec
end

-- minimum-rarity cycle for the filter button (index 1 = Any)
local FILTERS = { { name = "Any", rank = 0 } }
for _, spec in ipairs(RARITIES) do FILTERS[#FILTERS + 1] = { name = spec.name, rank = spec.rank } end

-- attribute names used by the fallback scanner
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
local playerGui = player:WaitForChild("PlayerGui")

local function log(...) warn("[M0x46]", ...) end

local function validNumber(value)
    return type(value) == "number" and value == value and value >= 0 and value < math.huge
end

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
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

local function moneyFilter(value)
    if value >= 1e9 then return string.format("%gB", value / 1e9) end
    if value >= 1e6 then return string.format("%gM", value / 1e6) end
    if value <= 0 then return "off" end
    return tostring(math.floor(value))
end

local function shortId(jobId)
    if type(jobId) ~= "string" or jobId == "" then return "?" end
    if #jobId <= 10 then return jobId end
    return jobId:sub(1, 8)
end

local function requirePath(root, dotted)
    local node = root
    for part in tostring(dotted):gmatch("[^%.]+") do
        node = node and node:FindFirstChild(part)
        if not node then return nil end
    end
    if not node:IsA("ModuleScript") then return nil end
    local ok, result = pcall(require, node)
    return ok and result or nil
end

local function readAttribute(object, names)
    if not object then return nil end
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
    cycle = requirePath(ReplicatedStorage, "Shared.Util.AreaEggCycle"),
    states = nil,
}
do
    local types = requirePath(ReplicatedStorage, "Shared.Types.AreaEggs")
    if type(types) == "table" and type(types.States) == "table" then MODULES.states = types.States end
end

local CAPS = {
    moduleApi = type(MODULES.eggState) == "table" and type(MODULES.eggState.ReadFieldEggs) == "function",
    cycle = type(MODULES.cycle) == "table",
    attributeScan = false,
    network = type(request) == "function" or type(http_request) == "function"
        or (type(syn) == "table" and type(syn.request) == "function"),
}

local INCOME_UNITS = { [""] = 1, k = 1e3, m = 1e6, b = 1e9, t = 1e12, qa = 1e15, q = 1e15, qi = 1e18 }

-- Reads the billboard income the game itself displays on the egg model.
local function displayedRate(model)
    if not model then return nil end
    local best
    local ok, descendants = pcall(function() return model:GetDescendants() end)
    if not ok or type(descendants) ~= "table" then return nil end
    for _, object in ipairs(descendants) do
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
        if key == "gold" then clean, key = "Golden", "golden" end
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
        return { running = running, remaining = remaining }
    end)
    return ok and info or nil
end

-- one record => one normalized entry -----------------------------------------
local function enrich(uid, record, model)
    local category = record and (record.AssetCategory or record.Category) or readAttribute(model, SCHEMA.CATEGORY)
    local directory = type(MODULES.assets) == "table" and MODULES.assets.Directory or nil
    local asset = (directory and category and directory[category]) or {}
    local rarity = type(asset.Rarity) == "table" and asset.Rarity or {}
    local rarityLabel = rarity.DisplayName or rarity._id or "Unknown"
    local rarityRank = tonumber(rarity.Rank) or 0

    local scale = validNumber(record and record.AssetScale) and record.AssetScale
        or readAttribute(model, SCHEMA.SCALE)

    local rate = displayedRate(model)
    local estimated = false
    if not rate then
        local base = asset.EarningRate
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

    return {
        uid = tostring(uid),
        name = tostring(asset.DisplayName or category or (model and model.Name) or uid),
        category = category and tostring(category) or nil,
        rarity = tostring(rarityLabel),
        rank = rarityRank,
        rate = rate,
        estimated = estimated,
        scale = scale,
        weight = weight,
        area = (record and record.AreaId and tostring(record.AreaId)) or readAttribute(model, SCHEMA.AREA),
        mutations = mutationList(record, model),
        jobId = game.JobId,
        placeId = game.PlaceId,
        isLocal = true,
        source = "scan",
    }
end

local SCAN_ROOTS = { "AreaEggSlotsClient", "EggSlots", "FieldEggs", "Eggs" }

local function scanByAttributes()
    local entries = {}
    for _, rootName in ipairs(SCAN_ROOTS) do
        local container = workspace:FindFirstChild(rootName)
        if container then
            for _, child in ipairs(container:GetChildren()) do
                if child:IsA("Model") then
                    local uid = tostring(readAttribute(child, SCHEMA.UID) or child.Name)
                    entries[#entries + 1] = enrich(uid, nil, child)
                end
            end
        end
    end
    CAPS.attributeScan = #entries > 0
    return entries
end

-- Dedupe helper used by both scan paths: one row per uid, highest income wins.
local function dedupe(entries)
    local byKey, out = {}, {}
    for _, entry in ipairs(entries) do
        local key = tostring(entry.uid) .. "|" .. tostring(entry.jobId or "")
        local existing = byKey[key]
        if not existing then
            byKey[key] = entry
        elseif (entry.rate or -1) > (existing.rate or -1) then
            byKey[key] = entry
        end
    end
    for _, entry in pairs(byKey) do out[#out + 1] = entry end
    table.sort(out, function(a, b)
        local ar, br = a.rate or -1, b.rate or -1
        if ar ~= br then return ar > br end
        if (a.rank or 0) ~= (b.rank or 0) then return (a.rank or 0) > (b.rank or 0) end
        return tostring(a.uid) < tostring(b.uid)
    end)
    return out
end

local function scanOnce()
    local entries = {}
    if CAPS.moduleApi then
        local ok, snapshot = pcall(MODULES.eggState.ReadFieldEggs)
        if ok and type(snapshot) == "table" and type(snapshot.Records) == "table" then
            local states = MODULES.states
            for key, record in pairs(snapshot.Records) do
                if type(record) == "table" then
                    local usable = states == nil or record.State == nil
                        or record.State == states.Slot
                        or record.State == states.Carried
                        or record.State == states.Dropped
                        or record.State == states.GuardCarried
                    local uid = record.Uid or key
                    if usable and uid ~= nil then
                        entries[#entries + 1] = enrich(tostring(uid), record, modelFor(uid))
                    end
                end
            end
        end
    end
    if #entries == 0 then
        for _, entry in ipairs(scanByAttributes()) do entries[#entries + 1] = entry end
    end
    return dedupe(entries)
end

--==============================================================================
-- NETWORK  (your backend only)
--==============================================================================
local BUSY = setmetatable({}, { __mode = "k" })
local MAIN_THREAD = {}

-- Transport diagnostics. Declared up here because api()/describeError() run before
-- STATE exists (STATE is built further down, after the data layer).
local DIAG = { lastUrl = nil, lastAuth = nil, problem = nil, probed = false }

local function httpRequest(options)
    if type(request) == "function" then return request(options) end
    if type(http_request) == "function" then return http_request(options) end
    if type(syn) == "table" and type(syn.request) == "function" then return syn.request(options) end
    return nil, "no HTTP function"
end

local function rawEndpoint()
    -- tolerate a pasted "..." / '...' and a trailing /v1 someone copied from a route
    local endpoint = tostring(CONFIG.ENDPOINT or ""):gsub('^%s+', ""):gsub("%s+$", "")
    endpoint = endpoint:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
    endpoint = endpoint:gsub("/+$", "")
    endpoint = endpoint:gsub("/v1$", "")
    return endpoint
end

-- Human-readable reason for every failure mode, so the UI can say what broke
-- instead of showing "HTTP 0".
local function describeError(err)
    local text = tostring(err or "unknown error")
    if text == "busy" then return "busy" end
    if text == "HTTP unavailable" then return "this executor has no HTTP function" end
    -- NYX errors must never be described using the own backend URL/key below.
    if text:sub(1, 3) == "NYX" then
        if text:find("HTTP 0", 1, true) or text:find("unreachable", 1, true) then
            return "NYX config/feed unreachable"
        end
        return text
    end
    if text:find("401", 1, true) then
        local key = tostring(CONFIG.ROOM_KEY or "")
        if key == "" or key == "changeme" then
            return "ROOM_KEY is still the default ('" .. key .. "') — set it to the exact value the server runs with"
        end
        local hint = ""
        if key:find('"') or key:find("'") then
            hint = " — the quotes are part of the key here: write ROOM_KEY = \"abc\", not ROOM_KEY = \"\\\"abc\\\"\""
        elseif key:find("^#") then
            hint = " — the key still starts with '#' (that is the .env comment marker, drop it)"
        elseif key:find("%s") then
            hint = " — the key contains a space; the server compares the exact string"
        elseif key:sub(1, 7) == "ROOM_KEY" or key:find("=") then
            hint = " — it looks like you pasted 'ROOM_KEY=...' or a whole line; keep just the value"
        end
        return "room key rejected (401). This script sends ROOM_KEY as " .. DIAG.lastAuth
            .. hint .. ". The header itself is fine — the server's ROOM_KEY is a different string. "
            .. "Compare them exactly, then tap REFRESH. (The key is never displayed.)"
    end
    if text:find("403", 1, true) then return "backend refused the request (403)" end
    if text:find("404", 1, true) then
        if DIAG.problem then return DIAG.problem end
        return "404 at " .. tostring(DIAG.lastUrl or rawEndpoint())
            .. " — ENDPOINT must be the host root, and the app must be deployed at it"
    end
    if text:find("429", 1, true) then return "rate limited by your backend (429)" end
    if text:find("HTTP 5", 1, true) then return "backend error (" .. text .. ")" end
    if text:find("HTTP 0", 1, true) or text:find("request failed", 1, true) then
        return "backend unreachable — the game cannot reach " .. rawEndpoint()
    end
    return text
end

local function api(method, pathAndQuery, body)
    if not CAPS.network then return nil, "HTTP unavailable" end
    local thread = coroutine.running() or MAIN_THREAD
    if BUSY[thread] then return nil, "busy" end
    BUSY[thread] = true
    local url = rawEndpoint() .. pathAndQuery
    DIAG.lastUrl = url             -- shown in diagnostics, never contains the key
    -- Diagnostics expose configuration state only, never a character (or
    -- fragment) of either room key.
    DIAG.lastAuth = (CONFIG.ROOM_KEY == nil or CONFIG.ROOM_KEY == "") and "empty"
        or ("configured (" .. #tostring(CONFIG.ROOM_KEY) .. " chars)")
    local ok, response, transportError = pcall(httpRequest, {
        Url = url,
        Method = method,
        Headers = {
            ["Content-Type"] = "application/json",
            ["X-Egg-Room"] = CONFIG.ROOM_KEY,     -- the header the backend checks
            ["X-M0x46-Room"] = CONFIG.ROOM_KEY,   -- kept for older builds
        },
        Body = body and HttpService:JSONEncode(body) or nil,
        Timeout = 8,
    })
    BUSY[thread] = nil
    if not ok then return nil, tostring(response) end
    if type(response) ~= "table" then return nil, tostring(transportError or "request failed") end
    local code = tonumber(response.StatusCode or response.Status) or 0
    if code < 200 or code >= 300 then
        -- Auth failures never surface an upstream body: proxies occasionally
        -- reflect request headers. Other statuses retain a short route hint.
        local snippet = (code == 401 or code == 403) and "(auth body redacted)"
            or tostring(response.Body or ""):sub(1, 140):gsub("%s+", " ")
        if snippet == "" then snippet = "(empty body)" end
        return nil, "HTTP " .. code .. " · " .. snippet
    end
    local okDecode, decoded = pcall(HttpService.JSONDecode, HttpService, response.Body or "")
    if not okDecode or type(decoded) ~= "table" then return nil, "bad json from backend" end
    return decoded
end

local STATE = {
    tab = "all",        -- LIVE FEED is the first screen; MY SERVER remains one tap away
    view = "logs",      -- sidebar: logs | history | users
    raw = {},            -- unfiltered field eggs from the last scan
    rawAt = 0,
    scanned = 0,         -- how many records the last scan produced
    feed = {},           -- unfiltered backend eggs
    feedMatched = 0,     -- backend eggs after filters (for messages)
    feedTotal = 0,
    feedAt = 0,
    feedBusy = false,
    remoteServers = 0,   -- distinct REMOTE jobIds in the last feed
    feedSource = nil,    -- "nyx" | "own" | nil
    feedErrors = {},     -- per-source failure text for the empty state
    feedTotalAll = 0,    -- backend total before hiding your own server
    feedError = nil,     -- nil = never fetched, else friendly reason
    feedLoaded = false,
    feedPages = 0,
    feedExpired = 0,
    statusCounts = { joinable = 0, taken = 0, full = 0, unknown = 0, expired = 0 },
    history = {},
    autoSeen = {},
    networkOnline = false,
    minRate = CONFIG.MIN_RATE,
    minRank = CONFIG.MIN_RANK,
    filterIndex = 1,
    status = "starting…",
    reportStatus = "offline",
    notice = nil,
    noticeUntil = 0,
    dirty = true,
}

for index, spec in ipairs(FILTERS) do
    if spec.rank == STATE.minRank then STATE.filterIndex = index end
end

local function notify(message, seconds)
    STATE.notice = tostring(message)
    STATE.noticeUntil = os.clock() + (seconds or 4)
end

local function raritySpec(entry)
    local byName = RARITY_BY_NAME[tostring((entry and entry.rarity) or ""):lower()]
    if byName then return byName end
    local rank = tonumber(entry and entry.rank) or 0
    if RARITY_BY_RANK[rank] then return RARITY_BY_RANK[rank] end
    return { name = tostring((entry and entry.rarity) or "Unknown"), rank = rank, color = Color3.fromRGB(176, 162, 210) }
end

local function displayRank(entry)
    local rank = tonumber(entry.rank) or 0
    if rank > 0 then return rank end
    return raritySpec(entry).rank
end

local function rarityName(rank)
    local spec = RARITY_BY_RANK[rank]
    return spec and spec.name or "Any"
end

-- The single filter used by MY SERVER, ALL SERVERS, the scan loop and REFRESH.
-- rule: an egg with no measurable income cannot satisfy an income floor.
local function passesFilter(entry)
    local rate = tonumber(entry.rate)
    if not rate or not validNumber(rate) or rate <= 0 then
        return STATE.minRate <= 0
    end
    if rate < STATE.minRate then return false end
    return displayRank(entry) >= STATE.minRank
end

local function sortByValue(a, b)
    local ar, br = a.rate or -1, b.rate or -1
    if ar ~= br then return ar > br end
    if displayRank(a) ~= displayRank(b) then return displayRank(a) > displayRank(b) end
    return tostring(a.name) < tostring(b.name)
end

-- Status is evidence-based. Missing NYX flags, transport failures and an
-- unavailable/expired claim are NEVER re-labelled TAKEN. A fresh feed rebuilds
-- rows from the server, so a local claim result cannot permanently poison one.
local STATUS = {}
function STATUS.now()
    return os.time() * 1000
end
function STATUS.of(entry, now)
    if type(entry) ~= "table" then return "unknown" end
    now = tonumber(now) or STATUS.now()
    if tonumber(entry.expiresAt) and entry.expiresAt > 0 and entry.expiresAt <= now then
        return "expired"
    end
    if entry.takenConfirmed == true or entry.taken == true or entry.claimStatus == "taken" then
        return "taken"
    end
    if entry.full == true or entry.claimStatus == "full" then return "full" end
    if entry.claimStatus == "expired" then return "expired" end
    if entry.claimStatus == "unavailable" then return "unknown" end
    if entry.unavailable == true then return "unknown" end
    -- Joinable requires positive feed evidence that BOTH state flags were sent
    -- and false. Own-backend rows without NYX-style flags deliberately remain
    -- UNKNOWN until their own preflight says allowed.
    if entry.hasTakenFlag and entry.hasFullFlag and not entry.taken and not entry.full then
        return "joinable"
    end
    return "unknown"
end
function STATUS.rank(entry, now)
    local state = STATUS.of(entry, now)
    return state == "joinable" and 1 or state == "unknown" and 2
        or state == "full" and 3 or state == "taken" and 4 or 5
end
function STATUS.count(entries, now)
    local counts = { joinable = 0, taken = 0, full = 0, unknown = 0, expired = 0 }
    for _, entry in ipairs(entries or {}) do
        if passesFilter(entry) then
            local state = STATUS.of(entry, now)
            counts[state] = (counts[state] or 0) + 1
        end
    end
    return counts
end

-- visible rows for the current tab. Never mutates STATE.raw / STATE.feed.
local function visibleList()
    local source = STATE.tab == "local" and STATE.raw or STATE.feed
    local matched = {}
    for _, entry in ipairs(source) do
        if passesFilter(entry) then matched[#matched + 1] = entry end
    end
    if STATE.tab == "all" then
        -- JOINABLE first, then UNKNOWN (preflight still possible), then
        -- confirmed FULL/TAKEN. This is a status sort, never a guess.
        table.sort(matched, function(a, b)
            local ar, br = STATUS.rank(a), STATUS.rank(b)
            if ar ~= br then return ar < br end
            return sortByValue(a, b)
        end)
    else
        table.sort(matched, sortByValue)
    end
    local limit = CONFIG.CARD_LIMIT
    if STATE.tab == "all" then limit = CONFIG.FEED_LIMIT end
    local shown = {}
    for index = 1, math.min(#matched, limit) do shown[index] = matched[index] end
    return shown, #matched, #source
end

local function markDirty()
    STATE.dirty = true
end

local function basePathOf(endpoint)
    local path = tostring(endpoint):match("^%a[%w+.-]*://[^/]+(/.*)$") or "/"
    return path:gsub("/+$", "")
end

-- stable local reporter id (never printed, never key material)
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
    if not CAPS.network then return nil, "executor has no HTTP function" end
    if not game.JobId or game.JobId == "" then return nil, "no server id" end
    local payload = {}
    for _, entry in ipairs(entries) do
        if validNumber(entry.rate) and entry.rate > 0 then
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
        if #payload >= 25 then break end
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

-- The backend is asked WITHOUT income/rarity filters so the client keeps the
-- full picture and can re-filter instantly when the user changes a filter.
-- excludeJob is what makes ALL SERVERS remote-only: the server drops every row
-- that belongs to the job we are standing in, instead of us guessing locally.
local function fetchFeed(offset)
    return api("GET", string.format(
        "/v1/eggs?placeId=%d&localJob=%s&excludeJob=%s&limit=%d&offset=%d&minRate=0&minRank=0&all=1",
        game.PlaceId, tostring(game.JobId or ""), tostring(game.JobId or ""),
        CONFIG.FEED_LIMIT, offset or 0
    ))
end

local INVALID_JOB = {
    [""] = true, ["0"] = true, ["nil"] = true, ["null"] = true, ["undefined"] = true,
}

local function validJobId(jobId)
    if type(jobId) ~= "string" then return false end
    if INVALID_JOB[jobId] then return false end
    if #jobId < 8 or #jobId > 64 then return false end
    if jobId == game.JobId then return false end
    if not jobId:match("^[%w%-_]+$") then return false end
    return true
end

local function normalizeFeedItem(item, feedSource)
    if type(item) ~= "table" then return nil end
    local jobId = type(item.jobId) == "string" and item.jobId or nil
    local rate = tonumber(item.rate)
    local rank = tonumber(item.rank) or 0
    local mutations = {}
    if type(item.mutations) == "string" then
        for token in item.mutations:gmatch("[^,;|+]+") do
            local clean = token:match("^%s*(.-)%s*$")
            if clean ~= "" then mutations[#mutations + 1] = clean end
        end
    elseif type(item.mutations) == "table" then
        for _, value in ipairs(item.mutations) do mutations[#mutations + 1] = tostring(value) end
    end
    return {
        uid = tostring(item.uid or (jobId or "?") .. ":" .. tostring(item.name or "?")),
        name = tostring(item.name or "Unknown egg"),
        rarity = tostring(item.rarity or "Unknown"),
        rank = rank,
        rate = validNumber(rate) and rate or nil,
        scale = tonumber(item.scale),
        weight = tonumber(item.weight),
        area = item.area and tostring(item.area) or nil,
        mutations = mutations,
        estimated = item.estimated == true,
        jobId = jobId,
        placeId = tonumber(item.placeId) or game.PlaceId,
        isLocal = item.isLocal == true or (jobId ~= nil and jobId == game.JobId),
        seenAt = tonumber(item.seenAt or item.updatedAt or item.reportedAt or item.createdAt),
        icon = type(item.icon) == "string" and item.icon:match("^rbxassetid://%d+$") and item.icon or nil,
        -- Transport provenance, not the reporter's own "source" field.  JOIN
        -- must claim against the network that actually served this row.
        source = feedSource or item.feedSource or "own",
        reportSource = item.source and tostring(item.source) or nil,
        -- Preserve raw NYX evidence separately. Missing is not false: missing
        -- status information renders UNKNOWN, not a fake JOIN or fake TAKEN.
        takenConfirmed = item.takenConfirmed == true,
        taken = item.taken == true,
        full = item.full == true,
        unavailable = item.unavailable == true,
        hasTakenFlag = type(item.takenConfirmed) == "boolean" or type(item.taken) == "boolean",
        hasFullFlag = type(item.full) == "boolean",
        hasUnavailableFlag = type(item.unavailable) == "boolean",
        expiresAt = tonumber(item.expiresAt),
    }
end

--==============================================================================
-- NYX FEED ADAPTER
-- Uses the shared cross-server network (authorised by its owner). No separate
-- key window, validation call, or remote code loading: only the documented
-- read feed + join claim, authenticated with the room key from NYX's own
-- public config so this file never carries or publishes a credential.
--==============================================================================
local NYX = {
    endpoint = nil,
    roomKey = nil,
    at = -math.huge,          -- when the config was last read
    error = nil,
    ttlSeconds = 90,
    servers = 0,
    participants = 0,
    serverTime = nil,         -- NYX clock in ms, used for expiry maths
}

function NYX.http(pathAndQuery, method, body, timeout)
    if not (NYX.endpoint and NYX.roomKey) then return nil, "nyx not configured" end
    local ok, response, transportError = pcall(httpRequest, {
        Url = NYX.endpoint .. pathAndQuery,
        Method = method or "GET",
        Headers = {
            ["Content-Type"] = "application/json",
            ["X-NYX-Room"] = NYX.roomKey,     -- NYX's own auth, unchanged
        },
        Body = body and HttpService:JSONEncode(body) or nil,
        Timeout = timeout or 8,
    })
    if not ok then return nil, tostring(response) end
    if type(response) ~= "table" then return nil, tostring(transportError or "request failed") end
    local code = tonumber(response.StatusCode or response.Status) or 0
    if code == 401 or code == 403 then return nil, "NYX key rejected (" .. code .. ")" end
    if code < 200 or code >= 300 then
        -- Do not surface an arbitrary upstream body: a misconfigured proxy can
        -- echo request material. The status is enough for an actionable UI.
        return nil, "NYX HTTP " .. code
    end
    local okDecode, decoded = pcall(HttpService.JSONDecode, HttpService, response.Body or "")
    if not okDecode or type(decoded) ~= "table" then return nil, "NYX returned non-JSON" end
    return decoded
end

-- Read (and cache for 10 minutes) NYX's public config. A pinned endpoint/key in
-- CONFIG wins, so the feed keeps working if that config URL ever moves.
function NYX.configure()
    if not CONFIG.NYX.ENABLED then return false, "nyx disabled" end
    if NYX.endpoint and NYX.roomKey and (os.clock() - NYX.at) < 600 then
        return true
    end
    local pinnedEndpoint = tostring(CONFIG.NYX.ENDPOINT or "")
    local pinnedRoomKey = tostring(CONFIG.NYX.ROOM_KEY or "")
    if pinnedEndpoint ~= "" and pinnedRoomKey ~= "" then
        NYX.endpoint = pinnedEndpoint:gsub("/+$", "")
        NYX.roomKey = pinnedRoomKey
        NYX.at = os.clock()
        NYX.error = nil
        return true
    end
    if not CAPS.network then return false, "nyx needs HTTP" end
    local ok, response = pcall(httpRequest, {
        Url = CONFIG.NYX.CONFIG_URL .. "?v=" .. tostring(math.floor(os.time())),
        Method = "GET", Timeout = 8,
    })
    if not ok or type(response) ~= "table" then return false, "NYX config unreachable" end
    local code = tonumber(response.StatusCode or response.Status) or 0
    if code < 200 or code >= 300 then return false, "NYX config HTTP " .. code end
    local okDecode, data = pcall(HttpService.JSONDecode, HttpService, response.Body or "")
    if not okDecode or type(data) ~= "table" then return false, "NYX config is not JSON" end
    -- A local override can pin either field independently; omitted fields still
    -- come from NYX's public runtime config, so no credential is committed.
    local endpoint = pinnedEndpoint ~= "" and pinnedEndpoint or tostring(data.endpoint or "")
    local roomKey = pinnedRoomKey ~= "" and pinnedRoomKey or tostring(data.roomKey or "")
    if not endpoint:match("^https://") or roomKey == "" then
        return false, "NYX config is missing endpoint/roomKey"
    end
    NYX.endpoint = endpoint:gsub("/+$", "")
    NYX.roomKey = roomKey
    NYX.at = os.clock()
    NYX.error = nil
    return true
end

-- One page of the shared feed. Remote-only is requested from the server itself,
-- so pages are never filled with the job the player is standing in.
function NYX.fetchPage(offset)
    local ready, why = NYX.configure()
    if not ready then
        NYX.error = tostring(why)
        return nil, NYX.error
    end
    local floor = math.max(0, tonumber(STATE.minRate) or 0)
    local rank = math.max(0, math.floor(tonumber(STATE.minRank) or 0))
    local query = string.format(
        "/v1/eggs?tier=%s&placeId=%d&localJob=%s&excludeJob=%s&minRate=%d&minRank=%d&limit=%d&offset=%d",
        tostring(CONFIG.NYX.TIER or "public"), game.PlaceId,
        tostring(game.JobId or ""), tostring(game.JobId or ""),
        math.floor(floor), rank, CONFIG.FEED_LIMIT, offset or 0
    )
    local data, err = NYX.http(query, "GET")
    if not data then
        NYX.error = tostring(err)
        return nil, err
    end
    NYX.error = nil
    NYX.ttlSeconds = tonumber(data.ttlSeconds) or NYX.ttlSeconds
    NYX.servers = tonumber(data.servers) or tonumber(data.retainedServers) or NYX.servers
    NYX.participants = tonumber(data.participants) or NYX.participants
    if tonumber(data.serverTime) then
        NYX.serverTime = tonumber(data.serverTime)
        NYX.serverClock = os.clock()     -- local reference for NYX.now()
    end
    return data
end

-- Authorised join claim. A refusal is data, not an error: NYX answers HTTP 200
-- with allowed=false plus the reason (expired / taken / full / unavailable).
function NYX.claim(entry)
    -- A row can stay on screen longer than the config cache. Re-check the
    -- runtime config before claiming so a rotated NYX room key is honoured.
    local ready, why = NYX.configure()
    if not ready then
        NYX.error = tostring(why)
        return nil, NYX.error
    end
    local data, err = NYX.http("/v1/join", "POST", {
        placeId = tonumber(entry.placeId),
        jobId = tostring(entry.jobId),
        uid = tostring(entry.uid),
        reporterId = reporterId,
    }, 8)
    if not data then
        NYX.error = tostring(err)
        return nil, err
    end
    return data
end

-- Turn either source's claim payload into an evidence-based result.
-- `allowed=false, unavailable=true, takenConfirmed=false` is a stale/expired
-- report, NOT proof that the egg was taken. NYX deliberately uses HTTP 200 for
-- this response, so the body is authoritative.
function NYX.claimVerdict(data)
    if type(data) ~= "table" then return "unknown", "claim returned invalid data" end
    if data.allowed == true then return "allowed", "claim accepted" end
    if data.takenConfirmed == true or data.taken == true then
        return "taken", "NYX confirmed this egg was taken"
    end
    if data.full == true then return "full", "NYX confirmed that server is full" end
    local reason = tostring(data.error or data.reason or "claim was not allowed")
    local lower = reason:lower()
    if data.expired == true or lower:find("expired", 1, true) then
        return "expired", reason
    end
    if data.unavailable == true or lower:find("no longer available", 1, true) then
        -- `unavailable` is a distinct current claim result, not proof of TAKEN
        -- and not proof that the feed's expiresAt elapsed.
        return "unavailable", reason
    end
    -- A generic refusal is still not TAKEN unless NYX supplied a confirming flag.
    return "unknown", reason
end

-- nowMs(): NYX publishes its own serverTime. Teleporting to another server does
-- not change it, so expiry comparisons stay correct.
function NYX.now()
    -- epoch milliseconds. NYX sends serverTime (ms) with every page; advance it
    -- locally from os.clock() so TTL maths does not depend on the player's clock.
    if NYX.serverTime and NYX.serverClock then
        return NYX.serverTime + (os.clock() - NYX.serverClock) * 1000
    end
    return os.time() * 1000
end

-- Continue beyond the normal page budget only when all reports seen so far are
-- confirmed unavailable. UNKNOWN remains actionable because a preflight can
-- still settle it, so it does not trigger wasteful extra pages.
function NYX.hasActionable(entries)
    for _, entry in ipairs(entries or {}) do
        local state = STATUS.of(entry, NYX.now())
        if state == "joinable" or state == "unknown" then return true end
    end
    return false
end

-- One boot probe that classifies the endpoint instead of only checking the path:
--   2xx        -> host runs the backend, nothing to say
--   401/403    -> host is behind platform auth, the app must be public
--   404 + path -> ENDPOINT has a stray path, calls become /v1/v1/...
--   404 at root-> host answers but the Node app is NOT mounted there (dead deploy)
--   no answer  -> unreachable
local function probeApiBase()
    if DIAG.probed or not CAPS.network then return end
    DIAG.probed = true
    local suffix = basePathOf(rawEndpoint())
    local ok, response = pcall(httpRequest, {
        Url = rawEndpoint() .. "/health",
        Method = "GET",
        Headers = { ["X-Egg-Room"] = CONFIG.ROOM_KEY },
        Timeout = 6,
    })
    local code = 0
    if ok and type(response) == "table" then
        code = tonumber(response.StatusCode or response.Status) or 0
    end
    if code >= 200 and code < 300 then
        DIAG.problem = nil
        return
    end
    if code == 401 or code == 403 then
        DIAG.problem = "host answered " .. code .. " at /health — the deployment is behind platform "
            .. "auth. The backend must be public, or the client cannot reach /v1/*."
        markDirty()
        return
    end
    if code == 404 or code == 405 then
        local body = ok and type(response) == "table" and tostring(response.Body or "") or ""
        if suffix ~= "" and suffix ~= "/" then
            DIAG.problem = string.format(
                "ENDPOINT has the path '%s' but the backend serves /v1/* at the host root — every call will 404. "
                    .. "Use the host only, e.g. %s", suffix, tostring(rawEndpoint()):gsub(suffix .. "/?$", "")
            )
        else
            DIAG.problem = "host is reachable but nothing is served at /health (HTTP 404"
                .. (body ~= "" and (": " .. body:sub(1, 60):gsub("%s+", " ")) or "")
                .. "). The Node app is not running at this URL — deploy/restart server.js, "
                .. "then tap REFRESH. Your ROOM_KEY cannot be the cause: nothing answered to check it."
        end
        markDirty()
        return
    end
    if code == 502 or code == 503 or code == 504 then
        DIAG.problem = "host answered " .. code .. " — the app behind the URL is down or still starting. "
            .. "Restart the deployment, then tap REFRESH."
        markDirty()
        return
    end
    DIAG.problem = "no answer from " .. rawEndpoint() .. " (health check failed). "
        .. "Check the URL, and that the deployment is awake and public."
    markDirty()
end

--==============================================================================
-- ORIGINAL M0x46 RED/BLACK MOBILE UI
-- Visual reference: compact neon operations console. This is an original layout
-- and keeps M0x46's feed/auth/data pipeline; it imports no third-party assets.
--==============================================================================
local GuiService = game:GetService("GuiService")
local THEME = {
    bg = Color3.fromRGB(5, 5, 7),
    panel = Color3.fromRGB(13, 10, 12),
    panelHigh = Color3.fromRGB(23, 14, 18),
    panelLow = Color3.fromRGB(8, 7, 8),
    red = Color3.fromRGB(235, 29, 47),
    redHot = Color3.fromRGB(255, 71, 71),
    redDeep = Color3.fromRGB(116, 11, 21),
    line = Color3.fromRGB(104, 26, 33),
    text = Color3.fromRGB(248, 244, 244),
    muted = Color3.fromRGB(176, 157, 160),
    green = Color3.fromRGB(76, 239, 129),
    amber = Color3.fromRGB(255, 190, 68),
    blue = Color3.fromRGB(88, 194, 255),
    gray = Color3.fromRGB(92, 92, 98),
}
local CARD_BG = Color3.fromRGB(15, 12, 14)

local function make(class, props, parent)
    local object = Instance.new(class)
    for key, value in pairs(props or {}) do object[key] = value end
    object.Parent = parent
    return object
end

local function corner(radius, parent)
    return make("UICorner", { CornerRadius = UDim.new(0, radius) }, parent)
end

local function stroke(parent, color, thickness, transparency)
    return make("UIStroke", {
        Color = color or THEME.line, Thickness = thickness or 1,
        Transparency = transparency == nil and 0.25 or transparency,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, parent)
end

local function label(parent, text, position, size, color, textSize)
    return make("TextLabel", {
        Text = text or "", Position = position or UDim2.new(), Size = size or UDim2.new(),
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = textSize or 12,
        TextColor3 = color or THEME.text, TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, parent)
end

local function button(parent, props, accent)
    local radius = props.CornerRadius or 8
    local data = {}
    for key, value in pairs(props or {}) do if key ~= "CornerRadius" then data[key] = value end end
    local object = make("TextButton", data, parent)
    object.BackgroundColor3 = accent and THEME.redDeep or THEME.panelHigh
    object.BackgroundTransparency = accent and 0.04 or 0.08
    object.TextColor3 = THEME.text
    object.Font = Enum.Font.GothamBold
    object.TextSize = props.TextSize or 11
    object.BorderSizePixel = 0
    object.AutoButtonColor = false
    corner(radius, object)
    stroke(object, accent and THEME.redHot or THEME.line, accent and 1.5 or 1, accent and 0.12 or 0.32)
    return object
end

--==============================================================================
-- ROOT GUI AND CONTROLS
--==============================================================================
local UI = {}
local connections = {}
local function connect(signal, callback)
    local connection = signal:Connect(callback)
    connections[#connections + 1] = connection
    return connection
end
local oldGui = playerGui:FindFirstChild("M0x46Finder")
if oldGui then oldGui:Destroy() end
UI.gui = make("ScreenGui", {
    Name = "M0x46Finder", ResetOnSpawn = false, IgnoreGuiInset = true,
    DisplayOrder = 1200, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, playerGui)
pcall(function() UI.gui.ScreenInsets = Enum.ScreenInsets.None end)

local function viewport()
    local ok, camera = pcall(function() return workspace.CurrentCamera end)
    local size = ok and camera and camera.ViewportSize
    if size and size.X and size.Y and size.X > 0 and size.Y > 0 then return size.X, size.Y end
    return 1280, 720
end

local SCREEN_MARGIN = 12
UI.panelX, UI.panelY, UI.panelW, UI.panelH = 18, 64, 680, 410

UI.launcher = make("TextButton", {
    Name = "Launcher", Text = "M0x46", Position = UDim2.fromOffset(18, 120),
    Size = UDim2.fromOffset(60, 60), BackgroundColor3 = THEME.redDeep,
    BorderSizePixel = 0, AutoButtonColor = false, ZIndex = 40,
    Font = Enum.Font.GothamBlack, TextSize = 13, TextColor3 = THEME.text,
}, UI.gui)
corner(999, UI.launcher)
stroke(UI.launcher, THEME.redHot, 2, 0.05)
make("UIGradient", { Rotation = 45, Color = ColorSequence.new(THEME.redDeep, THEME.red) }, UI.launcher)
UI.launcherDot = make("Frame", {
    Name = "Live", Position = UDim2.new(1, -14, 0, 7), Size = UDim2.fromOffset(9, 9),
    BackgroundColor3 = THEME.muted, BorderSizePixel = 0, ZIndex = 42,
}, UI.launcher)
corner(999, UI.launcherDot)
stroke(UI.launcherDot, THEME.bg, 2, 0.1)

UI.panel = make("Frame", {
    Name = "Panel", Position = UDim2.fromOffset(UI.panelX, UI.panelY),
    Size = UDim2.fromOffset(UI.panelW, UI.panelH), BackgroundColor3 = THEME.bg,
    BorderSizePixel = 0, Active = true, Visible = false, ClipsDescendants = true, ZIndex = 10,
}, UI.gui)
corner(12, UI.panel)
stroke(UI.panel, THEME.red, 2, 0.08)
make("UIGradient", { Rotation = 90, Color = ColorSequence.new(THEME.panel, THEME.bg) }, UI.panel)
UI.panelScale = make("UIScale", { Scale = 1 }, UI.panel)

-- Original red framing.
local edge = make("Frame", {
    Name = "RedEdge", Position = UDim2.fromOffset(0, 0), Size = UDim2.new(1, 0, 1, 0),
    BackgroundTransparency = 1, BorderSizePixel = 0, Active = false, ZIndex = 11,
}, UI.panel)
corner(12, edge)
stroke(edge, THEME.redHot, 5, 0.78)
local accentSlash = make("Frame", {
    Name = "AccentSlash", AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.new(0, 42, 1, -54), Size = UDim2.fromOffset(150, 9),
    Rotation = -42, BackgroundColor3 = THEME.red, BackgroundTransparency = 0.4,
    BorderSizePixel = 0, ZIndex = 11,
}, UI.panel)
make("UIGradient", { Color = ColorSequence.new(THEME.redDeep, THEME.redHot) }, accentSlash)
UI.sidebar = make("Frame", {
    Name = "Sidebar", BackgroundColor3 = THEME.panelLow, BackgroundTransparency = 0.12, BorderSizePixel = 0, ZIndex = 12,
}, UI.panel)
stroke(UI.sidebar, THEME.line, 1, 0.18)
UI.brand = label(UI.sidebar, "M0x46\nFINDER", UDim2.fromOffset(10, 9), UDim2.new(1, -20, 0, 36), THEME.text, 15)
UI.brand.Font = Enum.Font.GothamBlack
UI.connectionDot = make("Frame", {
    Name = "ConnectionDot", BackgroundColor3 = THEME.amber, BorderSizePixel = 0, ZIndex = 14,
}, UI.sidebar)
corner(999, UI.connectionDot)
UI.connectionLabel = label(UI.sidebar, "CHECKING", UDim2.new(), UDim2.new(), THEME.muted, 9)
UI.connectionLabel.ZIndex = 14

UI.logsButton = button(UI.sidebar, { Name = "NavLogs", Text = "◉  LOGS", TextXAlignment = Enum.TextXAlignment.Left, CornerRadius = 8, ZIndex = 14 }, true)
UI.historyButton = button(UI.sidebar, { Name = "NavHistory", Text = "◷  HISTORY", TextXAlignment = Enum.TextXAlignment.Left, CornerRadius = 8, ZIndex = 14 }, false)
UI.settingsButton = button(UI.sidebar, { Name = "Settings", Text = "⚙  SETTINGS", TextXAlignment = Enum.TextXAlignment.Left, CornerRadius = 8, ZIndex = 14 }, false)
UI.usersButton = button(UI.sidebar, { Name = "NavUsers", Text = "◌  USERS", TextXAlignment = Enum.TextXAlignment.Left, CornerRadius = 8, ZIndex = 14 }, false)
UI.hideButton = button(UI.sidebar, { Name = "Minimize", Text = "✕  HIDE", CornerRadius = 8, ZIndex = 14 }, true)

UI.header = make("Frame", {
    Name = "Header", BackgroundColor3 = THEME.panelLow, BorderSizePixel = 0, ZIndex = 12,
}, UI.panel)
corner(10, UI.header)
stroke(UI.header, THEME.line, 1, 0.28)
UI.title = label(UI.panel, "LIVE FEED", UDim2.new(), UDim2.new(), THEME.text, 17)
UI.title.Font = Enum.Font.GothamBlack
UI.title.ZIndex = 14
UI.statusText = label(UI.panel, "connecting…", UDim2.new(), UDim2.new(), THEME.muted, 10)
UI.statusText.Font = Enum.Font.Gotham
UI.statusText.ZIndex = 14
UI.closeButton = button(UI.panel, { Name = "Close", Text = "×", TextSize = 17, CornerRadius = 8, ZIndex = 15 }, false)
UI.closeButton.TextColor3 = THEME.redHot

UI.autoJoinToggle = button(UI.panel, { Name = "AutoJoinToggle", Text = "AUTO-JOIN: OFF", CornerRadius = 9, ZIndex = 15 }, false)
UI.autoForceToggle = button(UI.panel, { Name = "AutoForceToggle", Text = "AUTO-FORCE: OFF", CornerRadius = 9, ZIndex = 15 }, false)
UI.filterButton = button(UI.panel, { Name = "RarityFilter", Text = "RARITY: ANY", CornerRadius = 8, ZIndex = 14 }, false)
UI.refreshButton = button(UI.panel, { Name = "Refresh", Text = "↻", CornerRadius = 8, ZIndex = 14 }, true)
UI.clearButton = button(UI.panel, { Name = "Clear", Text = "CLEAR", CornerRadius = 8, ZIndex = 14 }, false)

UI.localTab = button(UI.panel, { Name = "TabLocal", Text = "MY SERVER", CornerRadius = 7, ZIndex = 14 }, false)
UI.feedTab = button(UI.panel, { Name = "TabAll", Text = "ALL SERVERS", CornerRadius = 7, ZIndex = 14 }, true)
UI.countJoin = label(UI.panel, "JOINABLE 0", UDim2.new(), UDim2.new(), THEME.green, 9)
UI.countTaken = label(UI.panel, "TAKEN 0", UDim2.new(), UDim2.new(), THEME.redHot, 9)
UI.countFull = label(UI.panel, "FULL 0", UDim2.new(), UDim2.new(), THEME.amber, 9)
UI.countUnknown = label(UI.panel, "UNKNOWN 0", UDim2.new(), UDim2.new(), THEME.blue, 9)
for _, chip in ipairs({ UI.countJoin, UI.countTaken, UI.countFull, UI.countUnknown }) do
    chip.TextXAlignment = Enum.TextXAlignment.Center
    chip.BackgroundColor3 = THEME.panelHigh
    chip.BackgroundTransparency = 0.06
    chip.ZIndex = 14
    corner(5, chip)
    stroke(chip, THEME.line, 1, 0.45)
end

UI.list = make("ScrollingFrame", {
    Name = "List", BackgroundTransparency = 1, BorderSizePixel = 0, CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 4,
    ScrollBarImageColor3 = THEME.red, ScrollBarImageTransparency = 0.2,
    ScrollingDirection = Enum.ScrollingDirection.Y, ElasticBehavior = Enum.ElasticBehavior.WhenScrollable,
    ZIndex = 13,
}, UI.panel)
make("UIListLayout", { Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }, UI.list)
make("UIPadding", { PaddingLeft = UDim.new(0, 2), PaddingRight = UDim.new(0, 2), PaddingBottom = UDim.new(0, 4) }, UI.list)

-- Settings is an in-panel, scrollable diagnostic drawer so mobile never clips it.
UI.overlay = make("Frame", {
    Active = true, Name = "SettingsOverlay", Position = UDim2.fromScale(0, 0), Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = THEME.bg, BackgroundTransparency = 0.01, BorderSizePixel = 0,
    Visible = false, ZIndex = 50,
}, UI.panel)
corner(12, UI.overlay)
stroke(UI.overlay, THEME.red, 1.6, 0.12)
UI.overlayTitle = label(UI.overlay, "SETTINGS", UDim2.fromOffset(16, 12), UDim2.new(1, -70, 0, 22), THEME.text, 15)
UI.overlayTitle.Font = Enum.Font.GothamBlack
UI.overlayTitle.ZIndex = 51
UI.overlayClose = button(UI.overlay, { Name = "SettingsClose", Text = "×", Position = UDim2.new(1, -42, 0, 10), Size = UDim2.fromOffset(30, 28), TextSize = 16, CornerRadius = 8, ZIndex = 52 }, false)
UI.overlayClose.TextColor3 = THEME.redHot
UI.overlayBody = make("ScrollingFrame", {
    Name = "SettingsBody", Position = UDim2.fromOffset(10, 43), Size = UDim2.new(1, -20, 1, -53),
    BackgroundTransparency = 1, BorderSizePixel = 0, CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 3, ScrollBarImageColor3 = THEME.red,
    ScrollingDirection = Enum.ScrollingDirection.Y, ZIndex = 51,
}, UI.overlay)
make("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, UI.overlayBody)
make("UIPadding", { PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 10) }, UI.overlayBody)

-- FORCE confirmation dialog; the existing confirmation handler is retained below.
UI.forceModal = make("Frame", {
    Active = true, Name = "ForceConfirm", Position = UDim2.fromScale(0, 0), Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Color3.fromRGB(0, 0, 0), BackgroundTransparency = 0.18,
    BorderSizePixel = 0, Visible = false, ZIndex = 80,
}, UI.panel)
local forceBox = make("Frame", {
    Name = "Dialog", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.new(0.78, 0, 0, 196), BackgroundColor3 = THEME.panel,
    BorderSizePixel = 0, ZIndex = 81,
}, UI.forceModal)
corner(10, forceBox); stroke(forceBox, THEME.redHot, 1.5, 0.1)
UI.forceTitle = label(forceBox, "CONFIRM FORCE JOIN", UDim2.fromOffset(14, 13), UDim2.new(1, -28, 0, 21), THEME.redHot, 14)
UI.forceTitle.Font = Enum.Font.GothamBlack; UI.forceTitle.ZIndex = 82
UI.forceBody = label(forceBox, "", UDim2.fromOffset(14, 40), UDim2.new(1, -28, 0, 92), THEME.text, 10)
UI.forceBody.TextWrapped = true; UI.forceBody.TextYAlignment = Enum.TextYAlignment.Top; UI.forceBody.ZIndex = 82
UI.forceCancel = button(forceBox, { Name = "ForceCancel", Text = "CANCEL", Position = UDim2.new(0, 14, 1, -45), Size = UDim2.new(0.42, -18, 0, 31), CornerRadius = 8, ZIndex = 83 }, false)
UI.forceConfirm = button(forceBox, { Name = "ForceConfirmButton", Text = "CONFIRM FORCE", Position = UDim2.new(0.42, 2, 1, -45), Size = UDim2.new(0.58, -16, 0, 31), CornerRadius = 8, ZIndex = 83 }, true)
UI.forceEntry = nil

UI.rateRow = make("Frame", { Name = "RateRow", Size = UDim2.new(1, -10, 0, 72), BackgroundTransparency = 1, LayoutOrder = 1, ZIndex = 51 }, UI.overlayBody)
local rateTitle = label(UI.rateRow, "MINIMUM INCOME", UDim2.fromOffset(2, 0), UDim2.new(1, -4, 0, 16), THEME.muted, 10)
rateTitle.Font = Enum.Font.GothamBold
UI.rateBox = make("TextBox", {
    Name = "MinRate", Text = moneyFilter(STATE.minRate), PlaceholderText = "1B",
    Position = UDim2.fromOffset(0, 20), Size = UDim2.new(0.36, -3, 0, 30), BackgroundColor3 = THEME.panelHigh,
    TextColor3 = THEME.text, Font = Enum.Font.GothamBold, TextSize = 13, ClearTextOnFocus = false,
    BorderSizePixel = 0, TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 52,
}, UI.rateRow)
corner(7, UI.rateBox)
stroke(UI.rateBox, THEME.red, 1, 0.35)
UI.presetButtons = {}
for index, preset in ipairs({ { "OFF", 0 }, { "250M", 2.5e8 }, { "1B", 1e9 }, { "5B", 5e9 } }) do
    local item = button(UI.rateRow, {
        Name = "Preset" .. preset[1], Text = preset[1], Position = UDim2.new(0.36 + (index - 1) * 0.16, 2, 0, 20),
        Size = UDim2.new(0.16, -4, 0, 30), TextSize = 9, CornerRadius = 7, ZIndex = 52,
    }, false)
    UI.presetButtons[#UI.presetButtons + 1] = { button = item, value = preset[2] }
end
local rateHint = label(UI.rateRow, "Minimum income sent to the feed", UDim2.fromOffset(2, 55), UDim2.new(1, -4, 0, 14), THEME.muted, 9)
rateHint.Font = Enum.Font.Gotham

UI.broadcastToggle = button(UI.overlayBody, { Name = "BroadcastToggle", Text = "BROADCAST: OFF", Size = UDim2.new(1, -10, 0, 36), LayoutOrder = 2, CornerRadius = 8, ZIndex = 52 }, false)
UI.infoRow = label(UI.overlayBody, "", UDim2.new(), UDim2.new(1, -10, 0, 220), THEME.muted, 10)
UI.infoRow.Name = "Diagnostics"
UI.infoRow.LayoutOrder = 3
UI.infoRow.TextWrapped = true
UI.infoRow.TextYAlignment = Enum.TextYAlignment.Top
UI.infoRow.ZIndex = 52

-- Presentation controls; the original public buttons remain TextButtons.
local switchParts = {}
for _, control in ipairs({UI.autoJoinToggle, UI.autoForceToggle}) do
    control.TextXAlignment = Enum.TextXAlignment.Left
    make("UIPadding", {PaddingLeft = UDim.new(0, 10)}, control)
    local track = make("Frame", {
        Name = "SwitchTrack", AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(34, 19),
        BackgroundColor3 = THEME.line, BorderSizePixel = 0, ZIndex = 16,
    }, control)
    corner(99, track)
    local thumb = make("Frame", {
        Name = "Thumb", Position = UDim2.fromOffset(3, 3), Size = UDim2.fromOffset(13, 13),
        BackgroundColor3 = THEME.text, BorderSizePixel = 0, ZIndex = 17,
    }, track)
    corner(99, thumb)
    switchParts[control] = {track = track, thumb = thumb}
end
UI.minusButton = button(UI.panel, {Name = "SizeDown", Text = "−", TextSize = 18, ZIndex = 20}, false)
UI.plusButton = button(UI.panel, {Name = "SizeUp", Text = "+", TextSize = 16, ZIndex = 20}, false)
UI.resizeHandle = button(UI.panel, {Name = "ResizeGrip", Text = "◢", TextSize = 17, ZIndex = 22}, false)
UI.resizeHandle.TextColor3 = THEME.redHot
UI.totalLabel = label(UI.panel, "0 shown", UDim2.new(), UDim2.new(), THEME.muted, 10)
UI.totalLabel.TextXAlignment = Enum.TextXAlignment.Right; UI.totalLabel.ZIndex = 14
local feedDot = make("Frame", {Name = "FeedDot", BackgroundColor3 = THEME.red,
    BorderSizePixel = 0, ZIndex = 14}, UI.panel)
corner(99, feedDot)
local footerLine = make("Frame", {Name = "FooterLine", BackgroundColor3 = THEME.line,
    BackgroundTransparency = 0.45, BorderSizePixel = 0, ZIndex = 13}, UI.panel)
local dragHint = label(UI.header, "• • •", UDim2.new(0.5, -20, 0, 0), UDim2.fromOffset(40, 9), THEME.redDeep, 9)
dragHint.TextXAlignment = Enum.TextXAlignment.Center; dragHint.ZIndex = 15
UI.header.Active = true; UI.brand.Active = true; dragHint.Active = true

-- Settings remains scrollable at the smallest supported window size.
UI.windowRow = make("Frame", {Name = "WindowSize", BackgroundTransparency = 1,
    Size = UDim2.new(1, -10, 0, 65), LayoutOrder = 2, ZIndex = 51}, UI.overlayBody)
label(UI.windowRow, "WINDOW SIZE", UDim2.fromOffset(2, 0), UDim2.new(1, -4, 0, 16), THEME.muted, 10).ZIndex = 52
UI.windowMinus = button(UI.windowRow, {Name = "Smaller", Text = "−", Position = UDim2.fromOffset(0, 23), Size = UDim2.new(0.25, -4, 0, 32), ZIndex = 52}, false)
UI.windowPlus = button(UI.windowRow, {Name = "Larger", Text = "+", Position = UDim2.new(0.25, 2, 0, 23), Size = UDim2.new(0.25, -4, 0, 32), ZIndex = 52}, false)
UI.resetSizeButton = button(UI.windowRow, {Name = "ResetSize", Text = "RESET SIZE", Position = UDim2.new(0.5, 4, 0, 23), Size = UDim2.new(0.5, -4, 0, 32), ZIndex = 52}, true)
UI.filterButton.Parent = UI.overlayBody
UI.filterButton.LayoutOrder = 3; UI.filterButton.Size = UDim2.new(1, -10, 0, 34); UI.filterButton.ZIndex = 52
UI.broadcastToggle.LayoutOrder = 4
UI.infoRow.LayoutOrder = 5
UI.infoRow.Size = UDim2.new(1, -10, 0, 260)

local function screenBounds()
    local w, h = viewport()
    local left, top, right, bottom = SCREEN_MARGIN, SCREEN_MARGIN, w - SCREEN_MARGIN, h - SCREEN_MARGIN
    local ok, a, b = pcall(function() return GuiService:GetGuiInset() end)
    if ok and a and b then
        left = math.max(left, a.X + SCREEN_MARGIN)
        top = math.max(top, a.Y + SCREEN_MARGIN)
        right = math.min(right, w - b.X - SCREEN_MARGIN)
        bottom = math.min(bottom, h - b.Y - SCREEN_MARGIN)
    end
    return left, top, math.max(left + 1, right), math.max(top + 1, bottom)
end
local function sizeLimits()
    local l, t, r, b = screenBounds()
    local aw, ah = r - l, b - t
    local maxW, maxH = math.floor(aw * 0.94), math.floor(ah * 0.9)
    return math.min(300, maxW), math.min(228, maxH), maxW, maxH
end
local function box(object, x, y, w, h)
    object.Position = UDim2.fromOffset(math.floor(x), math.floor(y))
    object.Size = UDim2.fromOffset(math.max(1, math.floor(w)), math.max(1, math.floor(h)))
end
function UI.clampPanel()
    local l, t, r, b = screenBounds()
    local minW, minH, maxW, maxH = sizeLimits()
    UI.panelW, UI.panelH = clamp(UI.panelW, minW, maxW), clamp(UI.panelH, minH, maxH)
    UI.panelX = clamp(UI.panelX, l, r - UI.panelW)
    UI.panelY = clamp(UI.panelY, t, b - UI.panelH)
    box(UI.panel, UI.panelX, UI.panelY, UI.panelW, UI.panelH)
    local compact = UI.panelW < 560
    local side = compact and 78 or 136
    local x, w = side + 12, UI.panelW - side - 24
    UI.contentW = w
    box(UI.sidebar, 0, 0, side, UI.panelH)
    box(UI.header, 4, 0, UI.panelW - 8, 10)
    UI.header.BackgroundTransparency = 1
    box(UI.brand, compact and 9 or 14, 16, side - (compact and 16 or 24), 36)
    UI.brand.TextSize = compact and 13 or 18
    UI.brand.Text = "M0x46\nFINDER"
    box(UI.connectionDot, compact and 10 or 15, 58, 6, 6)
    box(UI.connectionLabel, compact and 22 or 27, 53, side - (compact and 26 or 30), 16)
    UI.connectionLabel.TextSize = compact and 9 or 10
    local navH = UI.panelH < 290 and 24 or 34
    local navY = UI.panelH < 290 and 76 or 88
    for i, control in ipairs({UI.logsButton, UI.historyButton, UI.settingsButton, UI.usersButton}) do
        box(control, 7, navY + (i - 1) * (navH + 5), side - 14, navH)
        control.Text = (compact and {"LOGS", "HISTORY", "SETTINGS", "USERS"} or {"◉  Logs", "◷  History", "⚙  Settings", "◌  Users"})[i]
        control.TextXAlignment = Enum.TextXAlignment.Center
        control.TextSize = compact and 9 or 12
    end
    box(UI.hideButton, 7, UI.panelH - 37, side - 14, 28)
    UI.hideButton.Text = compact and "× HIDE" or "×  Hide"
    UI.hideButton.TextSize = compact and 10 or 12

    local toggleW = math.floor((w - 8) / 2)
    box(UI.autoJoinToggle, x, 14, toggleW, 34)
    box(UI.autoForceToggle, x + toggleW + 8, 14, toggleW, 34)
    for control, parts in pairs(switchParts) do
        local tiny = toggleW < 130
        local tw, th = tiny and 26 or 34, tiny and 16 or 19
        parts.track.Size = UDim2.fromOffset(tw, th)
        parts.track.Position = UDim2.new(1, -6, 0.5, 0)
        parts.thumb.Size = UDim2.fromOffset(th - 6, th - 6)
        local on = (control == UI.autoJoinToggle and CONFIG.AUTO_JOIN) or (control == UI.autoForceToggle and CONFIG.AUTO_FORCE)
        parts.thumb.Position = UDim2.fromOffset(on and tw - th + 3 or 3, 3)
        control.TextSize = tiny and 9 or 11
        control.Text = control == UI.autoJoinToggle and (tiny and "A-JOIN" or "Auto-Join") or (tiny and "A-FORCE" or "Auto-Force")
    end
    box(feedDot, x, 63, 6, 6)
    box(UI.title, x + 12, 56, w - 140, 20)
    UI.title.TextSize = w < 290 and 10 or 12
    UI.title.Text = STATE.tab == "all" and "LIVE FEED" or "MY SERVER"
    box(UI.totalLabel, x + w - 124, 56, 50, 20)
    UI.totalLabel.TextSize = 9
    box(UI.refreshButton, x + w - 66, 55, 27, 23)
    UI.refreshButton.TextSize = 17
    box(UI.clearButton, x + w - 34, 55, 34, 23)
    UI.clearButton.TextSize = 9
    UI.clearButton.Text = "Clear"
    box(UI.localTab, x, 86, (w - 6) / 2, 25)
    box(UI.feedTab, x + (w - 6) / 2 + 6, 86, (w - 6) / 2, 25)
    UI.localTab.TextSize, UI.feedTab.TextSize = 10, 10
    for i, chip in ipairs({UI.countJoin, UI.countTaken, UI.countFull, UI.countUnknown}) do
        box(chip, x + (i - 1) * (w + 4) / 4, 118, (w - 12) / 4, 17)
        chip.TextSize = 9
    end
    box(UI.list, x - 2, 143, w + 4, UI.panelH - 179)
    box(footerLine, x, UI.panelH - 31, w, 1)
    box(UI.statusText, x, UI.panelH - 26, w - 125, 19)
    UI.statusText.TextSize = 9
    box(UI.minusButton, x + w - 118, UI.panelH - 26, 26, 20)
    box(UI.plusButton, x + w - 87, UI.panelH - 26, 26, 20)
    box(UI.closeButton, x + w - 56, UI.panelH - 26, 24, 20)
    box(UI.resizeHandle, UI.panelW - 29, UI.panelH - 29, 24, 24)
    UI.resizeHandle.BackgroundTransparency = 1
end
function UI.clampLauncher()
    local l, t, r, b = screenBounds()
    local p = UI.launcher.Position
    UI.launcher.Position = UDim2.fromOffset(clamp(p.X.Offset, l, math.max(l, r - 60)), clamp(p.Y.Offset, t, math.max(t, b - 60)))
end
function UI.cardHeight() return (UI.contentW or 400) < 310 and 86 or 76 end
function UI.applyLayout()
    UI.clampPanel(); UI.clampLauncher()
    markDirty()
    if UI.reflowCards then UI.reflowCards() end
    if UI.paintCounts then UI.paintCounts() end
end
function UI.resize(width, height)
    UI.panelW, UI.panelH = tonumber(width) or UI.panelW, tonumber(height) or UI.panelH
    UI.applyLayout()
end
function UI.resizeBy(factor)
    factor = tonumber(factor)
    if not validNumber(factor) or factor <= 0 then return end
    local cx, cy = UI.panelX + UI.panelW / 2, UI.panelY + UI.panelH / 2
    local minW, minH, maxW, maxH = sizeLimits()
    UI.panelW, UI.panelH = clamp(UI.panelW * factor, minW, maxW), clamp(UI.panelH * factor, minH, maxH)
    UI.panelX, UI.panelY = cx - UI.panelW / 2, cy - UI.panelH / 2
    UI.applyLayout()
end
function UI.resetSize()
    local l, t, r, b = screenBounds()
    local aw, ah = r - l, b - t
    local portrait = ah > aw
    UI.panelW = math.min(760, aw * (portrait and 0.9 or 0.76))
    UI.panelH = math.min(460, ah * (portrait and 0.55 or 0.74))
    local minW, minH, maxW, maxH = sizeLimits()
    UI.panelW, UI.panelH = clamp(UI.panelW, minW, maxW), clamp(UI.panelH, minH, maxH)
    UI.panelX, UI.panelY = l + (aw - UI.panelW) / 2, t + (ah - UI.panelH) / 2
    UI.applyLayout()
end

-- One input owner: a second touch cannot hijack dragging/resizing.
local gesture, suppressLauncher = nil, false
local function begin(handle, mode)
    connect(handle.InputBegan, function(input)
        if gesture then return end
        local touch = input.UserInputType == Enum.UserInputType.Touch
        if not touch and input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        gesture = {mode = mode, input = input, touch = touch, x = input.Position.X, y = input.Position.Y,
            px = UI.panelX, py = UI.panelY, w = UI.panelW, h = UI.panelH,
            lx = UI.launcher.Position.X.Offset, ly = UI.launcher.Position.Y.Offset, moved = false}
    end)
end
begin(UI.header, "move"); begin(UI.brand, "move"); begin(dragHint, "move")
begin(UI.launcher, "launcher"); begin(UI.resizeHandle, "resize")
connect(UserInputService.InputChanged, function(input)
    local g = gesture
    if not g then return end
    if g.touch then if input ~= g.input then return end
    elseif input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
    local dx, dy = input.Position.X - g.x, input.Position.Y - g.y
    if math.abs(dx) + math.abs(dy) > 5 then g.moved = true end
    if not g.moved then return end
    if g.mode == "resize" then
        UI.resize(g.w + dx, g.h + dy)
    elseif g.mode == "move" then
        local l, t, r, b = screenBounds()
        UI.panelX, UI.panelY = clamp(g.px + dx, l, r - UI.panelW), clamp(g.py + dy, t, b - UI.panelH)
        UI.panel.Position = UDim2.fromOffset(UI.panelX, UI.panelY)
    else
        UI.launcher.Position = UDim2.fromOffset(g.lx + dx, g.ly + dy)
        UI.clampLauncher()
    end
end)
connect(UserInputService.InputEnded, function(input)
    local g = gesture
    if not g then return end
    if (g.touch and input ~= g.input) or (not g.touch and input.UserInputType ~= Enum.UserInputType.MouseButton1) then return end
    if g.mode == "launcher" and g.moved then suppressLauncher = true end
    gesture = nil
end)
local cameraConnection
local function bindCamera()
    if cameraConnection then cameraConnection:Disconnect() end
    local camera = workspace.CurrentCamera
    if camera then cameraConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
        gesture = nil
        UI.applyLayout()
    end) end
    UI.applyLayout()
end
connect(workspace:GetPropertyChangedSignal("CurrentCamera"), bindCamera)

--==============================================================================
-- JOIN  (implementation must sit ABOVE the card renderer: a `local function`
--        referenced earlier resolves to a nil global and silently does nothing)
--==============================================================================
-- A teleport is only attempted with a placeId taken from the report and a jobId
-- that passes the real Roblox job-id shape test. Everything else is refused out
-- loud instead of being passed to TeleportToPlaceInstance and failing invisibly.
local openForceConfirm
local actionAllowed

local function validPlaceId(placeId)
    local value = tonumber(placeId)
    return value ~= nil and value > 0 and value == math.floor(value)
end

local function jobShape(jobId)
    if type(jobId) ~= "string" then return false, "no JobId on this report" end
    if jobId == game.JobId then return false, "that report is this server" end
    if #jobId < 8 or #jobId > 64 then
        return false, string.format("JobId is %d chars (expected 8-64)", #jobId)
    end
    if not jobId:match("^[%w%-_]+$") then return false, "JobId has characters Roblox never emits" end
    -- Modern Roblox job ids are 36-char UUIDs (6f1d0c7e-2b44-4a1e-9c3d-77aa21b09f11);
    -- older/legacy ids look like job-xxxxxxxx. Anything else is refused rather than
    -- handed to TeleportToPlaceInstance where it fails silently.
    local UUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"
    if jobId:match(UUID) then return true end
    if jobId:match("^job%-") then return true end
    if #jobId >= 20 then return true end
    return false, "JobId shape is not a Roblox job id"
end

-- Ask only the source that published the row. Standard JOIN must receive an
-- explicit `allowed=true`; a network error, stale claim, or unknown refusal
-- never becomes a teleport or a fake TAKEN state.
function NYX.claimRemote(entry)
    if not CAPS.network then return "network", "HTTP unavailable" end
    local data, err
    if entry and entry.source == "nyx" then
        data, err = NYX.claim(entry)
        if not data then return "network", "NYX claim unavailable: " .. tostring(err or "request failed") end
        return NYX.claimVerdict(data)
    end
    data, err = api("POST", "/v1/join", {
        placeId = tonumber(entry and entry.placeId),
        jobId = entry and entry.jobId,
        uid = entry and entry.uid,
        reporterId = reporterId,
    })
    if not data then return "network", "own-backend claim unavailable: " .. tostring(err or "request failed") end
    return NYX.claimVerdict(data)
end

local function teleportEntry(entry, mode)
    local ok, err = pcall(function()
        TeleportService:TeleportToPlaceInstance(tonumber(entry.placeId), entry.jobId, player)
    end)
    if not ok then
        NYX.note("TELEPORT ERROR", tostring(err))
        notify("teleport failed: " .. tostring(err), 8)
        return false
    end
    NYX.note(mode == "force" and "FORCE" or "JOIN", "teleport requested for " .. shortId(entry.jobId))
    notify((mode == "force" and "force teleport requested → " or "teleport requested → ") .. shortId(entry.jobId), 6)
    return true
end

local function requestJoin(entry)
    local shapeOk, shapeWhy = jobShape(entry.jobId)
    if not shapeOk then
        NYX.note("JOIN BLOCKED", tostring(shapeWhy))
        notify("cannot JOIN: " .. tostring(shapeWhy), 6)
        return false
    end
    if not validPlaceId(entry.placeId) then
        NYX.note("JOIN BLOCKED", "report has no valid PlaceId")
        notify("cannot JOIN: report has no valid PlaceId", 6)
        return false
    end
    local state = STATUS.of(entry, NYX.now())
    if state == "taken" or state == "full" or state == "expired" then
        NYX.note("JOIN BLOCKED", "report is " .. string.upper(state))
        notify("cannot JOIN: this report is " .. string.upper(state) .. " — refresh for a fresh report", 7)
        return false
    end
    NYX.note("JOIN", "source preflight for " .. shortId(entry.jobId))
    notify("source preflight for " .. shortId(entry.jobId) .. "…", 8)
    local ok, kind, detail = pcall(NYX.claimRemote, entry)
    if not ok then kind, detail = "network", "claim call failed" end
    if kind ~= "allowed" then
        -- Only an explicit source response can label FULL or TAKEN. Expired,
        -- unavailable, generic refusals and network failures remain UNKNOWN.
        entry.claimStatus = kind
        entry.claimDetail = detail
        NYX.note("JOIN REFUSED", tostring(detail or kind))
        markDirty()
        notify("JOIN not sent: " .. tostring(detail or kind), 8)
        return false
    end
    entry.claimStatus = nil
    entry.claimDetail = nil
    NYX.note("JOIN", "preflight allowed for " .. shortId(entry.jobId))
    return teleportEntry(entry, "join")
end

-- FORCE JOIN is a direct Roblox teleport attempt after the user confirms it on
-- the card. It skips only our optional claim preflight; it cannot bypass a full
-- server, Roblox access restrictions, or any game/security check.
local function requestForceJoin(entry, confirmed)
    if confirmed ~= true then
        NYX.note("FORCE BLOCKED", "confirmation required")
        notify("FORCE requires the confirmation dialog", 6)
        return false
    end
    local shapeOk, shapeWhy = jobShape(entry.jobId)
    if not shapeOk then
        NYX.note("FORCE BLOCKED", tostring(shapeWhy))
        notify("cannot FORCE: " .. tostring(shapeWhy), 6)
        return false
    end
    if not validPlaceId(entry.placeId) then
        NYX.note("FORCE BLOCKED", "report has no valid PlaceId")
        notify("cannot FORCE: report has no valid PlaceId", 6)
        return false
    end
    local state = STATUS.of(entry, NYX.now())
    if state == "taken" or state == "full" or state == "expired" then
        NYX.note("FORCE BLOCKED", "confirmed " .. string.upper(state))
        notify("FORCE is unavailable for confirmed " .. string.upper(state), 7)
        return false
    end
    NYX.note("FORCE", "manual direct teleport requested for " .. shortId(entry.jobId))
    return teleportEntry(entry, "force")
end

openForceConfirm = function(entry, automaticPrompt)
    if not entry or not actionAllowed(entry) then
        notify("FORCE is not available for this report", 5)
        return false
    end
    UI.forceEntry = entry
    UI.forceBody.Text = table.concat({
        "Directly request a Roblox teleport to " .. shortId(entry.jobId) .. ".",
        "This skips only M0x46's optional NYX or own-backend preflight.",
        "It cannot bypass a full server, private access, security restrictions, or Roblox checks.",
        automaticPrompt and "AUTO-FORCE found a JOINABLE report; your manual confirmation is still required." or "Confirm only if you want to try this server now.",
    }, "\n\n")
    UI.forceModal.Visible = true
    return true
end

local function currentFeedEntry(entry)
    if not entry then return nil end
    for _, fresh in ipairs(STATE.feed or {}) do
        if fresh.source == entry.source and fresh.uid == entry.uid and fresh.jobId == entry.jobId then
            return fresh
        end
    end
    return nil
end

UI.forceCancel.MouseButton1Click:Connect(function()
    UI.forceEntry, UI.forceModal.Visible = nil, false
    notify("FORCE cancelled", 3)
end)
UI.forceConfirm.MouseButton1Click:Connect(function()
    local entry = currentFeedEntry(UI.forceEntry)
    UI.forceEntry, UI.forceModal.Visible = nil, false
    if not entry then
        NYX.note("FORCE BLOCKED", "report left the fresh feed")
        notify("FORCE cancelled: that report is no longer in the fresh feed", 6)
        return
    end
    requestForceJoin(entry, true)
end)

--==============================================================================
-- POOLED LIVE-FEED CARDS
-- Each card is built once and rebound on refresh. This avoids GUI churn on Delta
-- while preserving real report metadata, source provenance and status evidence.
--==============================================================================
local cardPool, pendingActions = {}, {}

function STATUS.text(entry)
    local state = STATUS.of(entry, NYX.now())
    if state == "joinable" then return "JOINABLE" end
    if state == "taken" then return "TAKEN" end
    if state == "full" then return "FULL" end
    if state == "expired" then return "EXPIRED" end
    if entry and entry.claimStatus == "unavailable" then return "UNAVAILABLE" end
    return "UNKNOWN"
end

function STATUS.color(entry)
    local state = STATUS.of(entry, NYX.now())
    if state == "joinable" then return THEME.green end
    if state == "taken" then return THEME.redHot end
    if state == "full" then return THEME.amber end
    if state == "expired" then return THEME.gray end
    return THEME.blue
end

actionAllowed = function(entry)
    local state = STATUS.of(entry, NYX.now())
    if state ~= "joinable" and state ~= "unknown" then return false end
    if entry.claimStatus == "expired" or entry.claimStatus == "unavailable" then return false end
    local shape = jobShape(entry.jobId)
    return shape and validJobId(entry.jobId) and validPlaceId(entry.placeId)
end

function NYX.note(kind, message)
    local rows = STATE.history
    table.insert(rows, 1, { at = os.time(), kind = tostring(kind or "INFO"), text = tostring(message or "") })
    while #rows > 40 do table.remove(rows) end
end

local function reportAge(entry)
    local seen = tonumber(entry and entry.seenAt)
    if not seen or seen <= 0 then return "age ?" end
    local seconds = math.max(0, math.floor((NYX.now() - seen) / 1000))
    if seconds < 60 then return seconds .. "s ago" end
    return math.floor(seconds / 60) .. "m ago"
end

local function createCard(index)
    local root = make("Frame", {
        Name = "Card" .. index, Size = UDim2.new(1, -4, 0, UI.cardHeight()),
        BackgroundColor3 = CARD_BG, BackgroundTransparency = 0.02, BorderSizePixel = 0,
        ClipsDescendants = true, ZIndex = 14,
    }, UI.list)
    corner(8, root)
    local outline = stroke(root, THEME.line, 1, 0.25)
    local strip = make("Frame", { Name = "StatusStrip", Position = UDim2.fromOffset(0, 5), Size = UDim2.new(0, 3, 1, -10), BackgroundColor3 = THEME.red, BorderSizePixel = 0, ZIndex = 15 }, root)
    corner(2, strip)
    local iconBack = make("Frame", { Name = "IconBack", BackgroundColor3 = THEME.panelHigh, BorderSizePixel = 0, ZIndex = 15 }, root)
    corner(7, iconBack)
    local icon = make("ImageLabel", { Name = "EggIcon", BackgroundTransparency = 1, Image = "", ScaleType = Enum.ScaleType.Fit, ZIndex = 16 }, iconBack)
    local glyph = label(iconBack, "◉", UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), THEME.redHot, 18)
    glyph.Name = "EggGlyph"
    glyph.TextSize = 10
    glyph.TextXAlignment = Enum.TextXAlignment.Center
    glyph.TextYAlignment = Enum.TextYAlignment.Center
    glyph.ZIndex = 16
    local name = label(root, "", UDim2.new(), UDim2.new(), THEME.text, 14)
    name.Name = "EggName"; name.Font = Enum.Font.GothamBlack; name.ZIndex = 16
    local income = label(root, "", UDim2.new(), UDim2.new(), THEME.green, 13)
    income.Name = "Income"; income.Font = Enum.Font.GothamBlack; income.ZIndex = 16
    local rarity = label(root, "", UDim2.new(), UDim2.new(), THEME.muted, 9)
    rarity.Name = "Rarity"; rarity.ZIndex = 16
    local server = label(root, "", UDim2.new(), UDim2.new(), THEME.muted, 9)
    server.Name = "Area"; server.ZIndex = 16
    local age = label(root, "", UDim2.new(), UDim2.new(), THEME.muted, 9)
    age.Name = "ReportAge"; age.TextXAlignment = Enum.TextXAlignment.Right; age.ZIndex = 16
    local status = label(root, "", UDim2.new(), UDim2.new(), THEME.blue, 9)
    status.Name = "JoinStatus"; status.TextXAlignment = Enum.TextXAlignment.Center; status.ZIndex = 16
    local join = button(root, { Name = "JoinButton", Text = "JOIN", CornerRadius = 7, ZIndex = 17 }, true)
    local force = button(root, { Name = "ForceButton", Text = "FORCE", CornerRadius = 7, ZIndex = 17 }, false)
    local slot = { root = root, outline = outline, strip = strip, iconBack = iconBack, icon = icon, glyph = glyph, name = name, income = income, rarity = rarity, server = server, age = age, status = status, join = join, force = force, entry = nil, pending = nil }
    join.MouseButton1Click:Connect(function()
        local entry = slot.entry
        if not entry or not actionAllowed(entry) then return end
        if CONFIG.AUTO_JOIN then requestJoin(entry); return end
        if slot.pending == "join" and os.clock() < (slot.pendingUntil or 0) then
            slot.pending = nil; requestJoin(entry); return
        end
        slot.pending, slot.pendingUntil = "join", os.clock() + 5
        join.Text = "SURE?"
        notify("tap JOIN again to preflight " .. shortId(entry.jobId), 5)
    end)
    force.MouseButton1Click:Connect(function()
        local entry = slot.entry
        if not entry or not actionAllowed(entry) then return end
        openForceConfirm(entry, false)
    end)
    cardPool[index] = slot
    pendingActions[#pendingActions + 1] = slot
    return slot
end

local function clearList()
    -- Detach pooled controls rather than destroy them. This avoids hidden pool
    -- slots contributing blank space to UIListLayout/AutomaticCanvasSize.
    for _, slot in ipairs(cardPool) do
        slot.root.Visible = false
        slot.root.Parent = nil
        slot.entry, slot.pending = nil, nil
    end
    if UI.infoCard then
        UI.infoCard.root.Visible = false
        UI.infoCard.root.Parent = nil
    end
end

local function bindCard(slot, entry, index)
    if slot.root.Parent ~= UI.list then slot.root.Parent = UI.list end
    local h = UI.cardHeight()
    local narrow = (UI.contentW or 400) < 310
    local state, color, spec = STATUS.of(entry, NYX.now()), STATUS.color(entry), raritySpec(entry)
    local action = actionAllowed(entry) and not entry.isLocal
    local right = narrow and 66 or (action and 136 or 90)
    local left = narrow and 47 or 58
    slot.root.Visible = true; slot.root.LayoutOrder = index
    slot.root.Size = UDim2.new(1, -6, 0, h)
    slot.root.BackgroundColor3 = state == "taken" and Color3.fromRGB(25, 10, 14) or CARD_BG
    slot.outline.Color, slot.outline.Transparency = THEME.red, 0.65
    slot.strip.BackgroundColor3 = color
    box(slot.iconBack, 10, narrow and 23 or 18, narrow and 28 or 34, narrow and 28 or 34)
    slot.icon.Size = UDim2.fromScale(1, 1)
    slot.icon.Image = entry.icon or ""; slot.icon.Visible = entry.icon ~= nil
    slot.glyph.Visible = entry.icon == nil; slot.glyph.TextColor3 = spec.color; slot.glyph.TextSize = 22
    slot.name.Text = tostring(entry.name or "Unknown")
    slot.name.TextColor3 = THEME.text
    box(slot.name, left, 8, (UI.contentW or 400) - left - right - 4, 17)
    slot.name.TextSize = narrow and 11 or 13
    slot.income.Text = money(entry.rate)
    box(slot.income, left, 28, (UI.contentW or 400) - left - right - 4, 17)
    slot.income.TextSize = narrow and 11 or 12
    slot.rarity.Text = tostring(entry.rarity or "Unknown") .. ((entry.mutations and #entry.mutations > 0) and (" • " .. table.concat(entry.mutations, ", ")) or "")
    slot.rarity.TextColor3 = spec.color
    box(slot.rarity, left, 48, (UI.contentW or 400) - left - right - 4, 12)
    slot.rarity.TextSize = 9
    slot.server.Text = (entry.isLocal and "THIS SERVER" or shortId(entry.jobId)) .. (entry.area and (" • " .. tostring(entry.area)) or "")
    slot.server.TextSize = 9
    box(slot.server, left, narrow and 66 or 61, (UI.contentW or 400) - left - right - 4, 12)
    slot.age.Text = reportAge(entry)
    slot.age.Visible = not narrow
    box(slot.age, (UI.contentW or 400) - right, 58, right - 14, 12)
    slot.age.TextSize = 9
    slot.status.Text = entry.isLocal and "HERE" or STATUS.text(entry)
    slot.status.TextColor3 = entry.isLocal and THEME.muted or color
    box(slot.status, (UI.contentW or 400) - right, 8, right - 14, 14)
    slot.status.TextSize = 9
    slot.join.Visible, slot.force.Visible = action, action
    if narrow then
        box(slot.join, (UI.contentW or 400) - 63, 29, 49, 22)
        box(slot.force, (UI.contentW or 400) - 63, 56, 49, 22)
    else
        box(slot.join, (UI.contentW or 400) - 136, 28, 58, 24)
        box(slot.force, (UI.contentW or 400) - 72, 28, 58, 24)
    end
    slot.join.Text, slot.force.Text = slot.pending == "join" and "SURE?" or "JOIN", "FORCE"
    slot.join.TextSize, slot.force.TextSize = 10, 10
    slot.entry = entry
end

function UI.reflowCards()
    for index, slot in ipairs(cardPool) do
        if slot.entry and slot.root.Parent == UI.list then bindCard(slot, slot.entry, index) end
    end
end

local function makeCard(entry, index)
    return bindCard(cardPool[index] or createCard(index), entry, index)
end

local function showInfo(titleText, bodyText)
    if not UI.infoCard then
        local root = make("Frame", { Name = "InfoPanel", Size = UDim2.new(1, -4, 0, 130), BackgroundColor3 = CARD_BG, BorderSizePixel = 0, LayoutOrder = 1, ZIndex = 14 }, UI.list)
        corner(8, root); stroke(root, THEME.line, 1, 0.3)
        local head = label(root, "", UDim2.fromOffset(12, 10), UDim2.new(1, -24, 0, 20), THEME.text, 14)
        head.Font = Enum.Font.GothamBlack; head.Name = "InfoTitle"; head.ZIndex = 15
        local body = label(root, "", UDim2.fromOffset(12, 35), UDim2.new(1, -24, 1, -45), THEME.muted, 10)
        body.Name = "EmptyText"; body.TextWrapped = true; body.TextYAlignment = Enum.TextYAlignment.Top; body.ZIndex = 15
        UI.infoCard = { root = root, head = head, body = body }
    end
    if UI.infoCard.root.Parent ~= UI.list then UI.infoCard.root.Parent = UI.list end
    UI.infoCard.root.Visible = true
    UI.infoCard.root.LayoutOrder = 1
    UI.infoCard.head.Text, UI.infoCard.body.Text = titleText, bodyText
end


--==============================================================================
-- EMPTY STATES  (always accurate, never invented data)
--==============================================================================
local function emptyMessage()
    if STATE.tab == "local" then
        if STATE.scanned == 0 then
            return "No field eggs detected in this server.\n\n"
                .. (CAPS.moduleApi
                    and "The game module is loaded but returned nothing — eggs may not have spawned yet."
                    or "Fallback attribute scan found nothing. If eggs are visible in game, check the workspace folder names.")
        end
        local matched = 0
        for _, entry in ipairs(STATE.raw) do if passesFilter(entry) then matched = matched + 1 end end
        if matched == 0 then
            return string.format(
                "%d egg(s) detected, 0 match your filters.\nFilter: %s+ rarity, %s minimum.\nLower the minimum income or tap RARITY.",
                STATE.scanned, rarityName(STATE.minRank), moneyFilter(STATE.minRate)
            )
        end
        return "No eggs to show."
    end

    if not CAPS.network then
        return "No HTTP in this executor.\nALL SERVERS is disabled — NYX and your fallback cannot be reached."
    end
    if STATE.feedBusy and not STATE.feedLoaded then
        return CONFIG.NYX.ENABLED and "Contacting NYX and your fallback…" or "Contacting your backend…"
    end
    if STATE.feedError then
        local nyxWhy = STATE.feedErrors and STATE.feedErrors.nyx
        local ownWhy = STATE.feedErrors and STATE.feedErrors.own
        local lines = { "ALL SERVERS unavailable." }
        if CONFIG.NYX.ENABLED then
            lines[#lines + 1] = "NYX: " .. tostring(describeError(nyxWhy or STATE.feedError))
            lines[#lines + 1] = "NYX endpoint: " .. tostring(NYX.endpoint or CONFIG.NYX.CONFIG_URL)
        end
        if CONFIG.NYX.FALLBACK ~= false then
            lines[#lines + 1] = "Own fallback: " .. tostring(describeError(ownWhy or STATE.feedError))
            lines[#lines + 1] = "Own endpoint: " .. tostring(rawEndpoint())
        end
        if DIAG.problem then lines[#lines + 1] = "Backend note: " .. tostring(DIAG.problem) end
        lines[#lines + 1] = "Tap REFRESH after fixing the unavailable source."
        return table.concat(lines, "\n")
    end
    if not STATE.feedLoaded then
        return "No shared-feed data yet.\nTap REFRESH to load NYX or your fallback."
    end
    if #STATE.feed == 0 then
        if STATE.feedSource == "nyx" then
            local ownNote = STATE.feedErrors and STATE.feedErrors.own
            return "NYX is connected but reports 0 currently valid eggs ≥ " .. moneyFilter(STATE.minRate) .. ".\n\n"
                .. "That network only lists eggs other players' clients have scanned in the\n"
                .. "last " .. tostring(NYX.ttlSeconds) .. " s. Nothing is invented locally."
                .. (ownNote and ("\n\nOwn fallback: " .. tostring(describeError(ownNote))) or "")
        end
        return "No reports from OTHER servers yet.\n\n"
            .. "Your own server is hidden on this tab by design (REMOTE_ONLY = true).\n"
            .. "Other servers appear here only when a client running M0x46 there has\n"
            .. "BROADCAST on and has scanned eggs above the income floor.\n"
            .. "Backend currently holds " .. tostring(STATE.feedTotal) .. " sighting(s). Nothing is simulated."
    end
    local matched = STATE.feedMatched
    if matched == 0 then
        return string.format(
            "%d egg(s) from %d other server(s), 0 match your filters.\nFilter: %s+ rarity, %s minimum.",
            #STATE.feed, STATE.remoteServers, rarityName(STATE.minRank), moneyFilter(STATE.minRate)
        )
    end
    return "No eggs to show."
end

--==============================================================================
-- RENDER
--==============================================================================
local function historyBody()
    if #STATE.history == 0 then return "No local M0x46 events yet.\n\nRefresh the live feed, use JOIN, or inspect a source error to populate this session history." end
    local rows = {}
    for index = 1, math.min(#STATE.history, 12) do
        local event = STATE.history[index]
        rows[#rows + 1] = string.format("[%s] %s", tostring(event.kind), tostring(event.text))
    end
    return table.concat(rows, "\n")
end

local function usersBody()
    return table.concat({
        "NYX servers: " .. tostring(NYX.servers),
        "NYX participants: " .. tostring(NYX.participants),
        "Remote servers in this feed: " .. tostring(STATE.remoteServers),
        "Source: " .. tostring(STATE.feedSource or "none"),
        "Pages read: " .. tostring(STATE.feedPages or 0),
        "TTL: " .. tostring(NYX.ttlSeconds) .. "s",
        "Current JobId remains excluded: " .. shortId(game.JobId),
    }, "\n")
end

local function render()
    clearList()
    if STATE.view == "history" then
        showInfo("SESSION HISTORY", historyBody())
        return
    end
    if STATE.view == "users" then
        showInfo("NYX NETWORK", usersBody())
        return
    end
    local shown, matched = visibleList()
    UI.totalLabel.Text = tostring(#shown) .. " shown"
    if STATE.tab == "all" then
        STATE.feedMatched = matched
        STATE.statusCounts = STATUS.count(STATE.feed, NYX.now())
    end
    if UI.paintCounts then UI.paintCounts() end
    if #shown == 0 then
        showInfo(STATE.tab == "all" and "LIVE FEED" or "MY SERVER", emptyMessage())
        if UI.infoCard then UI.infoCard.root.Name = "EmptyState" end
        return
    end
    for index = 1, #shown do makeCard(shown[index], index) end
end

local function renderIfDirty()
    if not UI.panel.Visible or not STATE.dirty then return end
    STATE.dirty = false
    render()
end

--==============================================================================
-- SCAN / FEED ACTIONS
--==============================================================================
local function ingestScan()
    local ok, entries = pcall(scanOnce)
    if not ok or type(entries) ~= "table" then
        STATE.status = "scan error: " .. tostring(entries)
        return false
    end
    -- keep the previous list if the game returned nothing this tick: a momentary
    -- empty snapshot should not blank the panel and look like a bug
    if #entries == 0 and #STATE.raw > 0 and (os.clock() - STATE.rawAt) < 3 then
        return false
    end
    STATE.raw = entries
    STATE.scanned = #entries
    STATE.rawAt = os.clock()
    local matched = 0
    for _, entry in ipairs(entries) do if passesFilter(entry) then matched = matched + 1 end end
    STATE.status = string.format("%d egg(s) • %d shown • %s", #entries, matched,
        CAPS.moduleApi and "module api" or "attribute scan")
    markDirty()
    pcall(function()
        UI.gui:SetAttribute("M0x46Count", matched)
        UI.gui:SetAttribute("M0x46Raw", #entries)
        UI.gui:SetAttribute("M0x46Status", STATE.status)
        UI.gui:SetAttribute("M0x46Source", CAPS.moduleApi and "module" or "attributes")
    end)
    markDirty()
    return true
end

-- Fresh reports replace stale duplicate data by report time, never by the
-- client's former claimStatus. If timestamps tie/missing, explicit feed state
-- evidence wins over absent fields; only then does income break the tie.
local function freshMillis(entry)
    return tonumber(entry and entry.seenAt) or 0
end

local function hasStateEvidence(entry)
    return entry and (entry.hasTakenFlag or entry.hasFullFlag or entry.hasUnavailableFlag) or false
end

local function shouldReplaceFresh(existing, incoming)
    local oldAt, newAt = freshMillis(existing), freshMillis(incoming)
    if newAt ~= oldAt then return newAt > oldAt end
    local oldEvidence, newEvidence = hasStateEvidence(existing), hasStateEvidence(incoming)
    if oldEvidence ~= newEvidence then return newEvidence end
    -- For tied feed records, the later payload is treated as the authoritative
    -- update; a lower rate is not a reason to retain a stale TAKEN/FULL state.
    return true
end

local function copyFresh(existing, incoming)
    for field, value in pairs(incoming) do existing[field] = value end
    -- fresh server data intentionally clears only transient local claim marks
    -- that could otherwise pin a card to a previous failed attempt.
    existing.claimStatus, existing.claimDetail = nil, nil
end

local function ingestFeed()
    if STATE.feedBusy then return false end
    if not CAPS.network then
        STATE.feedError = "HTTP unavailable"
        STATE.networkOnline = false
        STATE.feedLoaded = true
        markDirty()
        return false
    end
    STATE.feedBusy = true

    -- Source 1: the shared NYX network (cross-server, other people's reports).
    -- Source 2: your own backend, only if NYX is unavailable or empty.
    local seen, list = {}, {}
    local remote = {}
    local total, remoteTotal = 0, 0
    local source, sourceError = nil, nil
    local expiredRows = 0

    local function harvest(data)
        local added = 0
        for _, raw in ipairs(data.items or {}) do
            local entry = normalizeFeedItem(raw, "nyx")
            if entry then
                local isHere = entry.jobId == game.JobId
                local state = STATUS.of(entry, NYX.now())
                -- Expired reports are never rendered or claimed. Confirmed FULL
                -- and TAKEN stay visible as evidence; UNKNOWN never becomes TAKEN.
                if state == "expired" then
                    expiredRows = expiredRows + 1
                elseif not (CONFIG.REMOTE_ONLY and isHere) then
                    local key = tostring(entry.uid) .. "|" .. tostring(entry.jobId)
                    local existing = seen[key]
                    if not existing then
                        seen[key] = entry
                        list[#list + 1] = entry
                        added = added + 1
                    elseif shouldReplaceFresh(existing, entry) then
                        -- `list` holds the first table, so update it in place;
                        -- fresh status evidence must not be left on a stale card.
                        copyFresh(existing, entry)
                    end
                    if type(entry.jobId) == "string" then remote[entry.jobId] = true end
                end
            end
        end
        return added
    end

    if CONFIG.NYX.ENABLED then
        local offset, pageIndex, lastError = 0, 0, nil
        local normalPages = math.max(1, tonumber(CONFIG.NYX.PAGES) or 1)
        local maxPages = math.max(normalPages, tonumber(CONFIG.NYX.MAX_PAGES) or normalPages)
        while pageIndex < maxPages do
            local data, err = NYX.fetchPage(offset)
            if not data then lastError = err break end
            pageIndex = pageIndex + 1
            harvest(data)
            total = math.max(total, tonumber(data.total) or 0)
            local following = tonumber(data.nextOffset)
            if #(data.items or {}) == 0 or not following or following <= offset then break end
            -- Always read the normal budget. After that, continue only if every
            -- seen row is FULL/TAKEN/expired; this prevents the ALL-TAKEN first
            -- pages from hiding a later joinable report without unbounded polling.
            if pageIndex >= normalPages and (not CONFIG.NYX.EXPAND_UNAVAILABLE or NYX.hasActionable(list)) then break end
            offset = following
        end
        STATE.feedPages = pageIndex
        if pageIndex > 0 then
            source = "nyx"
            if lastError then sourceError = tostring(lastError) end
        else
            sourceError = tostring(lastError or "NYX unavailable")
        end
    end

    if #list > 0 then
        STATE.feedErrors = { nyx = sourceError }
        STATE.feedSource = source
        STATE.feedBusy = false
        -- Never infer availability from a missing field: this status order puts
        -- proven JOINABLE reports first, then UNKNOWN, then FULL and TAKEN.
        table.sort(list, function(a, b)
            local ar, br = STATUS.rank(a, NYX.now()), STATUS.rank(b, NYX.now())
            if ar ~= br then return ar < br end
            return sortByValue(a, b)
        end)
        local cap = math.max(tonumber(CONFIG.FEED_LIMIT) or 40, 40)
        while #list > cap do table.remove(list) end
        STATE.feed = list
        STATE.remoteServers = 0
        for _ in pairs(remote) do STATE.remoteServers = STATE.remoteServers + 1 end
        STATE.feedTotal = math.max(total, #list)
        STATE.feedError = nil
        STATE.feedLoaded = true
        STATE.feedAt = os.clock()
        STATE.feedExpired = expiredRows
        STATE.statusCounts = STATUS.count(list, NYX.now())
        STATE.feedMatched = STATE.statusCounts.joinable + STATE.statusCounts.taken
            + STATE.statusCounts.full + STATE.statusCounts.unknown
        STATE.networkOnline = true
        local more = STATE.feedTotal > #list and string.format(" · %d total", STATE.feedTotal) or ""
        STATE.status = string.format("%d live%s · %d server(s) · NYX · J%d T%d F%d U%d",
            #list, more, STATE.remoteServers, STATE.statusCounts.joinable,
            STATE.statusCounts.taken, STATE.statusCounts.full, STATE.statusCounts.unknown)
        markDirty()
        return true
    end

    -- A NYX-only install may opt out of the own backend entirely.  Do not turn
    -- a genuine empty NYX response into an "unavailable" error just because the
    -- optional fallback was deliberately disabled.
    if CONFIG.NYX.ENABLED and not CONFIG.NYX.FALLBACK then
        STATE.feedBusy = false
        STATE.feed = {}
        STATE.feedTotal = total
        STATE.remoteServers = 0
        STATE.feedLoaded = true
        STATE.feedAt = os.clock()
        STATE.feedMatched = 0
        STATE.feedExpired = expiredRows
        STATE.statusCounts = { joinable = 0, taken = 0, full = 0, unknown = 0, expired = expiredRows }
        STATE.networkOnline = source == "nyx" and not sourceError
        STATE.feedErrors = { nyx = sourceError }
        if source == "nyx" and not sourceError then
            STATE.feedSource = "nyx"
            STATE.feedError = nil
            STATE.status = string.format("NYX: 0 live ≥%s · fallback off", moneyFilter(STATE.minRate))
            markDirty()
            return true
        end
        STATE.feedSource = nil
        STATE.feedError = sourceError or "NYX unavailable"
        markDirty()
        return false
    end

    -- ---- fallback: your own backend (or NYX disabled) ----------------------
    STATE.feedBusy = true

    -- Paged fetch. Every page is filtered server-side by excludeJob, so a page
    -- can never be filled with rows from the server the player is standing in.
    local pages = math.max(1, tonumber(CONFIG.FEED_PAGES) or 1)
    local offset, pageIndex = 0, 0
    local seen, list = {}, {}
    local remote = {}
    local total, remoteTotal = 0, 0
    local lastError
    local fallbackExpired = 0

    while pageIndex < pages do
        local data, err = fetchFeed(offset)
        if not data or type(data.items) ~= "table" then
            lastError = err or "invalid response"
            break
        end
        pageIndex = pageIndex + 1
        total = tonumber(data.total) or total
        if tonumber(data.remoteServers) then remoteTotal = tonumber(data.remoteServers) end

        for _, raw in ipairs(data.items) do
            local entry = normalizeFeedItem(raw, "own")
            if entry then
                local isHere = entry.jobId == game.JobId
                local state = STATUS.of(entry, STATUS.now())
                -- defence in depth: even if the backend ignores excludeJob, our
                -- own server must never appear under ALL SERVERS
                if state == "expired" then
                    fallbackExpired = fallbackExpired + 1
                elseif not (CONFIG.REMOTE_ONLY and isHere) then
                    local key = tostring(entry.uid) .. "|" .. tostring(entry.jobId)
                    local existing = seen[key]
                    if not existing then
                        seen[key] = entry
                        list[#list + 1] = entry
                    elseif shouldReplaceFresh(existing, entry) then
                        -- `list` holds the first table, so update it in place;
                        -- fresh status evidence must not be left on a stale card.
                        copyFresh(existing, entry)
                    end
                    if type(entry.jobId) == "string" then remote[entry.jobId] = true end
                end
            end
        end

        local following = tonumber(data.nextOffset)
        if #data.items == 0 or not following or following <= offset then break end
        offset = following
    end

    STATE.feedBusy = false
    if pageIndex == 0 and not (source == "nyx" and not sourceError) then
        -- Both sources failed: keep the NYX reason, it is the interesting one.
        STATE.feedErrors = { nyx = sourceError, own = lastError }
        STATE.feedSource = nil
        STATE.networkOnline = false
        STATE.feedError = sourceError or lastError or "invalid response"
        STATE.feedLoaded = true
        markDirty()
        return false
    end

    table.sort(list, function(a, b)
        local ar, br = STATUS.rank(a), STATUS.rank(b)
        if ar ~= br then return ar < br end
        return sortByValue(a, b)
    end)
    STATE.feed = list
    STATE.feedTotal = total > 0 and total or #list
    STATE.remoteServers = 0
    for _ in pairs(remote) do STATE.remoteServers = STATE.remoteServers + 1 end
    if remoteTotal > 0 then STATE.remoteServers = remoteTotal end
    STATE.feedError = nil
    STATE.feedLoaded = true
    STATE.feedAt = os.clock()
    STATE.feedExpired = fallbackExpired
    STATE.statusCounts = STATUS.count(list, STATUS.now())
    STATE.feedMatched = STATE.statusCounts.joinable + STATE.statusCounts.taken
        + STATE.statusCounts.full + STATE.statusCounts.unknown
    STATE.networkOnline = pageIndex > 0
    STATE.feedErrors = { nyx = sourceError, own = lastError }
    if #list == 0 and source == "nyx" and not sourceError then
        -- NYX answered, but neither feed has a currently valid remote egg. Keep
        -- the true source so the empty state says NYX is connected, not that a
        -- local scan somehow found cross-server sightings.
        STATE.feedSource = "nyx"
        STATE.status = string.format("NYX: 0 live ≥%s · fallback empty", moneyFilter(STATE.minRate))
    else
        STATE.feedSource = "own"
        STATE.status = string.format("own backend: %d egg(s) · %d server(s) (NYX %s)",
            #list, STATE.remoteServers,
            CONFIG.NYX.ENABLED and (sourceError and "unavailable" or "empty") or "off")
    end
    markDirty()
    return true
end

local feedInFlight = false
local function refreshFeed()
    if feedInFlight then return end
    feedInFlight = true
    STATE.feedLoading = true
    notify(CONFIG.NYX.ENABLED and "asking NYX…" or "asking backend…", 2)
    task.spawn(function()
        ingestFeed()
        feedInFlight = false
        STATE.feedLoading = false
        if STATE.tab == "all" then renderIfDirty() end
    end)
end

local function refreshLocal()
    ingestScan()
    renderIfDirty()
end

pcall(function()
    TeleportService.TeleportInitFailed:Connect(function(_, _, message)
        notify("teleport failed: " .. tostring(message), 8)
    end)
end)

--==============================================================================
-- UI BEHAVIOUR
--==============================================================================
local function paintTabs()
    UI.localTab.BackgroundColor3 = STATE.tab == "local" and THEME.redDeep or THEME.panelHigh
    UI.feedTab.BackgroundColor3 = STATE.tab == "all" and THEME.redDeep or THEME.panelHigh
    UI.localTab.TextColor3, UI.feedTab.TextColor3 = THEME.text, THEME.text
end

local function paintSidebar()
    local active = { logs = UI.logsButton, history = UI.historyButton, users = UI.usersButton }
    for key, control in pairs(active) do
        local on = STATE.view == key
        control.BackgroundColor3 = on and THEME.redDeep or THEME.panelHigh
        control.TextColor3 = on and THEME.text or THEME.muted
    end
end

function UI.paintCounts()
    local c = STATE.statusCounts or {}
    local small = (UI.contentW or 400) < 310
    UI.countJoin.Text = (small and "JOIN " or "JOINABLE ") .. tostring(c.joinable or 0)
    UI.countTaken.Text = "TAKEN " .. tostring(c.taken or 0)
    UI.countFull.Text = "FULL " .. tostring(c.full or 0)
    UI.countUnknown.Text = (small and "UNK " or "UNKNOWN ") .. tostring(c.unknown or 0)
end
local function paintBroadcast()
    UI.broadcastToggle.Text = CONFIG.BROADCAST and "BROADCAST: ON" or "BROADCAST: OFF"
    UI.broadcastToggle.BackgroundColor3 = CONFIG.BROADCAST and Color3.fromRGB(22, 94, 48) or THEME.redDeep
end

local function paintAutos()
    for control, part in pairs(switchParts) do
        local on = (control == UI.autoJoinToggle and CONFIG.AUTO_JOIN) or (control == UI.autoForceToggle and CONFIG.AUTO_FORCE)
        local tiny = control.Size.X.Offset < 130
        control.Text = control == UI.autoJoinToggle and (tiny and "A-JOIN" or "Auto-Join") or (tiny and "A-FORCE" or "Auto-Force")
        part.track.BackgroundColor3 = on and THEME.red or THEME.line
        local w, h = part.track.Size.X.Offset, part.track.Size.Y.Offset
        part.thumb.Position = UDim2.fromOffset(on and w - h + 3 or 3, 3)
        control.BackgroundColor3 = on and THEME.redDeep or THEME.panelLow
    end
end

local function paintFilter()
    local spec = FILTERS[STATE.filterIndex]
    UI.filterButton.Text = "RARITY: " .. string.upper(spec.name)
    local rarity = RARITY_BY_NAME[spec.name:lower()]
    UI.filterButton.TextColor3 = rarity and rarity.color or THEME.muted
end

local function paintOverlayInfo()
    local counts = STATE.statusCounts or {}
    UI.infoRow.Text = table.concat({
        "NYX source: " .. tostring(STATE.feedSource or "not selected"),
        "NYX endpoint: " .. tostring(NYX.endpoint or "runtime config not read"),
        "NYX network: " .. tostring(NYX.servers) .. " server(s), " .. tostring(NYX.participants) .. " participant(s), ttl " .. tostring(NYX.ttlSeconds) .. "s",
        "NYX pages: " .. tostring(STATE.feedPages or 0) .. "  •  expired dropped: " .. tostring(STATE.feedExpired or 0),
        "Counts: JOINABLE " .. tostring(counts.joinable or 0) .. " | TAKEN " .. tostring(counts.taken or 0) .. " | FULL " .. tostring(counts.full or 0) .. " | UNKNOWN " .. tostring(counts.unknown or 0),
        "NYX error: " .. tostring(STATE.feedErrors and STATE.feedErrors.nyx or "none"),
        "Own fallback: " .. tostring(rawEndpoint()),
        "Own error: " .. tostring(STATE.feedErrors and STATE.feedErrors.own or "none"),
        "Current JobId excluded: " .. shortId(game.JobId),
        "Local scanner: " .. (CAPS.moduleApi and "game module" or "attribute fallback"),
        "Auth keys are never displayed. FORCE skips only this app's preflight; Roblox still decides access.",
        DIAG.problem and ("Backend note: " .. tostring(DIAG.problem)) or "",
    }, "\n")
end

local function applyFilters(reason)
    markDirty()
    local _, matched = visibleList()
    if reason then notify(string.format("%d shown (≥%s, %s+)", matched, moneyFilter(STATE.minRate), rarityName(STATE.minRank)), 3) end
    renderIfDirty()
    if STATE.tab == "all" then refreshFeed() end
end

local function setTab(key)
    STATE.tab = key
    STATE.view = "logs"
    paintTabs(); paintSidebar(); markDirty()
    if UI.panel.Visible then render() end
    if key == "all" then refreshFeed() else refreshLocal() end
end

local function setView(key)
    if key == "settings" then
        UI.overlay.Visible = not UI.overlay.Visible
        if UI.overlay.Visible then paintOverlayInfo() end
        return
    end
    STATE.view = key
    paintSidebar()
    markDirty()
    renderIfDirty()
end

-- income box: parse "1B", "250M", "0", "off", "1.5b"
local function parseIncome(text)
    local clean = string.lower(tostring(text or "")):gsub("%s", "")
    if clean == "" or clean == "off" or clean == "0" then return 0 end
    local amount, suffix = clean:match("^([%d%.]+)([kmbtq]?)")
    local value = tonumber(amount)
    if not value then return nil end
    return value * (({ k = 1e3, m = 1e6, b = 1e9, t = 1e12, q = 1e15 })[suffix] or 1)
end

local function applyIncomeBox(silent)
    local value = parseIncome(UI.rateBox.Text)
    if not value then
        UI.rateBox.Text = moneyFilter(STATE.minRate)
        notify("income must look like 1B, 250M or 0", 5)
        return
    end
    STATE.minRate = clamp(value, 0, 1e13)
    UI.rateBox.Text = moneyFilter(STATE.minRate)
    applyFilters(not silent)
end

-- Explicitly armed automation: AUTO-JOIN still requires a source preflight;
-- AUTO-FORCE is enabled only by a second arm tap and only targets JOINABLE rows.
local function attemptAuto()
    if not UI.panel.Visible or STATE.tab ~= "all" or (not CONFIG.AUTO_JOIN and not CONFIG.AUTO_FORCE) then return end
    if os.clock() < (STATE.autoNext or 0) then return end
    for _, entry in ipairs(STATE.feed or {}) do
        local key = tostring(entry.source) .. "|" .. tostring(entry.uid) .. "|" .. tostring(entry.jobId)
        if STATUS.of(entry, NYX.now()) == "joinable" and actionAllowed(entry) and not STATE.autoSeen[key] then
            STATE.autoSeen[key], STATE.autoNext = true, os.clock() + 5
            if CONFIG.AUTO_FORCE then
                NYX.note("AUTO-FORCE", "confirmation requested for " .. tostring(entry.name) .. " in " .. shortId(entry.jobId))
                openForceConfirm(entry, true)
            else
                NYX.note("AUTO-JOIN", "preflighting " .. tostring(entry.name) .. " in " .. shortId(entry.jobId))
                task.spawn(function() requestJoin(entry) end)
            end
            return
        end
    end
end

UI.logsButton.MouseButton1Click:Connect(function() setView("logs") end)
UI.historyButton.MouseButton1Click:Connect(function() setView("history") end)
UI.usersButton.MouseButton1Click:Connect(function() setView("users") end)
UI.settingsButton.MouseButton1Click:Connect(function() setView("settings") end)
UI.overlayClose.MouseButton1Click:Connect(function() UI.overlay.Visible = false end)
UI.localTab.MouseButton1Click:Connect(function() setTab("local") end)
UI.feedTab.MouseButton1Click:Connect(function() setTab("all") end)

UI.filterButton.MouseButton1Click:Connect(function()
    STATE.filterIndex = STATE.filterIndex % #FILTERS + 1
    STATE.minRank = FILTERS[STATE.filterIndex].rank
    paintFilter(); applyFilters(true)
end)
UI.refreshButton.MouseButton1Click:Connect(function()
    refreshLocal()
    if STATE.tab == "all" then refreshFeed() end
    notify("refresh requested", 3)
end)
UI.clearButton.MouseButton1Click:Connect(function()
    STATE.history = {}
    notify("session history cleared; live reports remain real", 3)
    if STATE.view == "history" then markDirty(); renderIfDirty() end
end)
UI.broadcastToggle.MouseButton1Click:Connect(function()
    CONFIG.BROADCAST = not CONFIG.BROADCAST
    paintBroadcast()
    notify(CONFIG.BROADCAST and "broadcast enabled" or "broadcast paused", 3)
end)
UI.autoJoinToggle.MouseButton1Click:Connect(function()
    CONFIG.AUTO_JOIN = not CONFIG.AUTO_JOIN
    if CONFIG.AUTO_JOIN then
        CONFIG.AUTO_FORCE = false
        STATE.autoSeen = {}
    end
    paintAutos()
    notify(CONFIG.AUTO_JOIN and "AUTO-JOIN armed: source preflight remains mandatory" or "AUTO-JOIN off", 5)
end)
UI.autoForceToggle.MouseButton1Click:Connect(function()
    if CONFIG.AUTO_FORCE then
        CONFIG.AUTO_FORCE = false
        paintAutos(); notify("AUTO-FORCE prompt mode off", 4); return
    end
    if os.clock() < (STATE.forceArmUntil or 0) then
        CONFIG.AUTO_FORCE, CONFIG.AUTO_JOIN, STATE.forceArmUntil = true, false, nil
        STATE.autoSeen = {}
        paintAutos(); notify("AUTO-FORCE prompt mode armed; every teleport still needs CONFIRM FORCE", 7)
    else
        STATE.forceArmUntil = os.clock() + 5
        UI.autoForceToggle.Text = "ARM FORCE?"
        notify("tap AUTO-FORCE again to arm prompt mode; it never bypasses confirmation", 5)
    end
end)
UI.rateBox.FocusLost:Connect(function() applyIncomeBox(false) end)
UI.rateBox:GetPropertyChangedSignal("Text"):Connect(function()
    if parseIncome(UI.rateBox.Text) ~= nil then
        STATE.minRate = clamp(parseIncome(UI.rateBox.Text), 0, 1e13)
        markDirty()
    end
end)
for _, preset in ipairs(UI.presetButtons) do
    preset.button.MouseButton1Click:Connect(function()
        STATE.minRate, UI.rateBox.Text = preset.value, moneyFilter(preset.value)
        applyFilters(true)
    end)
end

--==============================================================================
-- MINIMISE / REOPEN / CLOSE
--==============================================================================
local function openPanel()
    if UI.panel.Visible then return end
    UI.applyLayout()
    UI.panel.Visible, UI.launcher.Visible = true, false
    paintTabs(); paintSidebar(); UI.paintCounts(); render()
    if STATE.tab == "all" then refreshFeed() end
end

local function minimizePanel()
    if not UI.panel.Visible then return end
    UI.forceEntry, UI.forceModal.Visible = nil, false
    UI.panel.Visible, UI.launcher.Visible = false, true
end

local function closeScript()
    notify("M0x46 unloaded", 2)
    pcall(function() UI.gui:Destroy() end)
end

UI.launcher.MouseButton1Click:Connect(function()
    if suppressLauncher or (gesture and gesture.mode == "launcher" and gesture.moved) then suppressLauncher = false; return end
    if UI.panel.Visible then minimizePanel() else openPanel() end
end)
connect(UI.launcher.InputBegan, function(input)
    if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then suppressLauncher = false end
end)
UI.minusButton.MouseButton1Click:Connect(function() UI.resizeBy(1 / 1.1) end)
UI.plusButton.MouseButton1Click:Connect(function() UI.resizeBy(1.1) end)
UI.windowMinus.MouseButton1Click:Connect(function() UI.resizeBy(1 / 1.1) end)
UI.windowPlus.MouseButton1Click:Connect(function() UI.resizeBy(1.1) end)
UI.resetSizeButton.MouseButton1Click:Connect(UI.resetSize)
UI.hideButton.MouseButton1Click:Connect(minimizePanel)
UI.closeButton.MouseButton1Click:Connect(closeScript)
connect(UserInputService.InputBegan, function(input, processed)
    if processed or input.KeyCode ~= CONFIG.HOTKEY then return end
    if UI.panel.Visible then minimizePanel() else openPanel() end
end)

--==============================================================================
-- MAIN LOOP  (one lightweight scheduler; no RenderStepped loop)
--==============================================================================
local loop = { nextScan = 0, nextReport = 0, nextFeed = 0, lastBroadcast = nil }

local function updateStatusLine()
    if UI.overlay.Visible then paintOverlayInfo() end
    local line = STATE.status
    if STATE.notice and os.clock() < STATE.noticeUntil then line = STATE.notice end
    if STATE.feedError then
        UI.statusText.Text = "⚠ " .. tostring(describeError(STATE.feedError))
        UI.statusText.TextColor3 = THEME.amber
        UI.connectionDot.BackgroundColor3, UI.launcherDot.BackgroundColor3 = THEME.redHot, THEME.redHot
        UI.connectionLabel.Text, UI.connectionLabel.TextColor3 = "OFFLINE", THEME.redHot
    elseif STATE.networkOnline then
        UI.statusText.Text = tostring(line)
        UI.statusText.TextColor3 = THEME.green
        UI.connectionDot.BackgroundColor3, UI.launcherDot.BackgroundColor3 = THEME.green, THEME.green
        UI.connectionLabel.Text, UI.connectionLabel.TextColor3 = "CONNECTED", THEME.green
    else
        UI.statusText.Text = tostring(line)
        UI.statusText.TextColor3 = THEME.muted
        UI.connectionDot.BackgroundColor3, UI.launcherDot.BackgroundColor3 = THEME.amber, THEME.amber
        UI.connectionLabel.Text, UI.connectionLabel.TextColor3 = "CHECKING", THEME.amber
    end
    UI.paintCounts()
end

local function expirePendingActions()
    for _, slot in ipairs(pendingActions) do
        if slot.pending and os.clock() >= (slot.pendingUntil or 0) then
            slot.pending = nil
            markDirty()
        end
    end
    if STATE.forceArmUntil and os.clock() >= STATE.forceArmUntil then
        STATE.forceArmUntil = nil
        paintAutos()
    end
end

task.spawn(function()
    ingestScan()
    loop.nextScan, loop.nextFeed = os.clock() + CONFIG.SCAN_EVERY, os.clock()
    while UI.gui.Parent do
        local now = os.clock()
        local scanInterval = UI.panel.Visible and CONFIG.SCAN_EVERY or CONFIG.HIDDEN_SCAN_EVERY
        if now >= loop.nextScan then
            ingestScan()
            loop.nextScan = now + scanInterval
        end
        if CONFIG.BROADCAST and #STATE.raw > 0 and now >= loop.nextReport then
            local signature = tostring(#STATE.raw) .. ":" .. tostring(STATE.raw[1] and STATE.raw[1].uid)
            if signature ~= loop.lastBroadcast or now >= loop.nextReport + 10 then
                loop.lastBroadcast, loop.nextReport = signature, now + CONFIG.REPORT_EVERY
                local data, err = broadcast(STATE.raw)
                if data then
                    STATE.reportStatus = string.format("shared %d", tonumber(data.accepted) or 0)
                    pcall(function() UI.gui:SetAttribute("M0x46Reported", tonumber(data.accepted) or 0) end)
                elseif err and err ~= "busy" then
                    STATE.reportStatus = describeError(err)
                end
            else
                loop.nextReport = now + CONFIG.REPORT_EVERY
            end
        end
        -- Sensible refresh: NYX advertises a short TTL, but the UI only polls
        -- while visible and only once per 5 seconds (or the configured slower rate).
        if STATE.tab == "all" and UI.panel.Visible and now >= loop.nextFeed then
            loop.nextFeed = now + (CONFIG.NYX.ENABLED and math.min(CONFIG.FEED_EVERY, 5) or CONFIG.FEED_EVERY)
            if not feedInFlight then
                feedInFlight = true
                task.spawn(function()
                    ingestFeed()
                    feedInFlight = false
                end)
            end
        end
        attemptAuto()
        expirePendingActions()
        updateStatusLine()
        if UI.panel.Visible then renderIfDirty() end
        task.wait(CONFIG.UI_TICK)
    end
end)

UI.gui.Destroying:Connect(function()
    gesture = nil
    if cameraConnection then cameraConnection:Disconnect() end
    for _, connection in ipairs(connections) do connection:Disconnect() end
    for _, slot in ipairs(cardPool) do
        if slot.root.Parent == nil then slot.root:Destroy() end
    end
    if UI.infoCard and UI.infoCard.root.Parent == nil then UI.infoCard.root:Destroy() end
end)

--==============================================================================
-- BOOT
--==============================================================================
UI.resetSize()
bindCamera()
probeApiBase()
paintTabs()
paintSidebar()
paintBroadcast()
paintAutos()
paintFilter()
paintOverlayInfo()
UI.paintCounts()
UI.panelScale.Scale = 1
log("M0x46 Finder v2.4 loaded — hotkey", CONFIG.HOTKEY.Name,
    "| source:", CAPS.moduleApi and "module" or "attributes")

if not CAPS.network then
    log("WARNING: this executor exposes no HTTP function — ALL SERVERS is disabled")
elseif DIAG.problem then
    log("WARNING: " .. DIAG.problem)
end


-- Test/observer handle. Read-only mirror of the live state so an external harness
-- can assert on provenance (which feed answered) without scraping the UI.
-- The app never reads this back.
_G.M0x46_DIAG = setmetatable({}, {
    __index = function(_, key)
        if key == "source" then return STATE.feedSource end
        if key == "error" then return STATE.feedError end
        if key == "nyxError" then return NYX.error end
        if key == "nyxEndpoint" then return NYX.endpoint end
        if key == "nyxServers" then return NYX.servers end
        if key == "nyxParticipants" then return NYX.participants end
        if key == "rows" then return STATE.feed and #STATE.feed or 0 end
        if key == "counts" then return STATE.statusCounts end
        if key == "feedPages" then return STATE.feedPages end
        if key == "expiredRows" then return STATE.feedExpired end
        if key == "remoteServers" then return STATE.remoteServers end
        if key == "status" then return STATE.status end
        if key == "feedErrors" then return STATE.feedErrors end
        if key == "topRow" then return STATE.feed and STATE.feed[1] end
        if key == "takenRow" then
            for _, entry in ipairs(STATE.feed or {}) do
                if entry.taken == true or entry.full == true then return entry end
            end
            return nil
        end
        if key == "claim" then return NYX.claimRemote end
        -- Read-only simulation helpers used only by test_runtime.py. They do
        -- not trigger HTTP, claims, teleports, or expose room credentials.
        if key == "normalize" then return normalizeFeedItem end
        if key == "statusOf" then return STATUS.of end
        if key == "claimVerdict" then return NYX.claimVerdict end
        if key == "shouldReplaceFresh" then return shouldReplaceFresh end
        if key == "forceModal" then return UI.forceModal end
        return nil
    end,
})

