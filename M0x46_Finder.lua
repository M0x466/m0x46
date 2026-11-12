-- M0x46 Live Egg Finder v3 | one self-contained client; private report relay.
-- Before executing, set getgenv().M0x46_CONFIG = {ENDPOINT="https://YOUR-APP.back4.app", ROOM_KEY="YOUR-PRIVATE-KEY"}
-- Or create M0x46_Config.json privately in the executor workspace. Never commit it.
-- Remote sightings are client reports, not proof of egg availability or authenticity.
local CONFIG = {
    ENDPOINT = "", ROOM_KEY = "", REMOTE_ONLY = true, AUTO_JOIN = false,
    BROADCAST = true, MIN_RATE = 1e9, MIN_RANK = 0,
    SCAN_EVERY = 3, HIDDEN_SCAN_EVERY = 6, REPORT_EVERY = 15,
    FEED_EVERY = 12, SIGHTING_TTL = 45, PAGE_SIZE = 20,
    CARD_LIMIT = 40, MAX_PAGES = 3, HTTP_TIMEOUT = 8,
}
local Http = game:GetService("HttpService")
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local Input = game:GetService("UserInputService")
local Teleports = game:GetService("TeleportService")
local env = _G
pcall(function() if type(getgenv) == "function" then env = getgenv() end end)
local private = {}
pcall(function()
    if type(readfile) == "function" then private = Http:JSONDecode(readfile("M0x46_Config.json")) end
end)
if type(private) ~= "table" then private = {} end
if type(env.M0x46_CONFIG) == "table" then
    for key, value in pairs(env.M0x46_CONFIG) do private[key] = value end
end
-- Only configuration values with the expected type can override defaults.
for key, value in pairs(private) do
    if CONFIG[key] ~= nil and type(value) == type(CONFIG[key]) then CONFIG[key] = value end
end
CONFIG.REMOTE_ONLY = true
local function finite(n) return type(n) == "number" and n == n and n >= 0 and n < math.huge end
local function bounded(n, lo, hi, default)
    return finite(n) and math.max(lo, math.min(hi, n)) or default
end
CONFIG.MIN_RATE = bounded(CONFIG.MIN_RATE, 1e9, 1e30, 1e9)
CONFIG.MIN_RANK = math.floor(bounded(CONFIG.MIN_RANK, 0, 10, 0))
CONFIG.SCAN_EVERY = bounded(CONFIG.SCAN_EVERY, 2, 10, 3)
CONFIG.HIDDEN_SCAN_EVERY = bounded(CONFIG.HIDDEN_SCAN_EVERY, 3, 10, 6)
CONFIG.REPORT_EVERY = bounded(CONFIG.REPORT_EVERY, 10, 20, 15)
CONFIG.FEED_EVERY = bounded(CONFIG.FEED_EVERY, 10, 60, 12)
CONFIG.SIGHTING_TTL = bounded(CONFIG.SIGHTING_TTL, 30, 120, 45)
CONFIG.SIGHTING_TTL = math.max(CONFIG.SIGHTING_TTL, CONFIG.REPORT_EVERY * 3)
CONFIG.PAGE_SIZE = math.floor(bounded(CONFIG.PAGE_SIZE, 1, 50, 20))
CONFIG.CARD_LIMIT = math.floor(bounded(CONFIG.CARD_LIMIT, 1, 60, 40))
CONFIG.MAX_PAGES = math.floor(bounded(CONFIG.MAX_PAGES, 1, 5, 3))
CONFIG.HTTP_TIMEOUT = bounded(CONFIG.HTTP_TIMEOUT, 4, 15, 8)
local RARITIES = {"Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Cosmic", "Secret", "Eternal", "Divine"}
local function rankFor(name, rank)
    for i, v in ipairs(RARITIES) do if v:lower() == tostring(name):lower() then return i end end
    return finite(rank) and math.floor(rank) or 0
end
local function validPlace(n) return finite(n) and n > 0 and n <= 9007199254740991 and n % 1 == 0 end
local function validJob(s)
    if type(s) ~= "string" or #s ~= 36 then return false end
    return s:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end
local function sameJob(a,b) return type(a) == "string" and type(b) == "string" and a:lower() == b:lower() end
local function money(n, perSecond)
    if not finite(n) then return "Income unknown" end
    for _, u in ipairs({{1e18,"Qi"},{1e15,"Qa"},{1e12,"T"},{1e9,"B"},{1e6,"M"},{1e3,"K"}}) do
        if n >= u[1] then return string.format("%.2f%s%s", n/u[1], u[2], perSecond and "/s" or "") end
    end
    return string.format("%.0f%s", n, perSecond and "/s" or "")
end
local function parseIncome(s)
    local amount, suffix = tostring(s):lower():gsub("%s", ""):match("^(%d+%.?%d*)(%a*)$")
    local unit = ({[""]=1,k=1e3,m=1e6,b=1e9,t=1e12,qa=1e15,qi=1e18})[suffix]
    local n = amount and unit and tonumber(amount) * unit
    return finite(n) and n or nil
end
if not game:IsLoaded() then game.Loaded:Wait() end
local player = Players.LocalPlayer
assert(player, "Wait until Roblox finishes joining before executing M0x46")
local playerGui = player:WaitForChild("PlayerGui", 30)
assert(playerGui, "PlayerGui unavailable")
if type(env.__M0x46_STOP) == "function" then pcall(env.__M0x46_STOP) end
local old = playerGui:FindFirstChild("M0x46Finder")
if old then old:Destroy() end
local alive, connections = true, {}
local function connect(signal, fn)
    local c = signal:Connect(fn); connections[#connections+1] = c; return c
end
local state = {
    tab="all", raw={}, feed={}, scanAt=-math.huge, scanOK=false, scanError="Waiting for game data",
    feedError=nil, reportStatus="Sharing pending", dirty=true, minRate=CONFIG.MIN_RATE, minRank=CONFIG.MIN_RANK,
    epoch=0, total=0, servers=0, reportingServers=0, loaded=false, feedAt=-math.huge,
    nextFeed=0, nextReport=0, nextScan=0, feedFailures=0, reportFailures=0,
    notice="", noticeUntil=0, joining=false, joinUntil=0, joinEntry=nil, pendingJoin=nil,
}
local function notice(s, seconds) state.notice=tostring(s); state.noticeUntil=os.clock()+(seconds or 7) end
local theme = {bg=Color3.fromRGB(10,7,20), card=Color3.fromRGB(26,18,43), purple=Color3.fromRGB(139,82,224),
    text=Color3.fromRGB(242,236,255), muted=Color3.fromRGB(183,169,207), green=Color3.fromRGB(108,232,157)}
local function make(class, props, parent)
    local o=Instance.new(class); for k,v in pairs(props) do o[k]=v end; o.Parent=parent; return o
end
local function round(o) make("UICorner",{CornerRadius=UDim.new(0,9)},o) end
local function label(parent, name, x,y,w,h,size)
    return make("TextLabel",{Name=name,Position=UDim2.new(0,x,0,y),Size=UDim2.new(1,w,0,h),BackgroundTransparency=1,
        Text="",TextColor3=theme.text,Font=Enum.Font.Gotham,TextSize=size or 12,TextXAlignment=Enum.TextXAlignment.Left,
        TextTruncate=Enum.TextTruncate.AtEnd,RichText=false},parent)
end
local function button(parent,name,text,position,_unused,size)
    local b=make("TextButton",{Name=name,Text=text,Position=position,Size=size,BackgroundColor3=theme.card,TextColor3=theme.text,
        Font=Enum.Font.GothamBold,TextSize=12,BorderSizePixel=0,AutoButtonColor=true},parent)
    round(b); return b
end
local gui=make("ScreenGui",{Name="M0x46Finder",ResetOnSpawn=false,IgnoreGuiInset=false,DisplayOrder=1200,ZIndexBehavior=Enum.ZIndexBehavior.Sibling},playerGui)
local panel=make("Frame",{Name="Panel",BackgroundColor3=theme.bg,BorderSizePixel=0,Active=true,ClipsDescendants=true},gui)
round(panel)
make("UIStroke",{Color=theme.purple,Thickness=1,Transparency=0.2},panel)
local header=make("Frame",{Name="DragHandle",Size=UDim2.new(1,-100,0,44),BackgroundTransparency=1,Active=true},panel)
local title=label(header,"Brand",12,6,-12,32,17); title.Text="M0x46  LIVE FINDER"; title.Font=Enum.Font.GothamBold
local minimize=button(panel,"Minimize","−",UDim2.new(1,-92,0,4),nil,UDim2.fromOffset(42,36))
local close=button(panel,"Close","×",UDim2.new(1,-46,0,4),nil,UDim2.fromOffset(42,36))
local launcher=button(gui,"Reopen","M0x46",UDim2.fromOffset(12,64),nil,UDim2.fromOffset(66,44)); launcher.Visible=false
local tabs=make("Frame",{Name="Tabs",Position=UDim2.fromOffset(8,48),Size=UDim2.new(1,-16,0,40),BackgroundTransparency=1},panel)
local myTab=button(tabs,"MyServer","MY SERVER",UDim2.fromOffset(0,0),nil,UDim2.new(0.5,-3,1,0))
local allTab=button(tabs,"AllServers","ALL SERVERS",UDim2.new(0.5,3,0,0),nil,UDim2.new(0.5,-3,1,0))
local filters=make("Frame",{Name="Filters",Position=UDim2.fromOffset(8,94),Size=UDim2.new(1,-16,0,40),BackgroundTransparency=1},panel)
local rarity=button(filters,"Rarity","",UDim2.fromOffset(0,0),nil,UDim2.new(0.6,-4,1,0))
local rateBox=make("TextBox",{Name="MinimumIncome",Position=UDim2.new(0.6,2,0,0),Size=UDim2.new(0.4,-2,1,0),Text=money(state.minRate),
    PlaceholderText="Min 1B/s",ClearTextOnFocus=false,BackgroundColor3=theme.card,TextColor3=theme.text,
    Font=Enum.Font.Gotham,TextSize=14,BorderSizePixel=0},filters); round(rateBox)
local tools=make("Frame",{Name="Actions",Position=UDim2.fromOffset(8,140),Size=UDim2.new(1,-16,0,36),BackgroundTransparency=1},panel)
local refresh=button(tools,"Refresh","REFRESH",UDim2.fromOffset(0,0),nil,UDim2.new(0.34,-4,1,0))
local sharing=button(tools,"Sharing","",UDim2.new(0.34,2,0,0),nil,UDim2.new(0.33,-4,1,0))
local auto=button(tools,"AutoJoin","",UDim2.new(0.67,2,0,0),nil,UDim2.new(0.33,-2,1,0))
local summary=label(panel,"Summary",10,180,-20,34,12); summary.TextWrapped=true; summary.TextTruncate=Enum.TextTruncate.None
local list=make("ScrollingFrame",{Name="EggList",Position=UDim2.fromOffset(8,220),Size=UDim2.new(1,-16,1,-300),BackgroundTransparency=1,
    BorderSizePixel=0,ScrollBarThickness=4,CanvasSize=UDim2.fromOffset(0,0),ScrollingDirection=Enum.ScrollingDirection.Y},panel)
make("UIListLayout",{Padding=UDim.new(0,8),SortOrder=Enum.SortOrder.LayoutOrder},list)
local empty=label(list,"Empty",8,4,-20,144,13); empty.TextWrapped=true; empty.TextTruncate=Enum.TextTruncate.None; empty.TextYAlignment=Enum.TextYAlignment.Top
local status=label(panel,"Status",10,0,-20,48,11); status.Position=UDim2.new(0,10,1,-74); status.TextWrapped=true; status.TextTruncate=Enum.TextTruncate.None
local foot=label(panel,"Foot",10,0,-20,22,10); foot.Position=UDim2.new(0,10,1,-24); foot.Text="Client reports • Min 1B/s • Tap JobId to copy"; foot.TextColor3=theme.muted
local function viewport()
    -- ScreenGui.AbsoluteSize reflects Roblox's safe inset when available.
    local s=gui.AbsoluteSize
    if s and s.X>0 and s.Y>0 then return s.X,s.Y end
    local c=workspace.CurrentCamera; s=c and c.ViewportSize
    return s and s.X or 800,s and math.max(1,s.Y-36) or 564
end
local panelW,panelH=0,0
local function clampFrame(frame,w,h)
    local vw,vh=viewport()
    frame.Position=UDim2.fromOffset(math.max(0,math.min(vw-w,frame.Position.X.Offset)),math.max(0,math.min(vh-h,frame.Position.Y.Offset)))
end
local firstFit=true
local function fit()
    local vw,vh=viewport(); panelW=math.min(620,vw-16); panelH=math.min(670,vh-16)
    panel.Size=UDim2.fromOffset(math.max(1,panelW),math.max(1,panelH))
    if firstFit then panel.Position=UDim2.fromOffset(math.floor((vw-panelW)/2),8); firstFit=false end
    local compact=vh<430
    title.TextSize=panelW<360 and 14 or 17
    header.Size=UDim2.new(1,-100,0,compact and 36 or 44)
    tabs.Position=UDim2.fromOffset(8,compact and 40 or 48); tabs.Size=UDim2.new(1,-16,0,compact and 32 or 40)
    filters.Position=UDim2.fromOffset(8,compact and 76 or 94); filters.Size=UDim2.new(1,-16,0,compact and 32 or 40)
    tools.Visible=not compact
    summary.Position=UDim2.fromOffset(10,compact and 110 or 180); summary.Size=UDim2.new(1,-20,0,compact and 28 or 34)
    summary.TextSize=compact and 10 or 12
    list.Position=UDim2.fromOffset(8,compact and 142 or 220); list.Size=UDim2.new(1,-16,1,compact and -184 or -300)
    status.Position=UDim2.new(0,10,1,compact and -38 or -74); status.Size=UDim2.new(1,-20,0,compact and 34 or 48)
    foot.Visible=not compact
    clampFrame(panel,panelW,panelH); clampFrame(launcher,66,44); state.dirty=true
end
local drag
local function draggable(handle,frame)
    connect(handle.InputBegan,function(input)
        if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then
            drag={input=input,frame=frame,origin=input.Position,x=frame.Position.X.Offset,y=frame.Position.Y.Offset,moved=false}
        end
    end)
end
draggable(header,panel); draggable(launcher,launcher)
connect(Input.InputChanged,function(input)
    if not drag then return end
    if input==drag.input or (drag.input.UserInputType==Enum.UserInputType.MouseButton1 and input.UserInputType==Enum.UserInputType.MouseMovement) then
        local dx,dy=input.Position.X-drag.origin.X,input.Position.Y-drag.origin.Y
        drag.moved=drag.moved or math.abs(dx)+math.abs(dy)>6
        drag.frame.Position=UDim2.fromOffset(drag.x+dx,drag.y+dy)
        clampFrame(drag.frame,drag.frame==panel and panelW or 66,drag.frame==panel and panelH or 44)
    end
end)
local suppressOpenUntil=0
connect(Input.InputEnded,function(input)
    if drag and (input==drag.input or input.UserInputType==Enum.UserInputType.MouseButton1) then
        if drag.moved then suppressOpenUntil=os.clock()+0.3 end
        drag=nil
    end
end)
local function stop()
    if not alive then return end
    alive=false
    for _,c in ipairs(connections) do c:Disconnect() end
    gui:Destroy()
end
env.__M0x46_STOP=stop
connect(gui.Destroying,function()
    alive=false
    for _,c in ipairs(connections) do c:Disconnect() end
end)
connect(close.Activated,stop)
connect(minimize.Activated,function() panel.Visible=false; launcher.Visible=true end)
connect(launcher.Activated,function()
    if os.clock()<suppressOpenUntil then return end
    panel.Visible=true; launcher.Visible=false; fit(); state.dirty=true
end)
connect(Input.InputBegan,function(input,processed)
    if not processed and input.KeyCode==Enum.KeyCode.RightControl then panel.Visible=not panel.Visible; launcher.Visible=not panel.Visible; state.dirty=true end
end)
connect(gui:GetPropertyChangedSignal("AbsoluteSize"),fit)

-- Game bridge: only live field slots. A successful empty snapshot retires eggs.
local modules, nextModules = {},0
local function requirePath(dotted)
    local node=RS
    for part in dotted:gmatch("[^%.]+") do node=node and node:FindFirstChild(part); if not node then return nil end end
    if not node:IsA("ModuleScript") then return nil end
    local ok,v=pcall(require,node); return ok and type(v)=="table" and v or nil
end
local function loadModules()
    if os.clock()<nextModules then return end
    nextModules=os.clock()+10
    for key,p in pairs({eggs="Client.EggState",assets="Data.Assets",types="Shared.Types.AreaEggs",mutations="Shared.Modules.Mutations"}) do
        if not modules[key] then modules[key]=requirePath(p) end
    end
end
local function attr(model,key)
    if not model then return nil end
    local ok,v=pcall(model.GetAttribute,model,key); return ok and v or nil
end
local modelLabels=setmetatable({}, {__mode="k"})
local function displayedRate(model)
    if not model then return nil end
    local cached=modelLabels[model]
    if not cached or os.clock()-cached.at>15 then
        cached={at=os.clock(),labels={}}
        for _,obj in ipairs(model:GetDescendants()) do
            if obj:IsA("TextLabel") or obj:IsA("TextButton") then cached.labels[#cached.labels+1]=obj end
        end
        modelLabels[model]=cached
    end
    local value
    for _,obj in ipairs(cached.labels) do
        if obj.Parent then
            local s=tostring(obj.Text):gsub("<[^>]+>",""):gsub(",","")
            local amount,suffix=s:match("%$?%s*(%d+%.?%d*)%s*(%a*)%s*/%s*[sS]%f[%A]")
            if amount then
                local n=parseIncome(amount..suffix)
                -- Conflicting displays stay unknown rather than choosing the highest.
                if n and value and n~=value then return nil end
                value=n or value
            end
        end
    end
    return value
end
local function mutationNames(raw)
    local out,seen={},{}
    local known=type(raw)=="string" or type(raw)=="table"
    if type(raw)=="string" and raw:sub(1,1)=="[" then
        local ok,v=pcall(Http.JSONDecode,Http,raw); if ok and type(v)=="table" then raw=v end
    end
    local function add(s)
        if type(s)~="string" then return end
        s=s:match("^%s*(.-)%s*$")
        if s~="" and s~="None" and s~="Normal" and not seen[s] then seen[s]=true; out[#out+1]=s end
    end
    if type(raw)=="table" then
        for k,v in pairs(raw) do if v==true and type(k)=="string" then add(k) elseif type(v)=="string" then add(v) end end
    elseif type(raw)=="string" then for s in raw:gmatch("[^,;|+]+") do add(s) end end
    table.sort(out); return out,known
end
local function estimatedRate(asset,record)
    local base,scale,muts=asset.EarningRate,record.AssetScale,record.Mutations
    if not finite(base) or not finite(scale) or scale<=0 or type(muts)~="table" then return nil end
    local multiplier=1
    if next(muts) then
        local fn=modules.mutations and modules.mutations.EarningsFor
        if type(fn)~="function" then return nil end
        local ok,v=pcall(fn,muts); if not ok or not finite(v) then return nil end
        multiplier=v
    end
    -- Reference formula is an estimate; never publish it to the remote feed.
    local factor=scale>5 and (scale/5)^1.2*19.637875755794113 or scale^1.85
    local v=base*factor*multiplier; return finite(v) and v or nil
end
local function scan()
    loadModules()
    local root=workspace:FindFirstChild("AreaEggSlotsClient")
    local out={}
    local function enrich(uid,r,model)
        local category=r.AssetCategory or attr(model,"AssetCategory")
        local directory=modules.assets and modules.assets.Directory
        local asset=(type(directory)=="table" and directory[category]) or {}
        local spec=type(asset.Rarity)=="table" and asset.Rarity or {}
        local rate=displayedRate(model)
        local estimated=rate==nil
        if not rate then rate=estimatedRate(asset,r) end
        local mutations,known=mutationNames(r.Mutations or attr(model,"Mutations"))
        out[#out+1]={uid=tostring(uid),name=tostring(asset.DisplayName or category or attr(model,"DisplayName") or model and model.Name or uid),
            rarity=tostring(spec.DisplayName or spec._id or attr(model,"Rarity") or "Unknown"),rank=rankFor(spec.DisplayName or spec._id or attr(model,"Rarity"),tonumber(spec.Rank)),
            rate=rate,estimated=estimated,rateSource=estimated and "estimate" or "display",category=category and tostring(category) or nil,
            mutations=mutations,traitsKnown=known,jobId=game.JobId,placeId=game.PlaceId,isLocal=true,seenClock=os.clock()}
    end
    local api=modules.eggs
    if api and type(api.ReadFieldEggs)=="function" then
        local snapshot=api.ReadFieldEggs()
        if type(snapshot)~="table" or type(snapshot.Records)~="table" then error("Field snapshot unavailable") end
        local states=modules.types and modules.types.States
        if not states or states.Slot==nil then error("Game slot schema unavailable; sharing paused") end
        for key,r in pairs(snapshot.Records) do
            if type(r)=="table" and r.State==states.Slot then
                local uid=r.Uid or key
                local model=root and root:FindFirstChild(tostring(uid)) or workspace:FindFirstChild(tostring(uid))
                enrich(uid,r,model)
            end
        end
    elseif root then
        for _,model in ipairs(root:GetChildren()) do
            local s=attr(model,"State")
            if model:IsA("Model") and (s==nil or s=="Slot") then
                local uid=attr(model,"Uid") or model.Name
                enrich(uid,{},model)
            end
        end
    else error("Game modules/field folder unavailable; sharing paused") end
    local rows,seen={},{}
    for _,e in ipairs(out) do if not seen[e.uid] then seen[e.uid]=true; rows[#rows+1]=e end end
    table.sort(rows,function(a,b) return (a.rate or -1)>(b.rate or -1) end)
    return rows
end

-- Network: one serialized worker for report/feed/join; bounded retries/backoff.
local requestFn=type(request)=="function" and request or type(http_request)=="function" and http_request
    or type(syn)=="table" and syn.request or type(http)=="table" and http.request
if type(requestFn)~="function" then requestFn=nil end
local endpoint=CONFIG.ENDPOINT:gsub("/+$","")
local configError
if not endpoint:match("^https://[%w%.%-]+$") then configError="Set your HTTPS ENDPOINT in private M0x46_CONFIG"
elseif #CONFIG.ROOM_KEY<24 or #CONFIG.ROOM_KEY>512 or CONFIG.ROOM_KEY:find("[^!-~]") then configError="ROOM_KEY needs 24-512 printable ASCII characters without spaces"
elseif not requestFn then configError="Delta HTTP request function unavailable" end
local healthAt=-math.huge
local function api(method,path,body)
    if not alive then return nil,"Finder stopped" end
    if configError then return nil,configError end
    local opts={Url=endpoint..path,Method=method,Headers={["Content-Type"]="application/json",["X-Egg-Room"]=CONFIG.ROOM_KEY},Timeout=CONFIG.HTTP_TIMEOUT}
    if body then local ok,v=pcall(Http.JSONEncode,Http,body); if not ok then return nil,"Cannot encode report" end; opts.Body=v end
    local started=os.clock()
    local ok,response=pcall(requestFn,opts)
    if not ok or type(response)~="table" then return nil,"Backend unavailable or request failed" end
    local code=tonumber(response.StatusCode or response.Status) or 0
    if code==401 then return nil,"ROOM_KEY mismatch (HTTP 401)" end
    if code==429 then return nil,"Backend rate limit; backing off" end
    if code==409 then return nil,"Snapshot expired or sequence rejected; refresh again" end
    if code<200 or code>=300 then return nil,"Backend HTTP "..tostring(code) end
    local decoded,data=pcall(Http.JSONDecode,Http,response.Body or "")
    if not decoded or type(data)~="table" then return nil,"Invalid backend JSON" end
    return data,nil,os.clock()-started
end
local function checkHealth()
    if os.clock()-healthAt<60 then return true end
    local data,err=api("GET","/health")
    if not data then return false,err end
    if data.service~="m0x46-egg-relay" or data.version~=3 or type(data.capabilities)~="table" or data.capabilities.excludeJob~=true or data.capabilities.snapshots~=true then
        return false,"Backend v3 required: deploy reviewed server.js after approval"
    end
    healthAt=os.clock(); return true
end
local reporterId=Http:GenerateGUID(false) -- per execution; no account/user telemetry
local sequence=0
local function report()
    if not validPlace(game.PlaceId) or not validJob(game.JobId) then return nil,"No public PlaceId/JobId" end
    if not state.scanOK or os.clock()-state.scanAt>12 then return nil,"Fresh scan unavailable; sharing paused" end
    local eggs={}
    if CONFIG.BROADCAST then for _,e in ipairs(state.raw) do
        if finite(e.rate) and e.rate>=1e9 and not e.estimated then
            eggs[#eggs+1]={uid=e.uid,name=e.name,rate=e.rate,rarity=e.rarity,rank=e.rank,mutations=e.mutations,
                traitsKnown=e.traitsKnown,category=e.category,estimated=false,rateSource="display"}
        end
    end end
    if #eggs>256 then return nil,"More than 256 eligible eggs; report exceeds relay limit" end
    sequence=sequence+1
    -- [] is deliberate: withdraw this reporter's previous snapshot immediately.
    return api("POST","/v1/report",{placeId=game.PlaceId,jobId=game.JobId,reporterId=reporterId,sequence=sequence,ttl=CONFIG.SIGHTING_TTL*1000,eggs=eggs})
end
local function normalizeRemote(item,serverTime,rtt)
    if type(item)~="table" or not validJob(item.jobId) or sameJob(item.jobId,game.JobId) then return nil end
    if not validPlace(item.placeId) or item.placeId~=game.PlaceId or type(item.uid)~="string" or item.uid=="" then return nil end
    if type(item.name)~="string" or not finite(item.rate) or item.rate<state.minRate or item.estimated==true then return nil end
    if not finite(serverTime) or not finite(item.expiresAt) or not finite(item.seenAt) or item.seenAt>serverTime or item.expiresAt<=serverTime then return nil end
    local rank=rankFor(item.rarity,item.rank)
    if rank<state.minRank then return nil end
    local mutations,known=mutationNames(item.mutations)
    return {uid=item.uid,name=item.name,rate=item.rate,rarity=tostring(item.rarity or "Unknown"),rank=rank,mutations=mutations,
        traitsKnown=item.traitsKnown==true and known,jobId=item.jobId,placeId=item.placeId,isLocal=false,estimated=false,
        seenClock=os.clock()-math.max(0,(serverTime-item.seenAt)/1000),expiresClock=os.clock()+(item.expiresAt-serverTime)/1000-rtt}
end
local function fetchFeed()
    if not validJob(game.JobId) then return nil,"Current server has no valid JobId" end
    local epoch=state.epoch
    local base=string.format("/v1/eggs?placeId=%.0f&localJob=%s&excludeJob=%s&all=1&minRate=%.0f&minRank=%d&limit=%d",
        game.PlaceId,Http:UrlEncode(game.JobId),Http:UrlEncode(game.JobId),state.minRate,state.minRank,CONFIG.PAGE_SIZE)
    local items,seen,offset,snapshot={}, {},0,nil
    local total,servers,reportingServers=0,0,0
    for _=1,CONFIG.MAX_PAGES do
        local url=base.."&offset="..offset..(snapshot and "&snapshot="..Http:UrlEncode(snapshot) or "")
        local data,err,rtt=api("GET",url)
        if epoch~=state.epoch or not alive then return nil,"Filters changed",true end
        if not data or type(data.items)~="table" or type(data.snapshot)~="string" then return nil,err or "Invalid feed page" end
        if snapshot and snapshot~=data.snapshot then return nil,"Backend changed pagination snapshot" end
        snapshot=data.snapshot
        total=tonumber(data.total) or 0; servers=tonumber(data.serverCount) or 0; reportingServers=tonumber(data.reportingServerCount) or 0
        for _,raw in ipairs(data.items) do
            local e=normalizeRemote(raw,data.serverTime,rtt)
            if e and e.expiresClock>os.clock() then
                local key=e.placeId..":"..e.jobId..":"..e.uid
                if not seen[key] then seen[key]=true; items[#items+1]=e end
            end
        end
        local following=tonumber(data.nextOffset)
        if data.nextOffset==nil then break end
        if not finite(following) or following%1~=0 or following<=offset then return nil,"Invalid pagination cursor" end
        if #items>=CONFIG.CARD_LIMIT then break end
        offset=following
    end
    return {items=items,total=total,servers=servers,reportingServers=reportingServers}
end
local function teleportError(result,message)
    local code=tostring(result)
    if code:find("GameFull",1,true) then return "Server is full. Choose another report." end
    if code:find("GameNotFound",1,true) then return "Server closed or report expired. Refresh the feed." end
    if code:find("Unauthorized",1,true) or code:find("GameRestricted",1,true) then return "Server is private, restricted, or inaccessible." end
    if code:find("Flooded",1,true) then return "Roblox teleport rate limit. Wait and try again." end
    return "JOIN failed: "..tostring(message or result):sub(1,160)
end
local function join(entry)
    if not validPlace(entry.placeId) or entry.placeId~=game.PlaceId or not validJob(entry.jobId) or sameJob(entry.jobId,game.JobId) then notice("Invalid target or current server"); return end
    if not entry.expiresClock or entry.expiresClock<=os.clock() then notice("Report expired. Refresh first."); return end
    state.joining=true; state.joinUntil=os.clock()+20; state.joinEntry=entry
    notice("Checking report before JOIN…")
    local data,err,rtt=api("POST","/v1/join",{placeId=entry.placeId,jobId=entry.jobId,uid=entry.uid,currentJob=game.JobId})
    if not alive then return end
    if not state.joining or os.clock()>=state.joinUntil then state.joining=false; notice("JOIN preflight timed out; try again"); return end
    if not data or data.allowed~=true then
        state.joining=false; notice(err or "JOIN refused: "..tostring(data and data.reason or "expired")); state.nextFeed=os.clock()+2; return
    end
    if data.placeId~=entry.placeId or not sameJob(data.jobId,entry.jobId) or data.uid~=entry.uid or not finite(data.expiresAt) or not finite(data.serverTime) or data.expiresAt<=data.serverTime+rtt*1000 then
        state.joining=false; notice("JOIN response has an invalid or expired target"); return
    end
    local ok,reason=pcall(function() Teleports:TeleportToPlaceInstance(entry.placeId,entry.jobId,player) end)
    if not ok then state.joining=false; notice(teleportError("request",reason)) else notice("JOIN requested. Roblox checks capacity and access.") end
end
connect(Teleports.TeleportInitFailed,function(who,result,message,placeId,opts)
    if who~=player or not state.joining or not state.joinEntry or (placeId and placeId~=state.joinEntry.placeId) then return end
    if opts then
        local ok,target=pcall(function() return opts.ServerInstanceId end)
        if ok and target and target~="" and not sameJob(target,state.joinEntry.jobId) then return end
    end
    state.joining=false; notice(teleportError(result,message),10)
end)

-- Card pool: reused frames; no per-frame starfield, gradients, or tween churn.
local cards={}
local function keyFor(e) return tostring(e.placeId)..":"..tostring(e.jobId)..":"..e.uid end
local function queueJoin(e)
    if not e or e.isLocal or state.joining or state.pendingJoin then return end
    if state.feedError then notice("Refresh successfully before JOIN: "..state.feedError); return end
    state.pendingJoin=e
end
local function getCard(i)
    if cards[i] then return cards[i] end
    local frame=make("Frame",{Name="Egg"..i,Size=UDim2.new(1,-6,0,144),BackgroundColor3=theme.card,BorderSizePixel=0,LayoutOrder=i},list); round(frame)
    local c={frame=frame}
    c.name=label(frame,"Name",10,5,-104,24,14); c.name.Font=Enum.Font.GothamBold
    c.income=label(frame,"Income",10,30,-20,20,14); c.income.TextColor3=theme.green
    c.rarity=label(frame,"RarityText",10,52,-20,18,12)
    c.mutations=label(frame,"Mutations",10,72,-20,18,11)
    c.id=button(frame,"JobId","",UDim2.fromOffset(8,92),nil,UDim2.new(1,-16,0,24)); c.id.TextSize=10
    c.age=label(frame,"Age",10,119,-20,20,11); c.age.TextColor3=theme.muted
    c.join=button(frame,"Join","JOIN",UDim2.new(1,-88,0,4),nil,UDim2.fromOffset(80,40))
    connect(c.join.Activated,function()
        local e=c.entry
        if not e then return end
        if e.isLocal then notice("You are already in MY SERVER"); return end
        if c.confirmKey~=keyFor(e) or not c.confirmUntil or os.clock()>c.confirmUntil then
            c.confirmKey=keyFor(e); c.confirmUntil=os.clock()+4; c.join.Text="SURE?"; notice("Tap SURE? to join this report",4); return
        end
        c.confirmUntil=0; queueJoin(e)
    end)
    connect(c.id.Activated,function()
        if type(setclipboard)=="function" and c.entry then pcall(setclipboard,c.entry.jobId); notice("JobId copied") else notice(c.entry and c.entry.jobId or "No JobId") end
    end)
    cards[i]=c; return c
end
local function visible()
    local out={}
    local source=state.tab=="local" and state.raw or state.feed
    for _,e in ipairs(source) do
        local fresh=state.tab=="local" and state.scanOK and os.clock()-state.scanAt<=12 or state.tab=="all" and e.expiresClock and e.expiresClock>os.clock()
        if fresh and finite(e.rate) and e.rate>=state.minRate and e.rank>=state.minRank and (state.tab=="local" or not sameJob(e.jobId,game.JobId)) then out[#out+1]=e end
    end
    table.sort(out,function(a,b) if a.rate~=b.rate then return a.rate>b.rate end; return keyFor(a)<keyFor(b) end)
    return out
end
local function render()
    if not panel.Visible then return end
    local rows=visible()
    local count=math.min(#rows,CONFIG.CARD_LIMIT)
    for i=1,count do
        local c,e=getCard(i),rows[i]
        if c.entry and keyFor(c.entry)~=keyFor(e) then c.confirmUntil=0 end
        c.entry=e; c.frame.Visible=true
        c.name.Text=e.name
        c.income.Text=money(e.rate,true)..(e.estimated and "  [ESTIMATE • LOCAL ONLY]" or "  [game display]")
        c.rarity.Text="Rarity: "..e.rarity
        c.mutations.Text="Mutations: "..(#e.mutations>0 and table.concat(e.mutations,", ") or e.traitsKnown and "None" or "Unknown")
        c.id.Text="JobId: "..e.jobId
        c.join.Text=e.isLocal and "HERE" or c.confirmUntil and c.confirmUntil>os.clock() and c.confirmKey==keyFor(e) and "SURE?" or "JOIN"
        c.join.BackgroundColor3=e.isLocal and theme.card or theme.purple
        c.age.Text="Report age: "..math.max(0,math.floor(os.clock()-e.seenClock)).."s"..(e.expiresClock and " • expires in "..math.max(0,math.ceil(e.expiresClock-os.clock())).."s" or " • MY SERVER")
    end
    for i=count+1,#cards do cards[i].frame.Visible=false; cards[i].entry=nil end
    empty.Visible=count==0
    if count==0 then
        if state.tab=="local" then empty.Text=state.scanOK and "No field eggs match the income and rarity filters. Unknown income is excluded." or state.scanError
        elseif state.feedError then empty.Text="ALL SERVERS unavailable\n"..state.feedError
        elseif not state.loaded then empty.Text="Waiting for remote reports…"
        else empty.Text="No remote eggs match your filters.\n\nOther servers must run M0x46 with sharing enabled and the same private endpoint/key. Reporting only from MY SERVER cannot create remote detections." end
    end
    list.CanvasSize=UDim2.fromOffset(0,count==0 and 156 or count*152)
    if state.tab=="local" then summary.Text=string.format("MY SERVER • %d detected • %d shown",#state.raw,count)
    else summary.Text=string.format("REMOTE ONLY • %d/%d shown • %d servers at refresh\n%d remote servers reporting at last refresh",count,state.total,state.servers,state.reportingServers) end
    myTab.BackgroundColor3=state.tab=="local" and theme.purple or theme.card
    allTab.BackgroundColor3=state.tab=="all" and theme.purple or theme.card
    rarity.Text="RARITY: "..(RARITIES[state.minRank] or "Any")..(state.minRank>0 and "+" or "")
    sharing.Text=CONFIG.BROADCAST and "SHARE ON" or "SHARE OFF"
    auto.Text=CONFIG.AUTO_JOIN and "AUTO ON" or "AUTO OFF"
    state.dirty=false
end
local function changeFilters()
    state.epoch=state.epoch+1; state.feed={}; state.loaded=false; state.feedError=nil; state.feedAt=-math.huge
    state.nextFeed=os.clock()+1; state.dirty=true
end
connect(myTab.Activated,function() state.tab="local"; state.dirty=true end)
connect(allTab.Activated,function() state.tab="all"; state.nextFeed=math.min(state.nextFeed,os.clock()+1); state.dirty=true end)
connect(rarity.Activated,function() state.minRank=(state.minRank+1)%11; changeFilters() end)
connect(rateBox.FocusLost,function()
    local n=parseIncome(rateBox.Text)
    if not n or n<1e9 or n>1e30 then notice("Minimum must be 1B/s or higher (examples: 1B, 10B, 1T)") else state.minRate=n; changeFilters() end
    rateBox.Text=money(state.minRate)
end)
local lastManualRefresh=-math.huge
connect(refresh.Activated,function()
    if os.clock()-lastManualRefresh<5 or os.clock()-state.feedAt<5 then notice("Feed just updated; wait a few seconds"); return end
    lastManualRefresh=os.clock()
    state.nextScan=0; state.nextFeed=math.min(state.nextFeed,os.clock()+1); notice("Refresh queued")
end)
connect(sharing.Activated,function() CONFIG.BROADCAST=not CONFIG.BROADCAST; state.nextReport=os.clock(); state.dirty=true end)
local autoConfirmUntil=-math.huge
connect(auto.Activated,function()
    if not CONFIG.AUTO_JOIN and os.clock()>autoConfirmUntil then autoConfirmUntil=os.clock()+4; notice("Tap AUTO again to enable automatic teleportation",4); return end
    CONFIG.AUTO_JOIN=not CONFIG.AUTO_JOIN; autoConfirmUntil=0; state.dirty=true
end)

local scanBusy,networkBusy=false,false
local scanStarted=0
local networkStarted,stalled=false,false
local lastAuto=0
local attempted={}
local function backoff(failures,base) return math.min(120,base*2^math.min(failures,4)) end
local function networkWork()
    local healthy,err=checkHealth()
    if not healthy then
        state.feedError=err; state.reportStatus=err
        state.feedFailures=state.feedFailures+1; state.reportFailures=state.reportFailures+1
        local retry=os.clock()+backoff(state.feedFailures,CONFIG.FEED_EVERY)
        state.nextFeed=retry; state.nextReport=retry; state.pendingJoin=nil; state.dirty=true; return
    end
    if not alive then return end
    if state.pendingJoin then
        local e=state.pendingJoin; state.pendingJoin=nil; join(e); return
    end
    -- Heartbeats use last completion + a fixed interval, including unchanged/empty snapshots.
    if os.clock()>=state.nextReport then
        local data,reportErr=report()
        state.reportFailures=data and 0 or state.reportFailures+1
        state.nextReport=os.clock()+(data and CONFIG.REPORT_EVERY or backoff(state.reportFailures,CONFIG.REPORT_EVERY))
        state.reportStatus=data and (CONFIG.BROADCAST and "Shared "..tostring(data.accepted).." measured eggs" or "Sharing off; snapshot withdrawn") or tostring(reportErr)
    end
    if alive and panel.Visible and state.tab=="all" and os.clock()>=state.nextFeed then
        local data,feedErr,cancelled=fetchFeed()
        if cancelled then state.nextFeed=os.clock()+1; return end
        state.feedFailures=data and 0 or state.feedFailures+1
        state.nextFeed=os.clock()+(data and CONFIG.FEED_EVERY or backoff(state.feedFailures,CONFIG.FEED_EVERY))
        if data then
            state.feed=data.items; state.total=data.total; state.servers=data.servers; state.reportingServers=data.reportingServers
            state.feedAt=os.clock(); state.loaded=true; state.feedError=nil
        else state.feedError=feedErr end
        state.dirty=true
    end
end
fit(); render()
task.spawn(function()
    local lastPaint=-math.huge
    while alive do
        local t=os.clock()
        if t>=state.nextScan and not scanBusy then
            scanBusy=true; scanStarted=t; state.nextScan=t+(panel.Visible and CONFIG.SCAN_EVERY or CONFIG.HIDDEN_SCAN_EVERY)
            task.spawn(function()
                local ok,rows=pcall(scan)
                if alive then
                    state.scanOK=ok
                    if ok then state.raw=rows; state.scanAt=os.clock(); state.scanError=nil
                    else state.raw={}; state.scanError="Scan unavailable: "..tostring(rows):sub(1,140) end
                    state.dirty=true
                end
                scanBusy=false
            end)
        end
        if state.scanOK and t-state.scanAt>12 then
            state.scanOK=false; state.scanError="Game scan stale; sharing paused"; state.dirty=true
        end
        if scanBusy and t-scanStarted>15 then
            state.scanError="Game module scan stalled; re-execute after game finishes loading"; state.dirty=true
        end
        local due=state.pendingJoin or t>=state.nextReport or panel.Visible and state.tab=="all" and t>=state.nextFeed
        if due and not networkBusy and not stalled then
            networkBusy=true; networkStarted=t
            task.spawn(function()
                local ok,err=pcall(networkWork)
                networkBusy=false
                if not ok and alive then state.feedError="Worker failed: "..tostring(err):sub(1,120); state.nextFeed=os.clock()+30; state.nextReport=os.clock()+30; state.dirty=true end
            end)
        end
        -- Some executors ignore Timeout. Never spawn more workers over a hung one.
        if networkBusy and t-networkStarted>CONFIG.HTTP_TIMEOUT*(CONFIG.MAX_PAGES+3) then
            stalled=true; state.feedError="Delta HTTP request stalled; re-execute after checking connection"; state.dirty=true
        end
        if state.joining and t>=state.joinUntil then state.joining=false; notice("JOIN timed out. The server may be inaccessible.",10) end
        if CONFIG.AUTO_JOIN and not state.joining and not state.pendingJoin and not state.feedError and state.tab=="all" and panel.Visible and t-lastAuto>20 and t-state.feedAt<CONFIG.FEED_EVERY+2 then
            for _,e in ipairs(visible()) do
                local key=keyFor(e)
                if not e.isLocal and (not attempted[key] or t-attempted[key]>120) then
                    attempted[key]=t; lastAuto=t; queueJoin(e); break
                end
            end
        end
        if t-lastPaint>=1 then
            for k,v in pairs(attempted) do if t-v>120 then attempted[k]=nil end end
            status.Text=(t<state.noticeUntil and state.notice or state.reportStatus)..(state.feedError and "\n"..state.feedError or "")
            if panel.Visible then render() end
            lastPaint=t
        elseif state.dirty then render() end
        task.wait(0.5)
    end
end)
