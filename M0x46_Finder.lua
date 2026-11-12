--[[
================================================================================
  M0x46 FINDER  ·  v2.3  ·  owner build
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
    ENDPOINT = "https://m0x46-xm0emjn7.back4.app", -- own backend, no trailing slash
    ROOM_KEY = "jeDFerngBqaQhS_W%b{ExA6-GI,W&:JI", -- must equal your backend ROOM_KEY

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
    AUTO_JOIN = false,                    -- false = JOIN asks "SURE?" first
    REMOTE_ONLY = true,                   -- ALL SERVERS hides your own server
    FEED_PAGES = 3,                       -- pages x FEED_LIMIT rows per refresh

    -- NYX shared feed (cross-server network, used with the owner's permission).
    -- No NYX endpoint or room key is stored here: both are read as runtime data
    -- from NYX's public config. Leave local overrides empty for a public repo.
    NYX = {
        ENABLED = true,
        CONFIG_URL = "https://raw.githubusercontent.com/syss1211/Tenshi-script/main/NYX-Finder-Config.json",
        ENDPOINT = "",          -- "" = take it from CONFIG_URL
        ROOM_KEY = "",          -- "" = take it from CONFIG_URL (never commit one)
        TIER = "public",
        PAGES = 2,              -- bounded nextOffset paging (NYX currently retains ~30 rows)
        FALLBACK = true,        -- fall back to your own backend when NYX is down
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
    tab = "local",
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

-- visible rows for the current tab. Never mutates STATE.raw / STATE.feed.
local function visibleList()
    local source = STATE.tab == "local" and STATE.raw or STATE.feed
    local matched = {}
    for _, entry in ipairs(source) do
        if passesFilter(entry) then matched[#matched + 1] = entry end
    end
    if STATE.tab == "all" then
        -- Put usable opportunities ahead of historical FULL/TAKEN reports.
        -- The latter remain visible (they are real), but cannot steal focus.
        table.sort(matched, function(a, b)
            local aDead = (a.taken == true or a.full == true) and 1 or 0
            local bDead = (b.taken == true or b.full == true) and 1 or 0
            if aDead ~= bDead then return aDead < bDead end
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
        seenAt = tonumber(item.seenAt),
        icon = type(item.icon) == "string" and item.icon:match("^rbxassetid://%d+$") and item.icon or nil,
        -- Transport provenance, not the reporter's own "source" field.  JOIN
        -- must claim against the network that actually served this row.
        source = feedSource or item.feedSource or "own",
        reportSource = item.source and tostring(item.source) or nil,
        -- remote-feed health flags (NYX publishes these and they matter for JOIN)
        full = item.full == true,
        taken = item.takenConfirmed == true,
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

-- Turn either network's claim payload into the one UI contract used by JOIN.
-- NYX deliberately uses HTTP 200 for a refusal, so `allowed` is authoritative.
function NYX.claimVerdict(data)
    if type(data) ~= "table" then return "the claim response was invalid" end
    if data.allowed == true then return "ok" end
    -- Explicit unavailability wins over a generic `ok` flag if a service sends
    -- both: never teleport on an already-known refusal.
    if data.unavailable or data.expired then
        return "expired or already claimed — tap REFRESH for a fresh list"
    end
    if data.takenConfirmed or data.taken then return "that egg was already taken" end
    if data.full then return "that server is full" end
    if data.ok == true and data.allowed == nil and not data.error and not data.reason then
        return "ok"
    end
    local reason = tostring(data.error or data.reason or "the network refused this join")
    local lower = reason:lower()
    if lower:find("full", 1, true) then return "that server is full" end
    if lower:find("expired", 1, true) or lower:find("taken", 1, true)
        or lower:find("claim", 1, true) or lower:find("unavailable", 1, true) then
        return "expired or already claimed — tap REFRESH for a fresh list"
    end
    return reason
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
-- THEME  (glass premium: deep purple, neon accents, soft bevels)
--==============================================================================
local THEME = {
    bg = Color3.fromRGB(10, 7, 22),
    bgDeep = Color3.fromRGB(5, 3, 14),
    glass = Color3.fromRGB(26, 18, 46),
    glassHigh = Color3.fromRGB(40, 28, 68),
    line = Color3.fromRGB(110, 80, 185),
    accent = Color3.fromRGB(147, 92, 255),
    accentHot = Color3.fromRGB(213, 96, 255),
    cyan = Color3.fromRGB(56, 205, 255),
    text = Color3.fromRGB(245, 240, 255),
    muted = Color3.fromRGB(176, 162, 210),
    green = Color3.fromRGB(96, 235, 150),
    red = Color3.fromRGB(238, 96, 106),
    amber = Color3.fromRGB(255, 202, 92),
    tabActive = Color3.fromRGB(96, 58, 170),
}
local CARD_BG = Color3.fromRGB(26, 18, 46)

local function make(class, props, parent)
    local object = Instance.new(class)
    for key, value in pairs(props or {}) do object[key] = value end
    object.Parent = parent
    return object
end

local function corner(radius, parent)
    return make("UICorner", { CornerRadius = UDim.new(0, radius) }, parent)
end

local function stroke(parent, color, thickness, transparency, gradientTo)
    local object = make("UIStroke", {
        Color = color or THEME.line, Thickness = thickness or 1,
        Transparency = transparency or 0.3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, parent)
    if gradientTo then
        make("UIGradient", { Rotation = 55, Color = ColorSequence.new(color, gradientTo) }, object)
    end
    return object
end

local function label(parent, text, position, size, color, textSize)
    return make("TextLabel", {
        Text = text, Position = position, Size = size, BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold, TextSize = textSize or 12,
        TextColor3 = color or THEME.text, TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, parent)
end

local function button(parent, props, accent)
    -- CornerRadius is a helper option, not a TextButton property.
    -- Applying it via make() would throw before the launcher could appear.
    local radius = props.CornerRadius or 8
    local buttonProps = {}
    for key, value in pairs(props or {}) do
        if key ~= "CornerRadius" then buttonProps[key] = value end
    end
    local object = make("TextButton", buttonProps, parent)
    corner(radius, object)
    object.BackgroundColor3 = accent and THEME.accent or THEME.glass
    object.BackgroundTransparency = accent and 0.05 or 0.12
    object.TextColor3 = THEME.text
    object.Font = Enum.Font.GothamBold
    object.TextSize = props.TextSize or 12
    object.BorderSizePixel = 0
    object.AutoButtonColor = false
    stroke(object, accent and THEME.accentHot or THEME.line, 1, accent and 0.35 or 0.45)
    return object
end

-- thin bevel lines: the "molded plastic" edge the reference cards have
local function bevel(parent, zIndex)
    make("Frame", {
        Name = "BevelTop", Position = UDim2.fromOffset(3, 1), Size = UDim2.new(1, -6, 0, 1),
        BackgroundColor3 = Color3.fromRGB(235, 230, 255), BackgroundTransparency = 0.62,
        BorderSizePixel = 0, Active = false, ZIndex = zIndex or 12,
    }, parent)
    make("Frame", {
        Name = "BevelBottom", Position = UDim2.new(0, 3, 1, -2), Size = UDim2.new(1, -6, 0, 1),
        BackgroundColor3 = Color3.fromRGB(6, 3, 14), BackgroundTransparency = 0.1,
        BorderSizePixel = 0, Active = false, ZIndex = zIndex or 12,
    }, parent)
end

--==============================================================================
-- ROOT GUI
--==============================================================================
local oldGui = playerGui:FindFirstChild("M0x46Finder")
if oldGui then oldGui:Destroy() end

local gui = make("ScreenGui", {
    Name = "M0x46Finder",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    DisplayOrder = 1200,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, playerGui)
pcall(function() gui.ScreenInsets = Enum.ScreenInsets.None end)

local function viewport()
    local ok, camera = pcall(function() return workspace.CurrentCamera end)
    local size = ok and camera and camera.ViewportSize
    -- Roblox ViewportSize is a Vector2, not a Lua table.
    if size and size.X and size.Y and size.X > 0 and size.Y > 0 then
        return size.X, size.Y
    end
    return 1280, 720
end

local MOBILE_TOPBAR, SCREEN_MARGIN = 44, 8

--==============================================================================
-- LAUNCHER  (circular ring, like the reference's floating icon)
--==============================================================================
local launcher = make("TextButton", {
    Name = "Launcher", Text = "M0x46", Position = UDim2.new(0, 18, 0.5, -31),
    Size = UDim2.fromOffset(62, 62), BackgroundColor3 = THEME.accent,
    BorderSizePixel = 0, AutoButtonColor = false, ZIndex = 40,
    Font = Enum.Font.GothamBlack, TextSize = 13, TextColor3 = Color3.new(1, 1, 1),
    TextTruncate = Enum.TextTruncate.AtEnd,
}, gui)
corner(999, launcher)
make("UIGradient", { Rotation = 35, Color = ColorSequence.new(THEME.accent, THEME.accentHot) }, launcher)
stroke(launcher, THEME.cyan, 2, 0.1)
make("Frame", {
    Name = "InnerRing", Position = UDim2.new(0, 5, 0, 5), Size = UDim2.new(1, -10, 1, -10),
    BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 41,
}, launcher)
corner(999, launcher:FindFirstChild("InnerRing"))
stroke(launcher:FindFirstChild("InnerRing"), Color3.fromRGB(255, 255, 255), 1, 0.7)
local launcherDot = make("Frame", {
    Name = "Live", Size = UDim2.fromOffset(9, 9), Position = UDim2.new(1, -13, 0, 8),
    BackgroundColor3 = THEME.green, BorderSizePixel = 0, ZIndex = 43,
}, launcher)
corner(999, launcherDot)
stroke(launcherDot, Color3.fromRGB(10, 7, 22), 2, 0.2)

--==============================================================================
-- PANEL SHELL
--==============================================================================
local panel = make("Frame", {
    Name = "Panel", Size = UDim2.fromOffset(404, 560),
    Position = UDim2.new(0, 18, 0, 64),
    BackgroundColor3 = THEME.bg, BackgroundTransparency = 0.04, BorderSizePixel = 0,
    Active = true, Visible = false, ClipsDescendants = true, ZIndex = 10,
}, gui)
corner(12, panel)
stroke(panel, THEME.accent, 1.5, 0.22, THEME.cyan)
make("UIGradient", {
    Rotation = 95,
    Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(150, 138, 190)),
}, panel)

-- soft outer glow ring
local edgeGlow = make("Frame", {
    Name = "EdgeGlow", BackgroundTransparency = 1, BorderSizePixel = 0,
    Position = UDim2.fromOffset(-4, -4), Size = UDim2.new(1, 8, 1, 8), Active = false, ZIndex = 9,
}, panel)
corner(16, edgeGlow)
stroke(edgeGlow, THEME.accent, 6, 0.84)

local panelScale = make("UIScale", { Scale = 1 }, panel)

-- backdrop: dots + three breathing nebulas (engine tweens only)
local starfield = make("Frame", {
    Name = "Starfield", BackgroundTransparency = 1, BorderSizePixel = 0,
    Size = UDim2.fromScale(1, 1), Active = false, ZIndex = 1,
}, panel)
local starTweens = {}
do
    local random = Random.new(7319)
    for index = 1, math.max(CONFIG.THEME_STARS, 12) do
        local dot = make("Frame", {
            Name = "Star" .. index, BorderSizePixel = 0, Active = false, ZIndex = 1,
            Position = UDim2.fromScale(random:NextNumber(0.03, 0.97), random:NextNumber(0.10, 0.96)),
            BackgroundColor3 = (index % 7 == 0) and THEME.cyan or (index % 3 == 0) and THEME.accentHot
                or Color3.fromRGB(232, 226, 255),
        }, starfield)
        local dotSize = random:NextInteger(2, 3)
        dot.Size = UDim2.fromOffset(dotSize, dotSize)
        dot.BackgroundTransparency = random:NextNumber(0.30, 0.62)
        corner(999, dot)
        local tween = TweenService:Create(dot, TweenInfo.new(
            random:NextNumber(1.4, 3.4), Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true
        ), {
            BackgroundTransparency = 0.88,
            Size = UDim2.fromOffset(dotSize + 1, dotSize + 1),
        })
        tween:Play()
        starTweens[#starTweens + 1] = tween
    end
    for index, spec in ipairs({ { 132, THEME.accent, 0.94 }, { 96, THEME.cyan, 0.95 }, { 72, THEME.accentHot, 0.95 } }) do
        local nebula = make("Frame", {
            Name = "Nebula" .. index, BorderSizePixel = 0, Active = false, ZIndex = 1,
            Position = UDim2.fromScale(random:NextNumber(0.08, 0.78), random:NextNumber(0.14, 0.70)),
            Size = UDim2.fromOffset(spec[1], spec[1]), BackgroundColor3 = spec[2],
            BackgroundTransparency = spec[3],
        }, starfield)
        corner(999, nebula)
        local breathe = TweenService:Create(nebula, TweenInfo.new(4 + index, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
            BackgroundTransparency = math.min(0.985, spec[3] + 0.03),
        })
        breathe:Play()
        starTweens[#starTweens + 1] = breathe
    end
end

-- header ----------------------------------------------------------------------
local HEADER_H = 52
local header = make("Frame", {
    Name = "Header", Position = UDim2.fromOffset(1, 1), Size = UDim2.new(1, -2, 0, HEADER_H),
    BackgroundColor3 = THEME.bgDeep, BackgroundTransparency = 0.12, BorderSizePixel = 0, ZIndex = 12,
}, panel)
corner(12, header)
make("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(130, 118, 170)) }, header)

local title = label(panel, "M0x46 FINDER", UDim2.fromOffset(16, 8), UDim2.new(1, -118, 0, 24), THEME.text, 18)
title.Font = Enum.Font.GothamBlack
title.ZIndex = 13
make("UIGradient", {
    Rotation = 0,
    Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(198, 164, 255)),
}, title)
stroke(title, Color3.fromRGB(5, 3, 12), 1.4, 0.35)

local statusText = label(panel, "connecting…", UDim2.fromOffset(16, 31), UDim2.new(1, -118, 0, 15), THEME.cyan, 10)
statusText.ZIndex = 13
statusText.Font = Enum.Font.Gotham

local minimizeButton = button(panel, {
    Name = "Minimize", Text = "—", Position = UDim2.new(1, -78, 0, 13),
    Size = UDim2.fromOffset(30, 28), TextSize = 15, CornerRadius = 8, ZIndex = 14,
}, false)
local closeButton = button(panel, {
    Name = "Close", Text = "✕", Position = UDim2.new(1, -44, 0, 13),
    Size = UDim2.fromOffset(30, 28), TextSize = 12, CornerRadius = 8, ZIndex = 14,
}, false)
closeButton.TextColor3 = THEME.red
closeButton.BackgroundColor3 = Color3.fromRGB(120, 34, 44)
closeButton.BackgroundTransparency = 0.35

local hairline = make("Frame", {
    Name = "Hairline", BorderSizePixel = 0, Active = false, BackgroundColor3 = THEME.accent,
    Position = UDim2.new(0, 12, 0, HEADER_H + 1), Size = UDim2.new(1, -24, 0, 1), ZIndex = 13,
}, panel)
make("UIGradient", { Rotation = 0, Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.15, 0.2),
    NumberSequenceKeypoint.new(0.85, 0.2), NumberSequenceKeypoint.new(1, 1),
})}, hairline)

-- filter row: rarity chip + REFRESH (with the reset countdown inside it) ---------
local CONTROLS_Y = HEADER_H + 8
local filterButton = button(panel, {
    Name = "RarityFilter", Text = "RARITY: ANY",
    Position = UDim2.fromOffset(10, CONTROLS_Y), Size = UDim2.new(0.56, -14, 0, 32),
    TextSize = 11, CornerRadius = 8,
}, false)

local refreshButton = button(panel, {
    Name = "Refresh", Text = "REFRESH",
    Position = UDim2.new(0.56, -2, 0, CONTROLS_Y), Size = UDim2.new(0.44, -10, 0, 32),
    TextSize = 11, CornerRadius = 8, ZIndex = 14,
}, false)
refreshButton.BackgroundColor3 = Color3.fromRGB(104, 34, 196)
stroke(refreshButton, THEME.accentHot, 1.5, 0.1)
local resetLabel = make("TextLabel", {
    Name = "Reset", Text = "--:--",
    Position = UDim2.new(1, -86, 0, 0), Size = UDim2.fromOffset(80, 32),
    BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 11,
    TextColor3 = THEME.muted, TextXAlignment = Enum.TextXAlignment.Right,
    ZIndex = 15, TextTruncate = Enum.TextTruncate.AtEnd,
}, refreshButton)
resetLabel.Text = "--:--"

-- bottom tab bar (MY SERVER / ALL SERVERS), like the reference ------------------
local TABS_H = 36
local FOOTER_BTN_H = 30
local tabBar = make("Frame", {
    Name = "Tabs", Position = UDim2.new(0, 10, 1, -(FOOTER_BTN_H + 6 + TABS_H + 8)),
    Size = UDim2.new(1, -20, 0, TABS_H),
    BackgroundTransparency = 1, ZIndex = 12,
}, panel)
make("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6),
    SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Center,
}, tabBar)
local localTab = button(tabBar, {
    Name = "TabLocal", Text = "MY SERVER", Size = UDim2.new(0.5, -3, 1, 0),
    LayoutOrder = 1, TextSize = 12, CornerRadius = 8,
}, true)
local feedTab = button(tabBar, {
    Name = "TabAll", Text = "ALL SERVERS", Size = UDim2.new(0.5, -3, 1, 0),
    LayoutOrder = 2, TextSize = 12, CornerRadius = 8,
}, false)

-- list ------------------------------------------------------------------------
local LIST_Y = CONTROLS_Y + 38
local HINT_H = 16
-- everything the list must leave room for at the bottom
-- takes the panel height as an argument: panelH is declared below, and an
-- unresolved upvalue would silently become a nil global
local function listInset(height)
    local hint = height >= 430 and HINT_H or 0
    return FOOTER_BTN_H + 6 + TABS_H + 8 + hint
end
local list = make("ScrollingFrame", {
    Name = "List", Position = UDim2.fromOffset(10, LIST_Y),
    Size = UDim2.new(1, -20, 0, 300),
    BackgroundTransparency = 1, BorderSizePixel = 0,
    CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollBarThickness = 5, ScrollBarImageColor3 = Color3.fromRGB(150, 132, 190),
    ScrollBarImageTransparency = 0.15,
    ScrollingDirection = Enum.ScrollingDirection.Y, ElasticBehavior = Enum.ElasticBehavior.WhenScrollable,
    ZIndex = 11,
}, panel)
make("UIListLayout", {
    Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder,
    HorizontalAlignment = Enum.HorizontalAlignment.Left,
}, list)
make("UIPadding", { PaddingLeft = UDim.new(0, 2), PaddingRight = UDim.new(0, 2) }, list)

-- footer ----------------------------------------------------------------------
local broadcastButton = button(panel, {
    Name = "Broadcast", Text = "BROADCAST: ON",
    Position = UDim2.new(0, 10, 1, -(FOOTER_BTN_H + 8)), Size = UDim2.new(0.5, -13, 0, FOOTER_BTN_H),
    TextSize = 10, CornerRadius = 8,
}, false)
local settingsButton = button(panel, {
    Name = "Settings", Text = "SETTINGS",
    Position = UDim2.new(0.5, 3, 1, -(FOOTER_BTN_H + 8)), Size = UDim2.new(0.5, -13, 0, FOOTER_BTN_H),
    TextSize = 10, CornerRadius = 8,
}, false)

local footerHint = make("TextLabel", {
    Name = "FooterHint", Text = "SIGHTINGS SHARED WITH YOUR OWN SERVER",
    Position = UDim2.new(0, 12, 1, -15), Size = UDim2.new(1, -24, 0, 12),
    BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 9,
    TextColor3 = THEME.muted, TextXAlignment = Enum.TextXAlignment.Center,
    TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 5,
}, panel)

--==============================================================================
-- SETTINGS OVERLAY (scrollable so it never overflows on a phone)
--==============================================================================
local overlay = make("Frame", {
    Name = "SettingsOverlay", Position = UDim2.fromScale(0, 0), Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = THEME.bgDeep, BackgroundTransparency = 0.03, BorderSizePixel = 0,
    Visible = false, ZIndex = 30,
}, panel)
corner(12, overlay)
stroke(overlay, THEME.accent, 1.4, 0.32)

local overlayTitle = label(overlay, "SETTINGS", UDim2.fromOffset(16, 12), UDim2.new(1, -80, 0, 24), THEME.text, 16)
overlayTitle.Font = Enum.Font.GothamBlack
overlayTitle.ZIndex = 31

local overlayClose = button(overlay, {
    Name = "SettingsClose", Text = "✕", Position = UDim2.new(1, -46, 0, 12),
    Size = UDim2.fromOffset(30, 26), TextSize = 12, CornerRadius = 8, ZIndex = 31,
}, false)
overlayClose.TextColor3 = THEME.red

local overlayBody = make("ScrollingFrame", {
    Name = "SettingsBody", Position = UDim2.fromOffset(10, 44), Size = UDim2.new(1, -20, 1, -52),
    BackgroundTransparency = 1, BorderSizePixel = 0, CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 3,
    ScrollBarImageColor3 = THEME.accent, ScrollingDirection = Enum.ScrollingDirection.Y, ZIndex = 31,
}, overlay)
make("UIListLayout", {
    Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder,
    HorizontalAlignment = Enum.HorizontalAlignment.Center,
}, overlayBody)
make("UIPadding", { PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 10) }, overlayBody)

local function overRow(height, order)
    return make("Frame", {
        Size = UDim2.new(1, -12, 0, height), BackgroundTransparency = 1,
        LayoutOrder = order, ZIndex = 31,
    }, overlayBody)
end

local rateRow = overRow(76, 1)
local rateTitle = label(rateRow, "MINIMUM INCOME", UDim2.fromOffset(2, 0), UDim2.new(1, -4, 0, 16), THEME.muted, 10)
rateTitle.Font = Enum.Font.GothamBold
local rateBox = make("TextBox", {
    Name = "MinRate", Text = moneyFilter(STATE.minRate), PlaceholderText = "1B",
    Position = UDim2.fromOffset(0, 18), Size = UDim2.new(0.4, -4, 0, 30),
    BackgroundColor3 = THEME.glassHigh, TextColor3 = THEME.text, TextSize = 13,
    Font = Enum.Font.GothamBold, ClearTextOnFocus = false, BorderSizePixel = 0, ZIndex = 32,
    TextXAlignment = Enum.TextXAlignment.Center,
}, rateRow)
corner(8, rateBox)
stroke(rateBox, THEME.accent, 1, 0.4)

local PRESETS = { { label = "OFF", value = 0 }, { label = "250M", value = 2.5e8 }, { label = "1B", value = 1e9 }, { label = "5B", value = 5e9 } }
local presetButtons = {}
for index, preset in ipairs(PRESETS) do
    local presetButton = button(rateRow, {
        Text = preset.label, Position = UDim2.new(0.4 + (index - 1) * 0.15, 2, 0, 18),
        Size = UDim2.new(0.15, -4, 0, 30), TextSize = 10, CornerRadius = 7, ZIndex = 32,
    }, false)
    presetButtons[#presetButtons + 1] = { button = presetButton, value = preset.value }
end
local rateHint = label(rateRow, "B/s — 0 or OFF shows every egg", UDim2.fromOffset(2, 54), UDim2.new(1, -4, 0, 14), THEME.muted, 9)
rateHint.Font = Enum.Font.Gotham

local broadcastToggle = button(overlayBody, {
    Name = "BroadcastToggle", Text = "BROADCAST: ON", Size = UDim2.new(1, -12, 0, 38),
    LayoutOrder = 2, TextSize = 11, CornerRadius = 9, ZIndex = 31,
}, false)
local autoJoinToggle = button(overlayBody, {
    Name = "AutoJoinToggle", Text = "AUTO JOIN: OFF", Size = UDim2.new(1, -12, 0, 38),
    LayoutOrder = 3, TextSize = 11, CornerRadius = 9, ZIndex = 31,
}, false)
local autoJoinHint = make("TextLabel", {
    Text = "OFF = JOIN asks SURE? first. ON = JOIN teleports immediately.",
    Size = UDim2.new(1, -12, 0, 26), BackgroundTransparency = 1, LayoutOrder = 4,
    Font = Enum.Font.Gotham, TextSize = 9, TextColor3 = THEME.muted,
    TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 31,
}, overlayBody)

local infoRow = make("TextLabel", {
    -- This is deliberately tall: the scrolling overlay can reveal every NYX
    -- and fallback diagnostic on a short Delta phone instead of truncating it.
    Name = "Diagnostics", Text = "", Size = UDim2.new(1, -12, 0, 250),
    BackgroundTransparency = 1, LayoutOrder = 5, Font = Enum.Font.Gotham, TextSize = 10,
    TextColor3 = THEME.muted, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top, ZIndex = 31,
}, overlayBody)

local function paintOverlayInfo()
    infoRow.Text = table.concat({
        "backend : " .. rawEndpoint() .. " (fallback)",
        "nyx     : " .. (CONFIG.NYX.ENABLED
            and ((NYX.endpoint or "config not read") .. (NYX.error and (" — " .. tostring(NYX.error)) or " · ok"))
            or "disabled"),
        "nyx live: " .. tostring(NYX.servers) .. " server(s), " .. tostring(NYX.participants)
            .. " client(s), ttl " .. tostring(NYX.ttlSeconds) .. "s",
        "source  : " .. tostring(STATE.feedSource or "none"),
        "nyx err : " .. tostring(STATE.feedErrors and STATE.feedErrors.nyx or "none"),
        "own err : " .. tostring(STATE.feedErrors and STATE.feedErrors.own or "none"),
        "last url: " .. tostring(DIAG.lastUrl or "(nothing requested yet)"),
        "status   : " .. tostring(STATE.feedError and describeError(STATE.feedError) or (STATE.feedLoaded and "reachable" or "not contacted yet")),
        "game src : " .. (CAPS.moduleApi and "Client.EggState module" or "attribute scan"),
        "scanned  : " .. tostring(STATE.scanned) .. " egg(s) in this server",
        "feed     : " .. tostring(#STATE.feed) .. " remote egg(s) from "
            .. tostring(STATE.remoteServers) .. " other server(s) (" .. tostring(STATE.feedTotal) .. " on backend)",
        "my job   : " .. tostring(game.JobId or "?"):sub(1, 18) .. "… (hidden on ALL SERVERS)",
        "session  : " .. tostring(reporterId):sub(1, 8) .. "… (anonymous)",
        "row cap  : " .. CONFIG.CARD_LIMIT .. " local / " .. CONFIG.FEED_LIMIT .. " feed",
        DIAG.problem and ("\n!! " .. DIAG.problem) or "",
    }, "\n")
end

--==============================================================================
-- RESPONSIVE LAYOUT + DRAG
--==============================================================================
local panelX, panelY = 18, 64
local panelW, panelH = 404, 560

local function clampPanel()
    local vw, vh = viewport()
    local maxH = math.max(220, vh - MOBILE_TOPBAR - SCREEN_MARGIN)
    panelW = clamp(panelW, math.min(260, vw - 16), math.min(440, vw - 16))
    panelH = clamp(panelH, math.min(260, maxH), math.min(640, maxH))
    panelX = clamp(panelX, SCREEN_MARGIN, math.max(SCREEN_MARGIN, vw - panelW - SCREEN_MARGIN))
    panelY = clamp(panelY, MOBILE_TOPBAR, math.max(MOBILE_TOPBAR, vh - panelH - SCREEN_MARGIN))
    panel.Size = UDim2.fromOffset(panelW, panelH)
    panel.Position = UDim2.fromOffset(panelX, panelY)
    footerHint.Visible = panelH >= 430
    list.Size = UDim2.new(1, -20, 0, math.max(40, panelH - LIST_Y - listInset(panelH)))
end

local function clampLauncher()
    local vw, vh = viewport()
    local position = launcher.Position
    local x = clamp(position.X.Offset, SCREEN_MARGIN, math.max(SCREEN_MARGIN, vw - 62 - SCREEN_MARGIN))
    local y = clamp(position.Y.Offset, MOBILE_TOPBAR, math.max(MOBILE_TOPBAR, vh - 62 - SCREEN_MARGIN))
    launcher.Position = UDim2.fromOffset(x, y)
end

-- card height follows the panel so a phone still shows 3-4 real rows
local function cardHeight()
    clampPanel()
    local listHeight = math.max(40, panelH - LIST_Y - listInset(panelH))
    return math.floor(clamp(listHeight / 2.9 - 5, 62, 104))
end

local function cardRows()
    local height = cardHeight()
    if height >= 88 then return 3 end
    if height >= 74 then return 2 end
    return 1
end

local function applyLayout()
    clampPanel()
    clampLauncher()
    markDirty()
end

do
    local dragging, dragTarget, startMouse, startOffset = false, nil, nil, nil

    local function beginDrag(handle, target)
        handle.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                dragging = true
                dragTarget = target
                startMouse = input.Position
                startOffset = target.Position
            end
        end)
    end

    beginDrag(header, panel)
    beginDrag(launcher, launcher)

    UserInputService.InputChanged:Connect(function(input)
        if not dragging or not dragTarget then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        local delta = input.Position - startMouse
        local vw, vh = viewport()
        local width = dragTarget == panel and panelW or 62
        local height = dragTarget == panel and panelH or 62
        local x = clamp(startOffset.X.Offset + delta.X, SCREEN_MARGIN, math.max(SCREEN_MARGIN, vw - width - SCREEN_MARGIN))
        local y = clamp(startOffset.Y.Offset + delta.Y, MOBILE_TOPBAR, math.max(MOBILE_TOPBAR, vh - height - SCREEN_MARGIN))
        dragTarget.Position = UDim2.fromOffset(x, y)
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        if not dragging then return end
        dragging = false
        if dragTarget == panel then
            local position = panel.Position
            panelX, panelY = position.X.Offset, position.Y.Offset
        end
        dragTarget = nil
    end)
end

if workspace.CurrentCamera then
    pcall(function()
        workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
            -- render() is defined later; main loop redraws after markDirty().
            applyLayout()
        end)
    end)
end

--==============================================================================
-- GRADIENT ANIMATION  (engine-side tween: no per-frame Lua cost)
--==============================================================================
local MUTATION_PALETTE = {
    golden = { Color3.fromRGB(198, 156, 0), Color3.fromRGB(255, 196, 20), Color3.fromRGB(255, 236, 140) },
    silver = { Color3.fromRGB(126, 126, 132), Color3.fromRGB(206, 206, 214), Color3.fromRGB(255, 255, 255) },
    rainbow = { Color3.fromRGB(255, 70, 90), Color3.fromRGB(255, 196, 60), Color3.fromRGB(86, 232, 140), Color3.fromRGB(76, 190, 255), Color3.fromRGB(186, 96, 255) },
    frozen = { Color3.fromRGB(150, 210, 255), Color3.fromRGB(226, 244, 255), Color3.fromRGB(120, 180, 240) },
    shadow = { Color3.fromRGB(96, 60, 160), Color3.fromRGB(40, 24, 70), Color3.fromRGB(150, 100, 220) },
}

local liveGradients = {}

local function colorSequence(palette)
    local points = {}
    local count = #palette
    for index = 0, count do
        points[#points + 1] = ColorSequenceKeypoint.new(index / count, palette[(index % count) + 1])
    end
    return ColorSequence.new(points)
end

-- Engine-tweened Offset: an animated rainbow costs zero Lua cycles.
local function scrollGradient(object, palette, seconds)
    local gradient = make("UIGradient", {
        Color = colorSequence(palette), Rotation = 0, Offset = Vector2.new(0, 0),
    }, object)
    local tween = TweenService:Create(gradient, TweenInfo.new(
        seconds or 3.2, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1, false
    ), { Offset = Vector2.new(1, 0) })
    tween:Play()
    liveGradients[gradient] = tween
    return gradient
end

local function mutationPalette(mutationName)
    return MUTATION_PALETTE[tostring(mutationName or ""):lower()]
end

local function paintMutation(object, mutationName)
    local palette = mutationPalette(mutationName)
    if not palette then return false end
    if object:IsA("TextLabel") or object:IsA("TextButton") then
        object.TextColor3 = Color3.new(1, 1, 1)
        scrollGradient(object, palette, 2.6)
    end
    return true
end

local function clearGradients()
    for gradient, tween in pairs(liveGradients) do
        pcall(function() tween:Cancel() end)
        if gradient then pcall(function() gradient:Destroy() end) end
    end
    liveGradients = {}
end

--==============================================================================
-- JOIN  (implementation must sit ABOVE the card renderer: a `local function`
--        referenced earlier resolves to a nil global and silently does nothing)
--==============================================================================
-- A teleport is only attempted with a placeId taken from the report and a jobId
-- that passes the real Roblox job-id shape test. Everything else is refused out
-- loud instead of being passed to TeleportToPlaceInstance and failing invisibly.
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

-- Ask the network that published the row whether it is still claimable.
-- Returns "ok", or a refusal reason string. A network that cannot answer must
-- never block a join the player explicitly confirmed, so failures return "ok"
-- and the teleport itself reports any real problem.
function NYX.claimRemote(entry)
    -- Never ask the own backend to authorise a NYX row (or vice versa): it does
    -- not possess the other network's reservation state. A transport failure is
    -- explicitly shown as "claim unverified" and the player's confirmed JOIN is
    -- still allowed to teleport, rather than being silently misclassified.
    if not CAPS.network then return "ok", "HTTP unavailable" end
    local data, err
    if entry and entry.source == "nyx" then
        data, err = NYX.claim(entry)
        if not data then return "ok", "NYX claim unavailable: " .. tostring(err or "request failed") end
        return NYX.claimVerdict(data)
    end
    data, err = api("POST", "/v1/join", {
        placeId = tonumber(entry and entry.placeId),
        jobId = entry and entry.jobId,
        uid = entry and entry.uid,
        reporterId = reporterId,
    })
    if not data then return "ok", "backend claim unavailable: " .. tostring(err or "request failed") end
    return NYX.claimVerdict(data)
end

local function requestJoin(entry)
    local shapeOk, shapeWhy = jobShape(entry.jobId)
    if not shapeOk then
        notify("cannot join: " .. tostring(shapeWhy), 6)
        return false
    end
    if not validPlaceId(entry.placeId) then
        notify("cannot join: report has no valid PlaceId", 6)
        return false
    end
    local placeId = tonumber(entry.placeId)
    notify(string.format("checking %s (%d)…", shortId(entry.jobId), placeId), 8)

    local verdict, detail = "ok", nil
    if CAPS.network then
        local ok, result, why = pcall(NYX.claimRemote, entry)
        if ok then verdict, detail = result, why else verdict = "ok" end
    end
    if verdict ~= "ok" then
        notify("cannot join: " .. tostring(verdict), 8)
        -- Preserve the refusal accurately: an expired/claimed egg is TAKEN,
        -- while an actual population refusal is FULL. Both remove JOIN on redraw.
        local refusal = tostring(verdict):lower()
        if refusal:find("full", 1, true) then
            entry.full = true
        else
            entry.taken = true
        end
        markDirty()
        renderIfDirty()
        return false
    end
    if detail then
        -- claim could not be checked; say so instead of pretending it was
        notify("claim unverified (" .. tostring(detail) .. ") — teleporting anyway", 6)
    end
    local ok, err = pcall(function()
        TeleportService:TeleportToPlaceInstance(placeId, entry.jobId, player)
    end)
    if not ok then
        notify("teleport failed: " .. tostring(err), 8)
        return false
    end
    notify("teleport requested → " .. shortId(entry.jobId), 6)
    return true
end

--==============================================================================
-- CARD RENDERER  (icon | rank | name / rarity / income+weight / mutations | JOIN)
--==============================================================================
local function clearList()
    clearGradients()
    for _, child in ipairs(list:GetChildren()) do
        if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
            child:Destroy()
        end
    end
end

local function weightText(entry)
    if validNumber(entry.weight) then return compact(entry.weight) .. " KG" end
    if validNumber(entry.scale) then return "×" .. compact(entry.scale) end
    return nil
end

local function serverLine(entry)
    if entry.isLocal or entry.jobId == nil or entry.jobId == game.JobId then
        return "THIS SERVER", true
    end
    return "SERVER " .. shortId(entry.jobId), false
end

local SURE_COLOR = Color3.fromRGB(190, 132, 30)
local JOIN_COLOR = Color3.fromRGB(40, 160, 85)
local HERE_COLOR = Color3.fromRGB(86, 90, 100)
local pendingJoins = {}

local function makeCard(entry, index)
    local spec = raritySpec(entry)
    local rows = cardRows()
    local height = cardHeight()
    local rank = displayRank(entry)
    -- a card is only JOIN-able if BOTH ids would survive validation
    local canJoin = validJobId(entry.jobId) and jobShape(entry.jobId) and validPlaceId(entry.placeId)
    if entry.full == true or entry.taken == true then canJoin = false end
    local serverText, isHere = serverLine(entry)

    local card = make("Frame", {
        Name = "Card" .. index, Size = UDim2.new(1, -6, 0, height),
        BackgroundColor3 = CARD_BG, BackgroundTransparency = 0.10, BorderSizePixel = 0,
        LayoutOrder = index, ZIndex = 11, ClipsDescendants = true,
    })
    corner(8, card)
    make("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(168, 158, 200)) }, card)
    stroke(card, isHere and THEME.line or THEME.accent, 1, isHere and 0.55 or 0.3)
    bevel(card, 12)

    -- left rarity tint bar
    local tint = make("Frame", {
        Name = "Tint", Size = UDim2.new(0, 3, 1, -10), Position = UDim2.fromOffset(0, 5),
        BackgroundColor3 = spec.color, BackgroundTransparency = 0.12, BorderSizePixel = 0, ZIndex = 13,
    }, card)
    corner(2, tint)

    -- egg icon (only when the game gives us one)
    local iconX = 9
    local iconUrl = type(entry.icon) == "string" and entry.icon or nil
    if iconUrl and #iconUrl > 0 then
        local iconSize = math.min(56, height - 26)
        local iconBack = make("Frame", {
            Name = "IconBack", Position = UDim2.fromOffset(iconX, math.floor((height - iconSize) / 2)),
            Size = UDim2.fromOffset(iconSize, iconSize), BackgroundColor3 = THEME.bgDeep,
            BackgroundTransparency = 0.25, BorderSizePixel = 0, ZIndex = 12,
        }, card)
        corner(8, iconBack)
        stroke(iconBack, spec.color, 1, 0.6)
        local icon = make("ImageLabel", {
            Name = "EggIcon", Image = iconUrl, BackgroundTransparency = 1, ZIndex = 13,
            Position = UDim2.fromOffset(2, 2), Size = UDim2.new(1, -4, 1, -4), ScaleType = Enum.ScaleType.Fit,
        }, iconBack)
        local _ = icon
        iconX = iconX + iconSize + 8
    end

    -- rank
    local rankLabel = label(card, "#" .. index, UDim2.fromOffset(iconX, 4), UDim2.fromOffset(34, 24),
        Color3.fromRGB(220, 224, 235), math.min(20, math.max(14, height - 62)))
    rankLabel.Font = Enum.Font.GothamBlack
    rankLabel.ZIndex = 13
    stroke(rankLabel, Color3.new(0, 0, 0), 1.4, 0.3)

    -- name
    -- number, not a boolean: `canJoin or isHere and 78 or 66` yields true
    local joinW = canJoin and 78 or (isHere and 70 or 66)
    local nameX = iconX + 32
    local nameLabel = label(card, tostring(entry.name), UDim2.fromOffset(nameX, 3),
        UDim2.new(1, -(nameX + joinW + 14), 0, 26), spec.color, math.min(18, math.max(13, height - 64)))
    nameLabel.Font = Enum.Font.GothamBlack
    nameLabel.ZIndex = 13
    stroke(nameLabel, Color3.new(0, 0, 0), 1.1, 0.35)
    local topPalette = nil
    for _, mutation in ipairs(entry.mutations or {}) do
        topPalette = topPalette or mutationPalette(mutation)
    end
    if topPalette then
        nameLabel.TextColor3 = Color3.new(1, 1, 1)
        scrollGradient(nameLabel, topPalette, 3.0)
    elseif rank >= 8 then
        scrollGradient(nameLabel, { spec.color, THEME.text, spec.color }, 3.4)
    end

    -- rarity chip
    local chipY = height - 21
    local chip = make("TextLabel", {
        Name = "Rarity", Text = tostring(entry.rarity):upper(),
        Position = UDim2.fromOffset(iconX + 30, chipY), Size = UDim2.fromOffset(76, 16),
        BackgroundColor3 = spec.color, BackgroundTransparency = 0.88, BorderSizePixel = 0,
        Font = Enum.Font.GothamBold, TextSize = 9, TextColor3 = spec.color,
        TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 13,
    }, card)
    corner(4, chip)
    stroke(chip, spec.color, 1, 0.5)

    -- income + weight
    local moneyLabel = label(card, money(entry.rate), UDim2.fromOffset(iconX + 112, chipY - 1),
        UDim2.fromOffset(110, 18), THEME.green, 15)
    moneyLabel.Name = "Income"
    moneyLabel.Font = Enum.Font.GothamBlack
    moneyLabel.ZIndex = 13
    local weight = weightText(entry)
    -- One-row cards have no server/area line, so the remote server id replaces
    -- the weight/scale readout: a JOIN button must always say which server it
    -- will put you in.
    if rows < 3 and not isHere then
        -- badge regardless of joinability: FULL/TAKEN rows still need to say
        -- which server they came from
        weight = "SRV " .. shortId(entry.jobId)
    end
    if weight then
        local weightLabel = make("TextLabel", {
            Name = "Weight", Text = weight, Position = UDim2.new(1, -(joinW + 116), 0, chipY),
            Size = UDim2.fromOffset(104, 16), BackgroundTransparency = 1,
            Font = Enum.Font.GothamBold, TextSize = 10,
            TextColor3 = weight:sub(1, 4) == "SRV " and THEME.cyan or THEME.muted,
            TextXAlignment = Enum.TextXAlignment.Right, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 13,
        }, card)
        local _ = weightLabel
    end

    -- mutations / server line
    if rows >= 2 then
        local flow = make("Frame", {
            Name = "Mutations", Position = UDim2.fromOffset(nameX, 30),
            Size = UDim2.new(1, -(nameX + joinW + 14), 0, 16), BackgroundTransparency = 1, ZIndex = 13,
        }, card)
        make("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 5),
            SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Center,
        }, flow)
        local mutations = entry.mutations or {}
        if #mutations == 0 then
            local none = make("TextLabel", {
                Name = "MutNone", Text = "no mutation", Size = UDim2.fromOffset(100, 16),
                BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 9,
                TextColor3 = THEME.muted, ZIndex = 13, LayoutOrder = 1,
            }, flow)
            local _ = none
        else
            for mutationIndex, mutation in ipairs(mutations) do
                local word = make("TextLabel", {
                    Name = "Mut" .. mutationIndex, Text = tostring(mutation),
                    Size = UDim2.fromOffset(math.min(#tostring(mutation) * 7 + 8, 96), 16),
                    BackgroundTransparency = 1, Font = Enum.Font.GothamBlack, TextSize = 10,
                    TextColor3 = THEME.text, TextTruncate = Enum.TextTruncate.AtEnd,
                    LayoutOrder = mutationIndex, ZIndex = 14,
                }, flow)
                paintMutation(word, mutation)
            end
        end
        if rows >= 3 then
            local areaLabel = make("TextLabel", {
                Name = "Area", Text = (entry.area and ("area " .. tostring(entry.area)) or "area unknown")
                    .. "  ·  " .. serverText,
                Position = UDim2.fromOffset(nameX, 48), Size = UDim2.new(1, -(nameX + joinW + 14), 0, 14),
                BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 9,
                TextColor3 = isHere and THEME.muted or THEME.cyan,
                TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 13,
            }, card)
            local _ = areaLabel
        end
    end

    -- action button
    local buttonWidth = canJoin and 78 or (isHere and 70 or 66)
    local buttonHeight = math.min(30, height - 32)
    local action = button(card, {
        Name = "JoinStatus",
        Text = isHere and "HERE"
            or (entry.taken == true and "TAKEN")
            or (entry.full == true and "FULL")
            or (canJoin and "JOIN" or "NO ID"),
        Position = UDim2.new(1, -(buttonWidth + 9), 0, math.floor((height - buttonHeight) / 2)),
        Size = UDim2.fromOffset(buttonWidth, buttonHeight), TextSize = 11, CornerRadius = 8, ZIndex = 15,
    }, false)
    action.BackgroundColor3 = canJoin and JOIN_COLOR or HERE_COLOR
    action.TextColor3 = canJoin and Color3.new(1, 1, 1) or THEME.muted
    if canJoin then stroke(action, Color3.new(0, 0, 0), 2, 0.35) end

    action.MouseButton1Click:Connect(function()
        if isHere then
            notify("you are already in this server", 3)
            return
        end
        if not canJoin then
            if entry.taken == true then
                notify("this egg was already taken — tap REFRESH for a fresh list", 6)
            elseif entry.full == true then
                notify("that reported server is full — tap REFRESH for a fresh list", 6)
            else
                local _, why = jobShape(entry.jobId)
                notify("this report cannot be joined: " .. tostring(why), 6)
            end
            return
        end
        local pending = pendingJoins[action]
        if pending and os.clock() < pending.until_ then
            pendingJoins[action] = nil
            action.Text = "JOIN"
            action.BackgroundColor3 = JOIN_COLOR
            requestJoin(entry)
            return
        end
        if CONFIG.AUTO_JOIN then
            requestJoin(entry)
            return
        end
        pendingJoins[action] = { until_ = os.clock() + 5 }
        action.Text = "SURE?"
        action.BackgroundColor3 = SURE_COLOR
        notify("tap JOIN again to teleport to " .. shortId(entry.jobId), 5)
    end)

    return card
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
local function render()
    clearList()
    local shown, matched = visibleList()
    if STATE.tab == "all" then STATE.feedMatched = matched end

    if #shown == 0 then
        local holder = make("Frame", {
            Name = "EmptyState", Size = UDim2.new(1, -6, 0, 122), BackgroundColor3 = CARD_BG,
            BackgroundTransparency = 0.3, BorderSizePixel = 0, LayoutOrder = 1, ZIndex = 11,
        }, list)
        corner(8, holder)
        stroke(holder, THEME.line, 1, 0.5)
        local message = make("TextLabel", {
            Name = "EmptyText", Text = emptyMessage(), Size = UDim2.new(1, -20, 1, -20),
            Position = UDim2.fromOffset(10, 10), BackgroundTransparency = 1, Font = Enum.Font.Gotham,
            TextSize = 11, TextColor3 = THEME.muted, TextWrapped = true,
            TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, ZIndex = 12,
        }, holder)
        local _ = message
        return
    end

    for index = 1, #shown do
        local card = makeCard(shown[index], index)
        card.Parent = list
        card.BackgroundTransparency = 1
        TweenService:Create(card, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            BackgroundTransparency = 0.10,
        }):Play()
    end
end

local function renderIfDirty()
    if not panel.Visible then return end
    if not STATE.dirty then return end
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
        gui:SetAttribute("M0x46Count", matched)
        gui:SetAttribute("M0x46Raw", #entries)
        gui:SetAttribute("M0x46Status", STATE.status)
        gui:SetAttribute("M0x46Source", CAPS.moduleApi and "module" or "attributes")
    end)
    markDirty()
    return true
end

local function ingestFeed()
    if STATE.feedBusy then return false end
    if not CAPS.network then
        STATE.feedError = "HTTP unavailable"
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

    local function harvest(data)
        local added = 0
        for _, raw in ipairs(data.items or {}) do
            local entry = normalizeFeedItem(raw, "nyx")
            if entry then
                local isHere = entry.jobId == game.JobId
                local expired = entry.expiresAt and entry.expiresAt > 0 and entry.expiresAt <= NYX.now()
                -- A row is dropped only when it cannot be true any more:
                --   1. it belongs to the server we are already standing in
                --   2. its TTL has run out
                -- Rows the network reports as full/claimed stay listed with a
                -- FULL / TAKEN badge and no JOIN button — hiding them would hide
                -- real reports, which this app never does.
                if not (CONFIG.REMOTE_ONLY and isHere) and not expired then
                    local key = tostring(entry.uid) .. "|" .. tostring(entry.jobId)
                    local existing = seen[key]
                    if not existing then
                        seen[key] = entry
                        list[#list + 1] = entry
                        added = added + 1
                    elseif (entry.rate or -1) > (existing.rate or -1) then
                        -- `list` holds the first table, so update it in place;
                        -- replacing only seen[key] would leave a stale card.
                        for field, value in pairs(entry) do existing[field] = value end
                    end
                    if type(entry.jobId) == "string" then remote[entry.jobId] = true end
                end
            end
        end
        return added
    end

    if CONFIG.NYX.ENABLED then
        local offset, pageIndex, lastError = 0, 0, nil
        local nyxPages = math.max(1, tonumber(CONFIG.NYX.PAGES) or 1)
        while pageIndex < nyxPages do
            local data, err = NYX.fetchPage(offset)
            if not data then lastError = err break end
            pageIndex = pageIndex + 1
            harvest(data)
            total = math.max(total, tonumber(data.total) or 0)
            local following = tonumber(data.nextOffset)
            if #(data.items or {}) == 0 or not following or following <= offset then break end
            offset = following
        end
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
        -- claimable rows first (a TAKEN/FULL row can never be joined), then by income
        table.sort(list, function(a, b)
            local aDead = (a.taken == true or a.full == true) and 1 or 0
            local bDead = (b.taken == true or b.full == true) and 1 or 0
            if aDead ~= bDead then return aDead < bDead end
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
        STATE.feedMatched = 0
        for _, entry in ipairs(list) do if passesFilter(entry) then STATE.feedMatched = STATE.feedMatched + 1 end end
        local more = STATE.feedTotal > #list and string.format(" · %d total", STATE.feedTotal) or ""
        STATE.status = string.format("%d live%s · %d server(s) · NYX",
            #list, more, STATE.remoteServers)
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
                -- defence in depth: even if the backend ignores excludeJob, our
                -- own server must never appear under ALL SERVERS
                if not (CONFIG.REMOTE_ONLY and isHere) then
                    local key = tostring(entry.uid) .. "|" .. tostring(entry.jobId)
                    local existing = seen[key]
                    if not existing then
                        seen[key] = entry
                        list[#list + 1] = entry
                    elseif (entry.rate or -1) > (existing.rate or -1) then
                        -- `list` holds the first table, so update it in place;
                        -- replacing only seen[key] would leave a stale card.
                        for field, value in pairs(entry) do existing[field] = value end
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
        STATE.feedError = sourceError or lastError or "invalid response"
        STATE.feedLoaded = true
        markDirty()
        return false
    end

    table.sort(list, sortByValue)
    STATE.feed = list
    STATE.feedTotal = total > 0 and total or #list
    STATE.remoteServers = 0
    for _ in pairs(remote) do STATE.remoteServers = STATE.remoteServers + 1 end
    if remoteTotal > 0 then STATE.remoteServers = remoteTotal end
    STATE.feedError = nil
    STATE.feedLoaded = true
    STATE.feedAt = os.clock()
    STATE.feedMatched = 0
    for _, entry in ipairs(list) do if passesFilter(entry) then STATE.feedMatched = STATE.feedMatched + 1 end end
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
    localTab.BackgroundColor3 = STATE.tab == "local" and THEME.accent or THEME.glass
    feedTab.BackgroundColor3 = STATE.tab == "all" and THEME.accent or THEME.glass
    localTab.TextColor3 = THEME.text
    feedTab.TextColor3 = THEME.text
end

local function paintBroadcast()
    broadcastButton.Text = CONFIG.BROADCAST and "BROADCAST: ON" or "BROADCAST: OFF"
    broadcastButton.TextColor3 = CONFIG.BROADCAST and THEME.text or THEME.red
    broadcastToggle.Text = CONFIG.BROADCAST and "BROADCAST: ON" or "BROADCAST: OFF"
    broadcastToggle.BackgroundColor3 = CONFIG.BROADCAST and Color3.fromRGB(34, 128, 74) or Color3.fromRGB(140, 44, 50)
end

local function paintAutoJoin()
    autoJoinToggle.Text = CONFIG.AUTO_JOIN and "AUTO JOIN: ON" or "AUTO JOIN: OFF"
    autoJoinToggle.BackgroundColor3 = CONFIG.AUTO_JOIN and Color3.fromRGB(34, 128, 74) or THEME.glass
end

local function paintFilter()
    local spec = FILTERS[STATE.filterIndex]
    filterButton.Text = "RARITY: " .. string.upper(spec.name)
    local rarity = RARITY_BY_NAME[spec.name:lower()]
    filterButton.TextColor3 = rarity and rarity.color or THEME.muted
end

local function applyFilters(reason)
    -- Local/own-backend rows are re-filtered instantly. NYX also receives the
    -- changed floor/rank server-side, so refresh it once when ALL SERVERS is open.
    markDirty()
    local shown, matched = visibleList()
    if reason then
        notify(string.format("%d shown (≥%s, %s+)", matched, moneyFilter(STATE.minRate), rarityName(STATE.minRank)), 3)
    end
    renderIfDirty()
    if STATE.tab == "all" then refreshFeed() end
end

local function setTab(key)
    if STATE.tab == key then
        if key == "all" then refreshFeed() end
        return
    end
    STATE.tab = key
    paintTabs()
    markDirty()
    render()
    if key == "all" then refreshFeed() end
end

localTab.MouseButton1Click:Connect(function() setTab("local") end)
feedTab.MouseButton1Click:Connect(function() setTab("all") end)

filterButton.MouseButton1Click:Connect(function()
    STATE.filterIndex = STATE.filterIndex % #FILTERS + 1
    local spec = FILTERS[STATE.filterIndex]
    STATE.minRank = spec.rank
    paintFilter()
    applyFilters(true)
end)

refreshButton.MouseButton1Click:Connect(function()
    notify("scanning…", 2)
    refreshLocal()
    if STATE.tab == "all" then refreshFeed() end
    local shown, matched = visibleList()
    notify(string.format("%d egg(s) match (≥%s, %s+)", matched, moneyFilter(STATE.minRate), rarityName(STATE.minRank)), 4)
    local _ = shown -- kept for debugging in the console
end)

broadcastButton.MouseButton1Click:Connect(function()
    CONFIG.BROADCAST = not CONFIG.BROADCAST
    paintBroadcast()
    notify(CONFIG.BROADCAST and "broadcasting enabled" or "broadcasting paused")
end)

settingsButton.MouseButton1Click:Connect(function()
    overlay.Visible = not overlay.Visible
    if overlay.Visible then paintOverlayInfo() end
end)
overlayClose.MouseButton1Click:Connect(function() overlay.Visible = false end)

broadcastToggle.MouseButton1Click:Connect(function()
    CONFIG.BROADCAST = not CONFIG.BROADCAST
    paintBroadcast()
    notify(CONFIG.BROADCAST and "broadcasting enabled" or "broadcasting paused")
end)

autoJoinToggle.MouseButton1Click:Connect(function()
    CONFIG.AUTO_JOIN = not CONFIG.AUTO_JOIN
    paintAutoJoin()
    notify(CONFIG.AUTO_JOIN and "JOIN teleports immediately" or "JOIN now asks SURE? first")
end)

-- income box: parse "1B", "250M", "0", "off", "1.5b"
local function parseIncome(text)
    local clean = string.lower(tostring(text or "")):gsub("%s", "")
    if clean == "" or clean == "off" or clean == "0" then return 0 end
    local amount, suffix = clean:match("^([%d%.]+)([kmbtq]?)")
    local value = tonumber(amount)
    if not value then return nil end
    local multiplier = ({ k = 1e3, m = 1e6, b = 1e9, t = 1e12, q = 1e15 })[suffix] or 1
    return value * multiplier
end

local function applyIncomeBox(silent)
    local value = parseIncome(rateBox.Text)
    if not value then
        rateBox.Text = moneyFilter(STATE.minRate)
        notify("income must look like 1B, 250M or 0 (off)", 5)
        return
    end
    STATE.minRate = clamp(value, 0, 1e13)
    rateBox.Text = moneyFilter(STATE.minRate)
    applyFilters(not silent)
end

rateBox.FocusLost:Connect(function() applyIncomeBox(false) end)
rateBox:GetPropertyChangedSignal("Text"):Connect(function()
    -- live update while typing, but only for a complete, valid number
    if parseIncome(rateBox.Text) ~= nil then
        STATE.minRate = clamp(parseIncome(rateBox.Text), 0, 1e13)
        markDirty()
        renderIfDirty()
    end
end)

for _, preset in ipairs(presetButtons) do
    preset.button.MouseButton1Click:Connect(function()
        STATE.minRate = preset.value
        rateBox.Text = moneyFilter(STATE.minRate)
        applyFilters(true)
    end)
end

--==============================================================================
-- MINIMISE / REOPEN / CLOSE
--==============================================================================
local function fadePanel(target, visible)
    if visible then
        panel.Visible = true
        panelScale.Scale = 0.96
        TweenService:Create(panelScale, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 }):Play()
        render()
    else
        local tween = TweenService:Create(panelScale, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = 0.96 })
        tween.Completed:Connect(function() panel.Visible = false; panelScale.Scale = 1 end)
        tween:Play()
    end
    launcher.Visible = not visible
    if target then target.Visible = true end
end

local function openPanel()
    if panel.Visible then return end
    clampPanel()
    fadePanel(nil, true)
    paintTabs()
end

local function minimizePanel()
    if not panel.Visible then return end
    fadePanel(nil, false)
end

local function closeScript()
    notify("M0x46 unloaded", 2)
    pcall(function() gui:Destroy() end)
end

launcher.MouseButton1Click:Connect(function()
    if panel.Visible then minimizePanel() else openPanel() end
end)
minimizeButton.MouseButton1Click:Connect(minimizePanel)
closeButton.MouseButton1Click:Connect(closeScript)

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == CONFIG.HOTKEY then
        if panel.Visible then minimizePanel() else openPanel() end
    end
end)

--==============================================================================
-- MAIN LOOP  (one coroutine for scan, broadcast, feed and UI text)
--==============================================================================
local loop = {
    nextScan = 0,
    nextReport = 0,
    nextFeed = 0,
    lastBroadcast = nil,
}

local function updateStatusLine()
    if overlay.Visible then paintOverlayInfo() end
    local line = STATE.status
    if STATE.notice and os.clock() < STATE.noticeUntil then line = STATE.notice end
    if DIAG.problem then
        statusText.Text = "⚠ BACKEND — see ALL SERVERS tab"
        statusText.TextColor3 = THEME.red
        return
    end
    statusText.Text = tostring(STATE.reportStatus) .. "  ·  " .. tostring(line)
    if STATE.feedError then
        -- surface the actual failure in the header, where it is impossible to miss
        statusText.Text = "⚠ " .. tostring(describeError(STATE.feedError))
        statusText.TextColor3 = THEME.amber
    else
        statusText.TextColor3 = THEME.cyan
    end
end

local function updateReset()
    local cycle = cycleInfo()
    if cycle and validNumber(cycle.remaining) then
        local seconds = math.max(0, math.ceil(cycle.remaining))
        resetLabel.Text = cycle.running == false and "PAUSED"
            or string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
        resetLabel.TextColor3 = seconds <= 60 and THEME.red or seconds <= 150 and THEME.amber or THEME.muted
    else
        resetLabel.Text = "--:--"
        resetLabel.TextColor3 = THEME.muted
    end
end

local function expirePendingJoins()
    for button, pending in pairs(pendingJoins) do
        if not button.Parent then
            pendingJoins[button] = nil
        elseif os.clock() >= pending.until_ then
            button.Text = "JOIN"
            button.BackgroundColor3 = JOIN_COLOR
            pendingJoins[button] = nil
        end
    end
end

task.spawn(function()
    -- first data pull immediately, then follow the schedule
    ingestScan()
    loop.nextScan = os.clock() + CONFIG.SCAN_EVERY
    loop.nextFeed = os.clock()

    while gui.Parent do
        local now = os.clock()
        local interval = panel.Visible and CONFIG.SCAN_EVERY or CONFIG.HIDDEN_SCAN_EVERY

        if now >= loop.nextScan then
            ingestScan()
            loop.nextScan = now + interval
        end

        -- broadcast: only when something changed, or every 15 s as a keep-alive
        if CONFIG.BROADCAST and #STATE.raw > 0 and now >= loop.nextReport then
            local signature = tostring(#STATE.raw) .. ":" .. tostring(STATE.raw[1] and STATE.raw[1].uid)
            if signature ~= loop.lastBroadcast or now >= loop.nextReport + 10 then
                loop.lastBroadcast = signature
                loop.nextReport = now + CONFIG.REPORT_EVERY
                local data, err = broadcast(STATE.raw)
                if data then
                    STATE.reportStatus = string.format("shared %d", tonumber(data.accepted) or 0)
                    pcall(function() gui:SetAttribute("M0x46Reported", tonumber(data.accepted) or 0) end)
                elseif err and err ~= "busy" then
                    STATE.reportStatus = describeError(err)
                end
            else
                loop.nextReport = now + CONFIG.REPORT_EVERY
            end
        end

        -- feed: only while ALL SERVERS is actually on screen. The shared feed is
        -- polled slightly faster than the own backend because NYX reports expire
        -- in ~90 s and a stale list means a wasted teleport.
        if STATE.tab == "all" and panel.Visible and now >= loop.nextFeed then
            loop.nextFeedInterval = CONFIG.NYX.ENABLED and math.min(CONFIG.FEED_EVERY, 5) or CONFIG.FEED_EVERY
            loop.nextFeed = now + (loop.nextFeedInterval or CONFIG.FEED_EVERY)
            if not feedInFlight then
                feedInFlight = true
                task.spawn(function()
                    ingestFeed()
                    feedInFlight = false
                end)
            end
        end

        expirePendingJoins()
        updateStatusLine()
        if panel.Visible then
            updateReset()
            renderIfDirty()
        end

        task.wait(CONFIG.UI_TICK)
    end
end)

gui.Destroying:Connect(function()
    for _, tween in ipairs(starTweens) do pcall(function() tween:Cancel() end) end
    clearGradients()
end)

--==============================================================================
-- BOOT
--==============================================================================
clampPanel()
clampLauncher()
probeApiBase()
paintTabs()
paintBroadcast()
paintAutoJoin()
paintFilter()
paintOverlayInfo()
render()
panelScale.Scale = 1
log("M0x46 Finder v2.3 loaded — hotkey", CONFIG.HOTKEY.Name,
    "| source:", CAPS.moduleApi and "module" or "attributes")

-- loud, actionable warnings instead of silent zeroes
if not CAPS.network then
    log("WARNING: this executor exposes no HTTP function — ALL SERVERS is disabled")
else
    local endpoint = rawEndpoint()
    if endpoint:find("127%.0%.0%.1") or endpoint:find("localhost") then
        log("WARNING: ENDPOINT is the local default (" .. endpoint .. ") — the game cannot reach your PC.")
    elseif CONFIG.ROOM_KEY == "changeme" then
        log("WARNING: ROOM_KEY is still 'changeme' — set it to the value you started the server with")
    end
    local key = tostring(CONFIG.ROOM_KEY or "")
    if key:find('"') or key:find("'") then
        log("WARNING: ROOM_KEY contains quote characters — write ROOM_KEY = \"value\" once, not escaped quotes")
    elseif key:find("=") then
        log("WARNING: ROOM_KEY looks like a pasted assignment ('ROOM_KEY=...') — keep only the value")
    end
    if key:find("^#") then
        log("WARNING: ROOM_KEY starts with '#' — that is the .env comment marker; the server's real key does not have it")
    end
    if DIAG.problem then log("WARNING: " .. DIAG.problem) end
    local basePath = basePathOf(rawEndpoint())
    if basePath ~= "" and basePath ~= "/" then
        log("WARNING: ENDPOINT ends with the path '" .. basePath
            .. "' — the backend serves /v1/* at the host root, so calls become "
            .. basePath .. "/v1/eggs and return 404. Use the bare host.")
    end
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
        return nil
    end,
})
