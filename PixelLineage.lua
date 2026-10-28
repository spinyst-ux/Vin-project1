--[[ NCL HUB: Pixel Lineage auto-play | executor script (Luau)
  Finds the game's own buttons by their on-screen text (SET OUT, PLAY SOLO, ATTACK...) and presses them.
  Config auto-saves to workspace/NCL HUB/PixelLineage/config.json; debug.txt there shows what the script sees. ]]

if getgenv and getgenv().NCL_PL then pcall(getgenv().NCL_PL) end
if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local VIM = game:GetService("VirtualInputManager")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local CoreGui = game:GetService("CoreGui")
local player = Players.LocalPlayer
local pgui = player:WaitForChild("PlayerGui")

-- Button texts as the game shows them (normalized: uppercase, symbols stripped).
local TXT = {
	setOut = "SET OUT", solo = "PLAY SOLO", party = "FIND A PARTY", soloRun = "SOLO RUN", soloGo = { "SOLO", "SET OUT" },
	host = "HOST A LOBBY", queue = "RANDOM QUEUE", start = "START RUN",
	attack = "ATTACK", skills = "SKILLS", back = "BACK", path = "CHOOSE YOUR PATH", choose = "MAKE YOUR CHOICE",
	satchel = "SATCHEL", potion = "HP POTION", ally = "CHOOSE AN ALLY", waitReady = "WAITING FOR READY", invite = "PARTY INVITE",
	continue = { "RESUME BATTLE", "CONTINUE", "NEXT FLOOR", "NEXT", "CLAIM", "RETURN TO CASTLE" },
}

local S = {
	running = false, autoJoin = true, autoAttack = true, autoSkill = false, autoTarget = true, autoContinue = true, autoReplay = true, autoQTE = true,
	mode = "Solo", mpMode = "Host", difficulty = "Normal", targetName = "", clickMode = "Background",
	skills = {}, autoChest = true, autoPath = true, pathStars = "3", pathBy = "Reward",
	autoEvent = true, eventPrefer = "OFFER BLOOD", hideQTE = true,
	autoInvite = false, inviteList = "", waitParty = true, autoAccept = false, autoPotion = false, potionPct = "40", bloodMinHp = "50", gameSpeed = "1x", autoSlot = false, slotNum = "1",
	autoSell = false, sellRarity = { Common = true, Uncommon = true }, sellType = { weapon = true, head = true, chest = true, legs = true, relic = true, scroll = true },
	webhook = "", pingId = "", hookClear = true, hookDeath = true, hookChest = true, tormentStage = "", stopAtLife = true, fpsBoost = true, antiAfk = true, autoReconnect = true, autoSave = true, uiKey = "RightShift",
}
-- Config (RUN included) survives the teleport into each run: workspace/NCL HUB/PixelLineage/config.json.
local HttpService = game:GetService("HttpService")
local DIR = "NCL HUB/PixelLineage"
local SAVE = DIR .. "/config.json"
local DEFAULT = HttpService:JSONDecode(HttpService:JSONEncode(S))
local function ensureDir()
	if not (makefolder and isfolder) then return end
	local p = ""
	for part in DIR:gmatch("[^/]+") do
		p = p == "" and part or (p .. "/" .. part)
		if not isfolder(p) then makefolder(p) end
	end
end
local function applyConfig(t)
	if type(t) ~= "table" then return end
	for k, v in pairs(t) do
		if DEFAULT[k] ~= nil and type(v) == type(DEFAULT[k]) then S[k] = v end
	end
end
pcall(function()
	local src = (isfile and isfile(SAVE)) and SAVE or "NCL_PL_settings.json" -- old location, migrated on next save
	applyConfig(HttpService:JSONDecode(readfile(src)))
end)
local saved = ""
local function saveConfig()
	if not writefile then return false end
	ensureDir()
	saved = HttpService:JSONEncode(S)
	return pcall(writefile, SAVE, saved)
end
local alive, status, logs, gui = true, "Idle", {}, nil
local lastQueue = -999
local refresh -- set once the UI exists

local function log(m)
	table.insert(logs, 1, os.date("%H:%M:%S") .. "  " .. m)
	if #logs > 60 then table.remove(logs) end
	status = m -- the main loop redraws; refreshing here would run on game threads that can't touch our gethui UI
end

---------------------------------------------------------------- GAME UI READING
local function norm(s)
	s = s:gsub("<[^>]->", ""):upper():gsub("[^%w ]", " "):gsub("%s+", " ")
	return (s:match("^%s*(.-)%s*$"))
end

local function shown(g)
	if g.AbsoluteSize.X < 2 or g.AbsoluteSize.Y < 2 then return false end
	local o = g
	while o and o ~= pgui do
		if o:IsA("GuiObject") and not o.Visible then return false end
		if o:IsA("LayerCollector") and not o.Enabled then return false end
		o = o.Parent
	end
	return o == pgui
end

-- One pass over PlayerGui: list of { text, instance } for every visible label/button.
-- Walks only visible branches: hidden windows (thousands of instances) are skipped whole instead of every descendant
-- being listed and then checked up its ancestor chain - that per-poll cost was the stutter on slower executors.
local function scan()
	local list = {}
	local function walk(o)
		for _, d in ipairs(o:GetChildren()) do
			if d:IsA("GuiObject") then
				if d.Visible then
					if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text ~= "" and d.AbsoluteSize.X >= 2 and d.AbsoluteSize.Y >= 2 then
						local t = norm(d.Text)
						if t ~= "" then list[#list + 1] = { t, d } end
					end
					walk(d)
				end
			elseif d:IsA("LayerCollector") then
				if d.Enabled and d ~= gui then walk(d) end
			elseif not d:IsA("GuiBase") then
				walk(d) -- Folders and the like between GUI objects
			end
		end
	end
	walk(pgui)
	return list
end

-- Exact text first, then "starts with" (START RUN (1/4)), then short labels that contain it.
local function find(list, want)
	if type(want) == "table" then
		for _, w in ipairs(want) do local g = find(list, w); if g then return g end end
		return
	end
	for _, e in ipairs(list) do if e[1] == want then return e[2] end end
	for _, e in ipairs(list) do if e[1]:sub(1, #want) == want then return e[2] end end
	for _, e in ipairs(list) do if #e[1] <= #want + 10 and e[1]:find(want, 1, true) then return e[2] end end
end

local function center(t)
	local sg = t:FindFirstAncestorWhichIsA("ScreenGui")
	local inset = (sg and sg.IgnoreGuiInset) and Vector2.zero or GuiService:GetGuiInset()
	return t.AbsolutePosition + t.AbsoluteSize / 2 + inset
end

local function mouseClick(t)
	local p = center(t)
	VIM:SendMouseMoveEvent(p.X, p.Y, game)
	task.wait(0.04)
	VIM:SendMouseButtonEvent(p.X, p.Y, 0, true, game, 0)
	task.wait(0.05)
	VIM:SendMouseButtonEvent(p.X, p.Y, 0, false, game, 0)
end

-- The button behind a label: an ancestor (PLAY SOLO), else a sibling hit box (village plates: Plate.PlateHit).
local function buttonOf(g)
	local b = g
	for _ = 0, 3 do
		if not b then break end
		if b:IsA("GuiButton") then return b end
		b = b.Parent
	end
	return g.Parent and g.Parent:FindFirstChildWhichIsA("GuiButton")
end

local setIdentity = setthreadidentity or set_thread_identity or setidentity
-- Tables holding all of `keys`. filtergc matches natively (no heap walk); the full GC walk is the fallback and can
-- stall slow clients, so callers keep it rare. getgc(true) errors or is missing on some mobile executors: never fatal.
local function gcTables(keys)
	if filtergc then
		local ok, r = pcall(filtergc, "table", { Keys = keys })
		if ok and type(r) == "table" then return r end
	end
	if not getgc then return {} end
	local ok, r = pcall(getgc, true)
	if not (ok and type(r) == "table") then ok, r = pcall(getgc) end
	return (ok and type(r) == "table") and r or {}
end
local function fireHandlers(b)
	local fired = false
	for _, sig in ipairs({ b.MouseButton1Click, b.Activated, b.MouseButton1Down, b.MouseButton1Up }) do
		local ok, cs = pcall(getconnections, sig)
		-- own thread: some handlers (SET OUT -> lobby Open) yield and never return to the caller.
		-- identity 2 = game script level; at executor level the game's lazy require() throws and its windows render empty.
		if ok then
			for _, c in ipairs(cs) do
				task.spawn(function()
					if setIdentity then pcall(setIdentity, 2) end
					-- some mobile executors expose only .Function (or a Fire that errors): call the handler directly then
					if not (c.Fire and pcall(c.Fire, c)) and type(c.Function) == "function" then pcall(c.Function) end
				end)
				fired = true
			end
		end
	end
	return fired
end

-- Background: fire the button's own handlers, the mouse never moves. Mouse: virtual move + click at the element.
local function press(g)
	if not g then return false end
	local b = buttonOf(g)
	-- touch-only devices: virtual mouse events steal touch input (screen stops responding), so always background there
	if S.clickMode == "Mouse" and not (UIS.TouchEnabled and not UIS.KeyboardEnabled) then pcall(mouseClick, b or g); return true end
	if getconnections and b and fireHandlers(b) then return true end
	if firesignal and b then
		pcall(firesignal, b.MouseButton1Click); pcall(firesignal, b.Activated)
		return true
	end
	log("No handler on " .. (b or g):GetFullName())
	return false
end

---------------------------------------------------------------- AUTOPLAY
-- After ATTACK / a skill the game may ask for a target. Foe rows live in the command menu's FoesPage
-- (FoeN.Pick, hidden but wired); their handler ignores presses outside target mode, so firing is safe.
-- Picks the row whose name contains Target, else the first foe.
local syncSkills, battleMenu, pickIn
local function pickTarget()
	if not S.autoTarget then return end
	-- retried: on slow devices target mode opens later than 0.3s, and the first FoesPage in PlayerGui can be a stale
	-- copy, so the live battle menu's own box is searched first
	-- the Pick handler ignores presses until target mode ("CHOOSE A FOE") is open, so fire only while it shows
	local picked = false
	for _ = 1, 12 do
		task.wait(0.25)
		if find(scan(), "CHOOSE A FOE") then
			local m = battleMenu and battleMenu()
			local page = (m and m.box:FindFirstChild("FoesPage", true)) or pgui:FindFirstChild("FoesPage", true)
			if page then picked = pickIn(page) or picked end
		elseif picked then
			return
		end
	end
end
function pickIn(page)
	local want, first, hit = norm(S.targetName), nil, nil
	for _, row in ipairs(page:GetDescendants()) do
		local pick = row:IsA("Frame") and row.Name:match("^Foe%d") and row:FindFirstChild("Pick")
		local dead = false
		if pick then
			for _, l in ipairs(row:GetDescendants()) do
				if l:IsA("TextLabel") and norm(l.Text) == "DEFEATED" then dead = true end
			end
		end
		-- a defeated foe ignores the pick and the menu waits on "CHOOSE A FOE" forever
		if pick and not dead then
			first = first or row
			if want ~= "" then
				for _, l in ipairs(row:GetDescendants()) do
					if l:IsA("TextLabel") and norm(l.Text):find(want, 1, true) then hit = row end
				end
			end
		end
	end
	local row = hit or first
	if row and fireHandlers(row.Pick) then log("Target: " .. row.Name); return true end
end

---------------------------------------------------------------- WEBHOOK
local httpRequest = (syn and syn.request) or http_request or request or (http and http.request) or (fluxus and fluxus.request)
local runsDone, sessionStart = 0, os.time()

local function webhook(title, lines, color)
	local url = S.webhook:match("^%s*(.-)%s*$")
	if url == "" then return false, "no webhook URL" end
	if not httpRequest then return false, "executor has no request()" end
	-- Discord rejects an empty description and anything over 4096 chars; game texts carry <font> rich-text tags
	local desc = table.concat(lines, "\n"):gsub("<[^>]->", "")
	if desc:match("^%s*$") then desc = "-" end
	local body = {
		username = "NCL HUB",
		embeds = { {
			title = tostring(title):gsub("<[^>]->", ""):sub(1, 250), description = desc:sub(1, 4000), color = color or 0x485CEB,
			footer = { text = "Pixel Lineage | " .. player.Name }, timestamp = DateTime.now():ToIsoDate(),
		} },
	}
	if S.pingId ~= "" then body.content = S.pingId:match("^%d+$") and ("<@" .. S.pingId .. ">") or S.pingId end
	local ok, res
	for _ = 1, 3 do
		ok, res = pcall(httpRequest, {
			Url = url, Method = "POST", Headers = { ["Content-Type"] = "application/json" }, Body = HttpService:JSONEncode(body),
		})
		-- 429 = rate limited (several chests in a row): wait what Discord asks, then retry
		if not (ok and type(res) == "table" and tonumber(res.StatusCode) == 429) then break end
		local wait = 2
		pcall(function() wait = tonumber(HttpService:JSONDecode(res.Body).retry_after) or 2 end)
		task.wait(math.clamp(wait, 0.5, 10))
	end
	if not ok or type(res) ~= "table" then return false, tostring(res) end
	local code = tonumber(res.StatusCode) or 0
	if code >= 400 then return false, "HTTP " .. code .. " " .. tostring(res.Body):sub(1, 120) end
	return code >= 200 and code < 300, "HTTP " .. code
end

-- The run-end modal ("RUN COMPLETE!" / "RUN OVER" + stats like ACTS CLEARED) and the death panel ("YOU HAVE FALLEN")
-- are each reported once while they stay on screen.
local reported = {}
local function reportEnd(list)
	for _, k in ipairs({ "RUN COMPLETE", "RUN OVER", "YOU HAVE FALLEN" }) do
		local title = find(list, k)
		local want = k == "YOU HAVE FALLEN" and S.hookDeath or (k ~= "YOU HAVE FALLEN" and S.hookClear)
		if title and want and not reported[k] then
			reported[k] = true
			if k ~= "YOU HAVE FALLEN" then runsDone += 1 end
			local box, lines = title.Parent and title.Parent.Parent or title, {}
			for _, e in ipairs(list) do
				if e[2]:IsDescendantOf(box) and e[2] ~= title and #lines < 14 then lines[#lines + 1] = "• " .. e[2].Text end
			end
			lines[#lines + 1] = ("\nRuns this session: **%d** | Uptime: %d min"):format(runsDone, (os.time() - sessionStart) // 60)
			local color = k == "RUN COMPLETE" and 0x1CDC96 or 0xF02D64
			task.spawn(function()
				local ok, info = webhook(title.Text, lines, color)
				log("Webhook " .. k .. ": " .. (ok and "sent" or info))
			end)
		elseif not title then
			reported[k] = nil
		end
	end
end

-- Skill list as the game shows it after SKILLS: each row holds a name label and either "<n> EN" or "CD <n>";
-- the header reads "SKILLS EN <cur>/<max>". New names join S.skills (the priority list) at the bottom, enabled.
local skillsDirty = true
-- syncSkills / battleMenu are declared above pickTarget
local function readSkills(list)
	local en = 0
	for _, e in ipairs(list) do local v = e[1]:match("^SKILLS EN (%d+)") if v then en = tonumber(v) end end
	local rows = {}
	for _, e in ipairs(list) do
		local cost, cd = e[1]:match("^(%d+) EN"), e[1]:match("^CD %d") or e[1]:match(" CD %d")
		if (cost or cd) and e[2].Parent and e[2].Parent.Parent and e[2].Parent.Parent:IsA("ScrollingFrame") then
			for _, l in ipairs(e[2].Parent:GetChildren()) do
				local t = l:IsA("TextLabel") and norm(l.Text) or ""
				if t ~= "" and l ~= e[2] and not t:match("^%d+ EN") and not t:match("^CD %d") then
					rows[l.Text] = { label = l, locked = cd ~= nil or tonumber(cost) > en }
				end
			end
		end
	end
	syncSkills(rows)
	return rows
end

-- rows (name -> anything) is this hero's skill set: drop names it doesn't have (configs are shared between
-- accounts), append new ones at the bottom, enabled
function syncSkills(rows)
	if not next(rows) then return end
	for i = #S.skills, 1, -1 do
		if not rows[S.skills[i].name] then table.remove(S.skills, i); skillsDirty = true end
	end
	for name in pairs(rows) do
		local known = false
		for _, sk in ipairs(S.skills) do if sk.name == name then known = true end end
		if not known then table.insert(S.skills, { name = name, on = true }); skillsDirty = true end
	end
end

-- The game's battle command menu object (PixelCommandMenu instance): has foeRows, actions (Attack/Skill/Item lists)
-- and _perform. Found once in the GC, re-found when the battle UI is rebuilt.
local menuCache
function battleMenu()
	local m = menuCache
	if m and type(m.actions) == "table" and type(m.actions.Skill) == "table" and typeof(m.box) == "Instance" and m.box.Parent then return m end
	menuCache = nil
	for _, t in ipairs(gcTables({ "foeRows", "actions" })) do
		if type(t) == "table" and rawget(t, "foeRows") and type(rawget(t, "actions")) == "table" and type(t._perform) == "function" then
			menuCache = t
			break
		end
	end
	m = menuCache
	return (m and type(m.actions.Skill) == "table") and m or nil
end

---------------------------------------------------------------- PARTY + POTION
local RPGCommand
task.spawn(function()
	local pb = game:GetService("ReplicatedStorage"):WaitForChild("PlatformBattles", 20)
	local remotes = pb and pb:WaitForChild("Remotes", 20)
	RPGCommand = remotes and remotes:WaitForChild("RPGCommand", 20)
end)
local lastInvite = -999

-- Listed names (username or display name, comma separated) that are in this server, excluding us.
local function invitees()
	local out = {}
	for raw in S.inviteList:gmatch("[^,]+") do
		local want = raw:match("^%s*(.-)%s*$"):lower()
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= player and want ~= "" and (p.Name:lower() == want or p.DisplayName:lower() == want) then out[#out + 1] = p end
		end
	end
	return out
end

-- Our HP from the battle PARTY tab: the member row carrying our name, its "<hp>/<max>" label.
local function myHpPct()
	local page = pgui:FindFirstChild("PartyPage", true)
	if not page then return end
	local me1, me2 = norm(player.Name), norm(player.DisplayName)
	for _, row in ipairs(page:GetChildren()) do
		local mine, hp, max = false, nil, nil
		for _, l in ipairs(row:GetDescendants()) do
			if l:IsA("TextLabel") then
				local t = norm(l.Text)
				if t == me1 or t == me2 then mine = true end
				local a, b = l.Text:match("^(%d+)/(%d+)$")
				if a then hp, max = tonumber(a), tonumber(b) end
			end
		end
		if mine and hp and max and max > 0 then return hp / max * 100, row end
	end
end

-- SATCHEL -> "HP Potion" -> (CHOOSE AN ALLY) our own party row. The satchel allows 3 potions per battle; when the
-- row is missing or used up we back out and leave potions alone for 20s.
local potionPause = -999
local function usePotion()
	if os.clock() - potionPause < 20 then return false end
	local pct, row = myHpPct()
	if not pct or pct >= (tonumber(S.potionPct) or 40) then return false end
	-- the command button itself: a plain "SATCHEL" text match can hit the Info panel's title instead
	local cmds = pgui:FindFirstChild("PixelCommands", true)
	local item = cmds and cmds:FindFirstChild("Commands") and cmds.Commands:FindFirstChild("Item")
	if not item then return false end
	press(item); task.wait(0.4)
	local sl = scan()
	-- list title "HP <left>/3 | BREWS ..." : none left this run -> stop trying until the next run starts (reset on join / replay)
	for _, e in ipairs(sl) do
		if e[1]:match("^HP 0 3") then potionPause = math.huge; press(find(sl, TXT.back)); task.wait(0.3); return false end
	end
	local potion = find(sl, TXT.potion)
	if potion then
		press(potion); task.wait(0.4)
		if find(scan(), TXT.ally) and row:FindFirstChild("Pick") then fireHandlers(row.Pick); task.wait(0.4) end
		-- used up / not allowed: the press is ignored and the potion list stays open
		if not find(scan(), TXT.potion) then log(("Potion at %d%% HP"):format(pct)); return true end
	end
	potionPause = os.clock()
	press(find(scan(), TXT.back)); task.wait(0.3)
	return false
end

-- Our turn = the battle command menu's own ATTACK button is on screen. A plain "ATTACK" text match also hits the gear
-- window's stat list ("+42 ATTACK"), which made the macro think it was in battle while standing in the castle.
local function attackButton()
	local cmds = pgui:FindFirstChild("PixelCommands", true)
	local b = cmds and cmds:FindFirstChild("Commands") and cmds.Commands:FindFirstChild("Attack")
	b = b or (cmds and cmds:FindFirstChild("Attack", true)) -- other layouts (phone) may nest the command buttons deeper
	return (b and b:IsA("GuiObject") and shown(b)) and b or nil
end

---------------------------------------------------------------- AUTO SELL
-- Gear lives in the client's profile table (profile.gearBag[uid] = { rarity, base, locked, ... }); worn pieces are the
-- values of profile.gear / profile.vanity. The game's own bulk sell is RPGCommand "GearSellMany" { uids }.
local GearConfig
pcall(function()
	local m = game:GetService("ReplicatedStorage"):FindFirstChild("GearConfig", true)
	if m then
		if setIdentity then pcall(setIdentity, 2) end -- shared module; a game-level require works from any context
		GearConfig = require(m)
	end
end)
local lastSell, sellNote = -999, "Auto Sell: idle"

-- Several profile snapshots can sit in memory at once, including stale ones (pieces already sold still listed).
-- No version field exists; the newest has the most gold (farming and selling only raise it), bag size breaks ties.
local function gearProfile()
	local best, bg, bn = nil, -1, -1
	for _, t in ipairs(gcTables({ "gearBag" })) do
		if type(t) == "table" and type(rawget(t, "gearBag")) == "table" then
			local n, g = 0, tonumber(rawget(t, "gold")) or 0
			for _ in pairs(t.gearBag) do n += 1 end
			if g > bg or (g == bg and n > bn) then best, bg, bn = t, g, n end
		end
	end
	return best
end

-- type from the item definition: GearConfig.Items[base].kind = Weapon / Helmet / Chest / Legs / Relic / Scroll
-- (GearConfig.SlotsFor returns nothing for bag pieces, so every piece used to be skipped)
local function gearType(item)
	local def = GearConfig.Items and GearConfig.Items[tostring(item.base or "")]
	local kind = def and def.kind and tostring(def.kind):lower()
	return kind == "helmet" and "head" or kind
end

local function sellPass(manual)
	lastSell = os.clock()
	local p = gearProfile()
	if not p or not GearConfig then sellNote = "Auto Sell: gear data not found"; return 0 end
	local worn = {}
	for _, list in ipairs({ p.gear or {}, p.vanity or {} }) do for _, uid in pairs(list) do worn[uid] = true end end
	local uids, gold = {}, 0
	for uid, it in pairs(p.gearBag) do
		local t = gearType(it)
		local canSell = pcall(GearConfig.CanSell, it) and GearConfig.CanSell(it)
		if type(it) == "table" and not worn[uid] and it.locked ~= true and canSell
			and S.sellRarity[tostring(it.rarity)] and t and S.sellType[t] then
			uids[#uids + 1] = uid
			gold += tonumber(select(2, pcall(GearConfig.SellPrice, it))) or 0
		end
	end
	if #uids > 0 then
		if RPGCommand then RPGCommand:FireServer("GearSellMany", { uids = uids }) end
		sellNote = ("Sold %d piece(s) for ~%d gold (%s)"):format(#uids, gold, os.date("%H:%M:%S"))
		log(sellNote)
	elseif manual then
		sellNote = "Nothing matches the rarity / type filter."
	end
	return #uids
end

-- Torment tier: the TORMENT button reads "TORMENT <roman>", stepped with the "<" / ">" buttons beside it.
local function roman(s)
	local v, n, prev = { I = 1, V = 5, X = 10, L = 50, C = 100, D = 500, M = 1000 }, 0, 0
	for i = #s, 1, -1 do
		local d = v[s:sub(i, i)] or 0
		n += d < prev and -d or d
		prev = math.max(prev, d)
	end
	return n
end
local function pickTorment()
	local want = tonumber(S.tormentStage)
	if not want or want < 1 then return end
	for _ = 1, 120 do
		local btn = find(scan(), "TORMENT")
		if not btn then return end
		local cur = roman(norm(btn.Text):match("TORMENT ([IVXLCDM]+)") or "")
		if cur == want or cur == 0 then return end
		local root, arrow = btn.Parent and btn.Parent.Parent or pgui, nil
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("TextButton") and d.Text:match("^%s*" .. (cur < want and ">" or "<") .. "%s*$") and shown(d) then arrow = d; break end
		end
		if not arrow then log("Torment arrows not found"); return end
		press(arrow); task.wait(0.15)
	end
end

-- lives come with every BattleUpdated (d.lives); losing the last one wipes the character's gear
local livesLeft
local function lowLives() return S.stopAtLife and livesLeft ~= nil and livesLeft <= 1 end
local function step()
	local list = scan()
	reportEnd(list)
	-- "UNFINISHED BATTLE" after a reconnect: go back into the fight before anything else (castle SET OUT is also on screen)
	local resume = find(list, "RESUME BATTLE")
	if resume then press(resume); log("Resume battle"); return 3 end
	-- death panel (PixelDeath.Fallen): RETURN HOME costs the light already lost; CheatDeath is a paid revive, never pressed
	do
		local fallen = pgui:FindFirstChild("PixelDeath")
		local home = fallen and fallen:FindFirstChild("ReturnHome", true)
		if home and shown(home) and S.autoContinue then press(home); log("Fallen: return home"); return 3 end
	end
	-- character select: main menu CHARACTER SELECT -> SlotN's ENTER. Only ENTER is pressed; locked slots say UNLOCK (Robux)
	if S.autoSlot then
		local gate = pgui:FindFirstChild("PlatformBattlesUI") and pgui.PlatformBattlesUI:FindFirstChild("Root")
		gate = gate and gate:FindFirstChild("ProfileGate")
		local card = gate and gate:FindFirstChild("CharacterSlotsPage")
		card = card and card:FindFirstChild("Slot" .. S.slotNum, true)
		local enter = card and card:FindFirstChild("Action", true)
		if enter and shown(enter) then
			if norm(enter.Text):sub(1, 5) == "ENTER" then press(enter); log("Enter slot " .. S.slotNum); return 3 end
			log("Slot " .. S.slotNum .. " is locked"); return 5
		end
		local open = gate and gate:FindFirstChild("CharacterSelect", true)
		if open and shown(open) then press(open); return 1.5 end
	end
	if S.autoSell and os.clock() - lastSell > 30 and not attackButton() then sellPass() end
	local attack = attackButton()

	if attack and S.autoPotion and usePotion() then return 1.5 end
	if attack and S.autoPotion then list = scan(); attack = attackButton() end

	if (S.autoAttack or S.autoSkill) and attack then
		-- hidden path: the battle menu object holds the hero's skills (actions.Skill, enabled = false while on cooldown
		-- or short on EN) and performs one with :_perform(action) - the SKILLS list never opens on screen
		local menu = S.autoSkill and battleMenu()
		if menu then
			local rows = {}
			for _, a in ipairs(menu.actions.Skill) do
				if type(a) == "table" and a.name then rows[tostring(a.name)] = { action = a, locked = a.enabled == false } end
			end
			syncSkills(rows)
			for _, sk in ipairs(S.skills) do
				local row = sk.on and rows[sk.name]
				if row and not row.locked then
					task.spawn(function()
						if setIdentity then pcall(setIdentity, 2) end
						pcall(menu._perform, menu, row.action)
					end)
					task.wait(0.3)
					log("Skill: " .. sk.name); pickTarget()
					return 1.5
				end
			end
		elseif S.autoSkill then
			press(find(list, TXT.skills)); task.wait(0.4)
			local rows = readSkills(scan())
			-- first enabled skill in priority order that isn't on cooldown and fits the current EN
			for _, sk in ipairs(S.skills) do
				local row = sk.on and rows[sk.name]
				if row and not row.locked then
					press(row.label); log("Skill: " .. sk.name); pickTarget()
					return 1.5
				end
			end
			press(find(scan(), TXT.back)); task.wait(0.3)
			attack = attackButton()
		end
		if attack then press(attack); log("Attack"); pickTarget() end
		return 1.5
	end

	if S.autoJoin and lowLives() then
		-- one life left: no new run. Stops once back in the castle (a run already going is still played out)
		if find(list, TXT.setOut) or find(list, TXT.solo) or find(list, TXT.start) then
			S.running = false; log(("Stopped: %d life left (safety)"):format(livesLeft))
			task.spawn(webhook, "⚠️ Macro stopped", { ("Only **%d** life left - stopped before a new run so the gear is not wiped."):format(livesLeft) }, 0xF02D64)
		end
		return 1
	end
	if S.autoJoin then
		-- Picking a difficulty re-renders the window: every button found before it is destroyed, so re-scan.
		local function pickDiff()
			potionPause = -999 -- new run: potions are 3 again
			press(find(list, S.difficulty:upper())); task.wait(0.4)
			if S.difficulty == "Torment" then pickTorment() end
			return scan()
		end
		-- own lobby (START RUN (n/max) or WAITING FOR READY): invite the listed players every 20s, and with Wait for
		-- party hold the start until everyone listed who is in this server has joined
		local startBtn = find(list, TXT.start)
		if (startBtn or find(list, TXT.waitReady)) and S.mode == "Multiplayer" and S.autoInvite then
			local want = invitees()
			if os.clock() - lastInvite > 20 and #want > 0 then
				lastInvite = os.clock()
				for _, p in ipairs(want) do
					if RPGCommand then RPGCommand:FireServer("RunLobby", { action = "invite", userId = p.UserId }) end
				end
				log("Invited " .. #want .. " player(s)")
			end
			local n = startBtn and tonumber(norm(startBtn.Text):match("START RUN (%d+)")) or 0
			if S.waitParty and (not startBtn or n < 1 + #want) then
				status = ("Waiting for party %d/%d"):format(n, 1 + #want)
				return 2
			end
		end
		if startBtn then
			press(find(pickDiff(), TXT.start)); log("Start run (" .. S.difficulty .. ")")
			return 3
		end
		-- someone else's invite popup
		if S.autoAccept and find(list, TXT.invite) then
			for _, e in ipairs(list) do
				if e[2]:IsA("TextButton") and (e[1] == "ACCEPT" or e[1] == "JOIN") then press(e[2]); log("Accepted party invite"); return 3 end
			end
		end
		-- SOLO RUN screen: difficulty + "SOLO!" (it also shows HOST A LOBBY, so check it first)
		-- Confirm = exact-text TextButton inside that window: loose matching hits the title or the castle-bar SET OUT.
		local soloTitle = S.mode == "Solo" and find(list, TXT.soloRun)
		if soloTitle then
			local win = soloTitle:FindFirstAncestor("Window") or soloTitle.Parent
			for _, e in ipairs(pickDiff()) do
				if e[2]:IsA("TextButton") and e[2]:IsDescendantOf(win) and table.find(TXT.soloGo, e[1]) then
					press(e[2]); log("Solo run (" .. S.difficulty .. ")")
					return 4
				end
			end
		end
		if S.mode == "Multiplayer" and find(list, TXT.host) then
			if S.mpMode == "Queue" and os.clock() - lastQueue < 60 then status = "In queue..."; return 1 end
			local fresh = pickDiff()
			if S.mpMode == "Host" then press(find(fresh, TXT.host)); log("Host lobby")
			else press(find(fresh, TXT.queue)); lastQueue = os.clock(); log("Random queue") end
			return 2
		end
		local solo = find(list, TXT.solo)
		if solo then
			if S.mode == "Solo" then press(solo); log("Play solo") else press(find(list, TXT.party)); log("Find a party") end
			return 2
		end
		local setOut = find(list, TXT.setOut)
		if setOut then press(setOut); log("Set out"); return 2.5 end
	end

	-- Auto Replay: PLAY AGAIN on the run-end screen (off = Auto Next falls back to RETURN TO CASTLE)
	if S.autoReplay and not lowLives() then
		local again = find(list, "PLAY AGAIN")
		if again then potionPause = -999; press(again); log("Replay"); return 2 end
	end
	do -- path, event and chest each have their own toggle; Auto Next Act only gates the continue buttons below
		-- run map: cards RunMap.Cards.OptionN, each with two rows of 5 star icons (DANGER at y=7, REWARD at y=29). Pick the card whose chosen row is closest to S.pathStars; ties -> leftmost.
		local sign = S.autoPath and find(list, TXT.path)
		local cards = sign and sign:FindFirstAncestor("Cards")
		if cards then
			local best, bestDiff, bestN = nil, math.huge, 0
			local want = tonumber(S.pathStars) or 3
			for i = 1, 6 do
				local card = cards:FindFirstChild("Option" .. i)
				if card and card.Visible then
					-- star rows = frames holding "Icon" children; DANGER is the upper row, REWARD the lower one.
					-- Ordered by on-screen Y, not a fixed offset, so scaled phone layouts read the same.
					local rows = {}
					for _, row in ipairs(card:GetDescendants()) do
						if row:IsA("Frame") and row:FindFirstChild("Icon") then rows[#rows + 1] = row end
					end
					table.sort(rows, function(a, b) return a.AbsolutePosition.Y < b.AbsolutePosition.Y end)
					local row, n = rows[S.pathBy == "Danger" and 1 or #rows], 0
					-- each star is an "Icon" frame wrapping the drawn sprite named "star" or "starEmpty"
					for _, c in ipairs(row and row:GetChildren() or {}) do
						if c.Name == "Icon" and c:FindFirstChild("star", true) and not c:FindFirstChild("starEmpty", true) then n += 1 end
					end
					if math.abs(n - want) < bestDiff then best, bestDiff, bestN = card, math.abs(n - want), n end
				end
			end
			if best then press(best); log(("Path: %s (%s %d*)"):format(best.Name, S.pathBy, bestN)); return 2 end
		end
		-- event card ("Make your choice."): options are blank TextButtons whose first label (y=8) is the name; dimmed
		-- (BackgroundTransparency 0.5) = not available. TO BATTLE stays disabled until one is chosen.
		if S.autoEvent and find(list, TXT.choose) then
			local opts, prefer = {}, {}
			for w in S.eventPrefer:gmatch("[^,]+") do prefer[#prefer + 1] = norm(w) end
			-- name = the option button's topmost label (on-screen Y, so scaled phone layouts work too)
			local top, eventGui = {}, find(list, TXT.choose):FindFirstAncestorWhichIsA("ScreenGui")
			for _, e in ipairs(list) do
				local b = e[2].Parent
				if b:IsA("TextButton") and b.Text == "" and b.BackgroundTransparency < 0.5 and b:IsDescendantOf(eventGui) then
					if not top[b] or e[2].AbsolutePosition.Y < top[b][2].AbsolutePosition.Y then top[b] = e end
				end
			end
			for b, e in pairs(top) do opts[#opts + 1] = { e[1], b } end
			-- HP on the run map: the PARTY slot's "<hp>/<max>" label. Offer Blood costs 20% HP, so it is skipped below the floor.
			local hpPct
			local rm = pgui:FindFirstChild("PlatformBattlesRunMap")
			for _, l in ipairs(rm and rm:GetDescendants() or {}) do
				if l:IsA("TextLabel") and l:FindFirstAncestor("Party") then
					local a, b = l.Text:match("^(%d+)/(%d+)$")
					if a and tonumber(b) > 0 then hpPct = tonumber(a) / tonumber(b) * 100; break end
				end
			end
			local pick
			for _, w in ipairs(prefer) do
				for _, o in ipairs(opts) do
					local blood = o[1] == "OFFER BLOOD" and hpPct and hpPct < (tonumber(S.bloodMinHp) or 50)
					if not pick and o[1] == w and not blood then pick = o end
				end
			end
			if not pick and hpPct and hpPct < (tonumber(S.bloodMinHp) or 50) then
				for i = #opts, 1, -1 do if opts[i][1] == "OFFER BLOOD" then table.remove(opts, i) end end
			end
			if not pick then
				-- ponytail: random among options that aren't a plain exit; exit only when nothing else is offered
				local real = {}
				for _, o in ipairs(opts) do if o[1] ~= "WALK AWAY" and o[1] ~= "LEAVE" then real[#real + 1] = o end end
				if #real == 0 then real = opts end
				pick = real[math.random(#real)]
			end
			if pick then press(pick[2]); log("Event: " .. pick[1]); return 1.5 end
		end
		-- chest / loot reveal: the button reads "<CLICK/TAP/...> TO OPEN" then "... TO CONTINUE"
		if S.autoChest then
			for _, e in ipairs(list) do
				if e[2]:IsA("TextButton") and (e[1]:match("TO OPEN$") or e[1]:match("TO CONTINUE$")) then
					press(e[2]); log("Chest: " .. e[1]); return 0.3 -- tap through the reveal animation
				end
			end
		end
		-- map node screens (path card, camp, event) end on TO BATTLE: part of Next Path, not Next Act
		local toBattle = S.autoPath and find(list, "TO BATTLE")
		if toBattle then press(toBattle); log("Click TO BATTLE"); return 1.5 end
		for _, w in ipairs(S.autoContinue and TXT.continue or {}) do
			local c = find(list, w)
			if c then press(c); log("Click " .. w); return 1.5 end
		end
	end

	status = "Waiting..."
	return 0.3 -- poll fast: the turn menu / next screen is acted on as soon as it shows (one scan ~8ms on a busy screen)
end

task.spawn(function()
	while alive do
		local w = 0.5
		if S.running then
			local ok, r = pcall(step)
			if ok then w = r else log("Error: " .. tostring(r)); w = 2 end
		end
		if refresh then refresh() end
		task.wait(w / ((getgenv and getgenv().NCL_SPEED) or 1)) -- pauses between macro steps follow Game Speed
	end
end)

---------------------------------------------------------------- DEFENSE LOG
-- One line per enemy attack: what the server asked (normal / heavy / barrage), when we pressed vs the target (ms),
-- the server's verdict and any damage that still landed. Shown in the Logs tab, kept in DIR/defense_log.txt.
local dlogLines, dlogPending = {}, {}
local function dlog(line)
	table.insert(dlogLines, 1, os.date("%H:%M:%S") .. "  " .. line)
	if #dlogLines > 80 then table.remove(dlogLines) end
	pcall(function()
		ensureDir()
		local path, text = DIR .. "/defense_log.txt", os.date("%H:%M:%S") .. "  " .. line .. "\n"
		if isfile(path) then appendfile(path, text) else writefile(path, text) end -- appendfile needs an existing file
	end)
end
local function dlogPress(token, delta)
	local p = dlogPending[token]
	if p then p.presses[#p.presses + 1] = ("%+dms"):format(math.floor(delta * 1000 + 0.5)) end
end
local stateConn = { Disconnect = function() end }
task.spawn(function()
	local pb = game:GetService("ReplicatedStorage"):WaitForChild("PlatformBattles", 20)
	local remotes = pb and pb:WaitForChild("Remotes", 20)
	local state = remotes and remotes:WaitForChild("RPGState", 20)
	if state then
		stateConn = state.OnClientEvent:Connect(function(name, d)
			if type(d) ~= "table" then return end
			if type(d.lives) == "number" then livesLeft = d.lives end
			-- chest loot straight from the server event (BossChestLoot, ...): same on PC and phone, no screen reading.
			-- Payload shape isn't fixed, so every string/number leaf is posted as "path: value".
			if S.hookChest and type(name) == "string" and (name:find("Loot") or name:find("Chest")) then
				local lines = {}
				local function walk(t, path, depth)
					for k, v in pairs(t) do
						local p = path == "" and tostring(k) or (path .. "." .. tostring(k))
						if type(v) == "table" and depth < 4 then walk(v, p, depth + 1)
						elseif (type(v) == "string" or type(v) == "number" or type(v) == "boolean") and #lines < 25 then
							lines[#lines + 1] = "• " .. p .. ": " .. tostring(v)
						end
					end
				end
				-- BossChestLoot: { items = { { name = "10080 Gold", rarity = "Rare", kind, gearKind?, quantity? }, ... } }
				if type(d.items) == "table" and #d.items > 0 then
					local icon = { Common = "⚪", Uncommon = "🟢", Rare = "🔵", Epic = "🟣", Legendary = "🟠", Mythic = "🔴" }
					for _, it in ipairs(d.items) do
						if type(it) == "table" and #lines < 25 then
							local extra = it.gearKind and (" · " .. tostring(it.gearKind)) or ""
							lines[#lines + 1] = ("%s **%s** — %s%s"):format(icon[it.rarity] or "▫️", tostring(it.name or it.id or "?"), tostring(it.rarity or "?"), extra)
						end
					end
				else
					walk(d, "", 0)
				end
				dlog("CHEST " .. name .. " " .. HttpService:JSONEncode(d):sub(1, 400))
				task.spawn(function()
					local ok, info = webhook(name == "BossChestLoot" and "🎁 Boss chest opened" or ("🎁 " .. name), lines, 0xF5B942)
					log("Webhook chest: " .. (ok and "sent" or info))
				end)
			end
			if name == "DefenseTimingStarted" then
				local kind = type(d.marks) == "table" and ("BARRAGE x" .. #d.marks) or (d.heavy and "HEAVY" or "normal")
				dlogPending[tostring(d.token)] = { kind = kind, what = tostring(d.actionName or d.title or "?"), presses = {}, at = os.clock(),
					win = math.floor((tonumber(d.perfect) or 0) * 1000 + 0.5) }
			elseif name == "DefenseTimingResolved" then
				local p = dlogPending[tostring(d.token)]
				dlogPending[tostring(d.token)] = nil
				local res = d.outcome and tostring(d.outcome) or (type(d.outcomes) == "table" and table.concat(d.outcomes, ",") or "?")
				dlog(("%s %s | perfect ±%sms | pressed %s | server: %s (%s)"):format(p and p.kind or "?", p and p.what or "?",
					p and p.win or "?", p and (#p.presses > 0 and table.concat(p.presses, " ") or "NONE") or "?", res, tostring(d.reason or "")))
			elseif name == "CombatVFX" and d.kind == "DamageIndicator" and d.targetUserId == player.UserId and (tonumber(d.amount) or 0) > 0 and not d.healing then
				dlog(("!! HIT %s for %s%s%s"):format(tostring(d.actionName or "?"), tostring(d.amount), d.critical and " CRIT" or "", d.dot and " (DoT)" or ""))
			end
		end)
	end
end)

---------------------------------------------------------------- GAME SPEED
-- Turns are paced by the server, but most of the time between them is the client waiting: battle animations,
-- the enemy "presentation" that gates DefenseTimingReady, the delay before a QTE result is sent, tweens, and this
-- macro's own pauses. All of those go through task.wait / task.delay / wait / delay / TweenService:Create, so those
-- are hooked once per VM and divided by getgenv().NCL_SPEED. QTE timing reads os.clock / GetServerTimeNow and is
-- not touched, so perfect presses stay exact.
---------------------------------------------------------------- FPS BOOST
-- Battles are drawn in PlayerGui; the 3D world behind them is most of the frame cost. Measured on a slow executor:
-- 22fps with 200ms hitches -> 58fps steady (lowest quality + 3D rendering off). Dodge timing needs steady frames.
local boostOn, boostQuality = false, nil
local function applyBoost(on)
	if on == boostOn then return end
	boostOn = on
	pcall(function() RunService:Set3dRenderingEnabled(not on) end)
	pcall(function()
		if on then
			boostQuality = settings().Rendering.QualityLevel
			settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
		elseif boostQuality then
			settings().Rendering.QualityLevel = boostQuality
		end
	end)
	if on and setfpscap then pcall(setfpscap, 60) end
end

local function speed() return (getgenv and getgenv().NCL_SPEED) or 1 end
-- installed only once a speed above 1x is picked: on some mobile executors a hooked task.wait can't yield, so 1x
-- must leave the game's waits untouched
local function installSpeedHooks()
	if not (getgenv and not getgenv().NCL_SPEED_HOOKED and hookfunction and newcclosure) then return end
	getgenv().NCL_SPEED_HOOKED = true
	-- only the game's own waits: this script's short "press, let the UI react, rescan" pauses stay real-time
	local function scaled(t)
		local s = speed()
		if s == 1 or type(t) ~= "number" or (checkcaller and checkcaller()) then return t end
		return t / s
	end
	-- hookfunction patches the function in place and RETURNS the original; calling the old reference would recurse
	for _, fn in ipairs({ task.wait, task.delay, wait, delay }) do
		pcall(function()
			local orig
			orig = hookfunction(fn, newcclosure(function(t, ...) return orig(scaled(t), ...) end))
		end)
	end
	pcall(function()
		local old
		old = hookmetamethod(game, "__namecall", newcclosure(function(self, info, ...)
			if speed() ~= 1 and self == TweenService and typeof(info) == "TweenInfo" and not (checkcaller and checkcaller()) and getnamecallmethod() == "Create" then
				local s = speed()
				-- rebuilt TweenInfo; reading/constructing here is not a namecall, so the method above stays "Create"
				local ti = TweenInfo.new(info.Time / s, info.EasingStyle, info.EasingDirection, info.RepeatCount, info.Reverses, info.DelayTime / s)
				return old(self, ti, ...)
			end
			return old(self, info, ...)
		end))
	end)
end
if speed() > 1 then installSpeedHooks() end

---------------------------------------------------------------- AUTO QTE
-- Hooks the game's PixelQTE class (found in GC, shared by every instance through __index) and presses its own
-- pressHandler at the perfect moment, from inside the per-frame step the game runs via self:_run(step).
-- Attack marks (archer/fist/spear/bard): each round starts with _pip(n, "active"); progress = elapsed / targetSeconds,
--   PERFECT when progress hits (openFrom + openTo) / 2. Graded on the client, server gets ThiefSlashResult {hits}.
-- Defense: graded on the server from pressedAt; perfect at startedAt + target * duration (+-32ms).
local qte = getgenv and getgenv().NCL_PL_QTE
if not qte and getgc then
	for _, t in ipairs(gcTables({ "_defense", "_timedMarks", "_send" })) do
		if type(t) == "table" and rawget(t, "_defense") and rawget(t, "_timedMarks") and rawget(t, "_send") then qte = t; break end
	end
end
local gcInfo = qte and "qte-from-gc" or "qte-not-in-gc"
-- getgc(true) is missing / limited on some mobile executors: require the class module itself (cached, same table)
if not qte then
	local mods = game:GetService("ReplicatedStorage"):GetDescendants()
	for _, m in ipairs(player:FindFirstChild("PlayerScripts") and player.PlayerScripts:GetDescendants() or {}) do mods[#mods + 1] = m end
	for _, m in ipairs(mods) do
		if m:IsA("ModuleScript") and m.Name:find("QTE") then
			if setIdentity then pcall(setIdentity, 2) end
			local ok, t = pcall(require, m)
			if ok and type(t) == "table" and rawget(t, "_defense") then qte = t; gcInfo = "qte-from-require"; break end
		end
	end
end
if qte then
	-- originals kept on the class so a re-run wraps them again instead of wrapping our own wrappers
	qte.nclOrig = qte.nclOrig or { open = qte._open, send = qte._send, defense = qte._defense }
	local o = qte.nclOrig
	o.run, o.pip, o.marks = o.run or qte._run, o.pip or qte._pip, o.marks or qte._timedMarks
	do
		local open, send, defense = o.open, o.send, o.defense
		qte._open = function(self, theme, pips, ...)
			self.nclPips = tonumber(pips) or 0
			local r = open(self, theme, pips, ...)
			-- hidden panel still runs its per-frame step, so the auto press keeps working
			if qte.nclHide and self.root then self.root.Visible = false end
			return r
		end
		qte._send = function(self, name, data, ...)
			if qte.nclOn and name == "ThiefSlashResult" and type(data) == "table" and (self.nclPips or 0) > 0 then
				data.hits = math.max(tonumber(data.hits) or 0, self.nclPips)
			end
			-- Defense presses carry pressedAt = the exact perfect moment instead of whatever the clock read on the frame
			-- that pressed. The server accepts a claimed time up to (2 x ping + 80ms, max 300ms) older than the packet,
			-- so a frame hitch or slow send no longer turns a perfect into TOO LATE (low-fps executors).
			if qte.nclOn and name == "DefenseTimingInput" and type(data) == "table" and self.nclAim then
				local now = Workspace:GetServerTimeNow()
				if now >= self.nclAim - 0.05 and now <= self.nclAim + 0.3 then data.pressedAt = self.nclAim end
				self.nclAim = nil
			end
			if name == "ThiefSlashResult" and type(data) == "table" then dlog(("ATK QTE: %s / %s hits sent"):format(tostring(data.hits), tostring(self.nclPips))) end
			return send(self, name, data, ...)
		end
		-- presses go out 20ms early while still claiming the exact moment: the packet then lands inside the server's
		-- latency credit even with ~40ms of extra jitter, and an early arrival still grades inside the window
		local SEND_LEAD = 0.02
		qte._run = function(self, step, ...)
			return o.run(self, function(...)
				local r = step(...)
				-- The perfect window shrinks to 18ms on a dodge streak and frames can be 50ms+ apart when FPS dips (a press
				-- landed +23ms late that way), so from 120ms before the moment, spin inside this frame until it arrives and
				-- press then (costs one frame hitch). The spin is capped at 130ms of real time: server time may only tick per
				-- frame, and an uncapped wait on it inside a frame never ends (that froze the game once).
				local function spinUntil(target, clock)
					local cap = os.clock() + 0.13
					while clock() < target and os.clock() < cap do end
				end
				local now = Workspace:GetServerTimeNow()
				local at, m, hits = self.nclPressAt, self.nclMarks, self.nclStrikes
				if at and self.defense and self.defense.token == self.nclPressToken and now >= at - 0.12 then
					self.nclPressAt = nil
					spinUntil(at - SEND_LEAD, function() return Workspace:GetServerTimeNow() end) -- claims `at` exactly (see _send)
					self.nclAim = at; if self.pressHandler then self.pressHandler() end
					dlogPress(self.nclPressToken, Workspace:GetServerTimeNow() - at)
				elseif hits and hits[1] and self.defense and self.defense.token == self.nclPressToken and now >= hits[1] - 0.12 then
					-- barrage: one press per strike, in order
					local t = table.remove(hits, 1)
					spinUntil(t - SEND_LEAD, function() return Workspace:GetServerTimeNow() end)
					self.nclAim = t; if self.pressHandler then self.pressHandler() end
					dlogPress(self.nclPressToken, Workspace:GetServerTimeNow() - t)
				elseif m and m.at and os.clock() >= m.at - 0.05 then
					local t = m.at
					m.at = nil
					spinUntil(t, os.clock)
					if self.pressHandler then self.pressHandler() end
				end
				return r
			end, ...)
		end
		-- Real clicks / keys reach the QTE through _press (the game treats ANY left click as a press, clicks on this
		-- window included). One stray click before the mark used up the defense ("Miss, TOO EARLY") and blocked our
		-- exact press. With Perfect QTE on only the script presses (it calls pressHandler directly, not _press).
		o.press = o.press or qte._press
		qte._press = function(self, ...)
			if qte.nclOn then return end
			return o.press(self, ...)
		end
		qte._pip = function(self, n, state, ...)
			local r = o.pip(self, n, state, ...)
			local m = self.nclMarks
			if m and state == "active" then m.at = os.clock() + m.wait end -- the round's clock starts this frame
			return r
		end
		qte._timedMarks = function(self, d, style, ...)
			self.nclMarks, self.nclPressAt = nil, nil
			if qte.nclOn and type(d) == "table" then
				-- same clamps as the game's own grading
				local from = math.clamp(tonumber(d.openFrom) or 0.35, 0, 1)
				local to = math.clamp(tonumber(d.openTo) or 0.8, from, 1)
				local secs = math.clamp(tonumber(d.targetSeconds) or 0.78, 0.15, 1.25)
				self.nclMarks = { wait = (from + to) / 2 * secs }
			end
			local r = o.marks(self, d, style, ...)
			-- Game Speed above 1x: the server only waits for ThiefSlashResult {hits}, so send the full count right away
			-- and close the panel instead of playing ~3.5s of rounds (closing ends the rounds, so nothing is sent twice)
			if qte.nclOn and speed() > 1 and type(d) == "table" and (self.nclPips or 0) > 0 then
				self:_send("ThiefSlashResult", { battleId = tostring(d.battleId or ""), token = tostring(d.token or ""), hits = self.nclPips })
				task.defer(function() if self.token == tostring(d.token or "") then self:_close(0) end end)
			end
			return r
		end
		-- barrage (several strikes, the "crit" chains): strike i lands at startedAt + marks[i] * duration
		o.barrage = o.barrage or qte._barrage
		qte._barrage = function(self, d, ...)
			self.nclPressAt, self.nclMarks, self.nclStrikes = nil, nil, nil
			if qte.nclOn and type(d) == "table" and type(d.startedAt) == "number" and type(d.marks) == "table" then
				local dur, list = math.max(0.2, tonumber(d.duration) or 2), {}
				for _, v in ipairs(d.marks) do list[#list + 1] = d.startedAt + math.clamp(tonumber(v) or 0.5, 0, 1) * dur end
				table.sort(list)
				self.nclStrikes, self.nclPressToken = list, tostring(d.token or "")
			end
			return o.barrage(self, d, ...)
		end
		qte._defense = function(self, d, ...)
			self.nclPressAt, self.nclMarks, self.nclStrikes = nil, nil, nil
			if qte.nclOn and type(d) == "table" and type(d.startedAt) == "number" and type(d.target) == "number" then
				self.nclPressAt = d.startedAt + d.target * (tonumber(d.duration) or 0.85)
				self.nclPressToken = tostring(d.token or "")
			end
			return defense(self, d, ...)
		end
		if getgenv then getgenv().NCL_PL_QTE = qte end
	end
end

---------------------------------------------------------------- DEBUG FILE + ANTI-AFK
-- NCL HUB/PixelLineage/debug.txt, rewritten every 15s (file writes hitch some executors): visible texts, the button behind each, and the log.
if writefile then
	task.spawn(function()
		while alive do
			pcall(function()
				local out = { "== " .. os.date() .. "  running=" .. tostring(S.running) .. "  status=" .. status,
					("executor=%s  touch=%s  screen=%s  getgc=%s  qte=%s  menu=%s  getconnections=%s  hookfunction=%s"):format(
						identifyexecutor and tostring((identifyexecutor())) or "?", tostring(UIS.TouchEnabled),
						tostring(Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize), gcInfo, tostring(qte ~= nil),
						tostring(menuCache ~= nil), tostring(getconnections ~= nil), tostring(hookfunction ~= nil)),
					"", "== VISIBLE TEXT" }
				for _, e in ipairs(scan()) do
					local b = buttonOf(e[2])
					out[#out + 1] = string.format("%q [%s] %s | %s", e[1], e[2].ClassName, e[2]:GetFullName(), b and b:GetFullName() or "no button")
				end
				out[#out + 1] = ""; out[#out + 1] = "== LOG"
				for _, l in ipairs(logs) do out[#out + 1] = l end
				ensureDir()
				writefile(DIR .. "/debug.txt", table.concat(out, "\n"))
			end)
			task.wait(15)
		end
	end)
end

-- Auto reconnect: Roblox shows its error prompt on a kick / lost connection; rejoin the game after a short pause.
-- Back in the castle, "UNFINISHED BATTLE" is answered with RESUME BATTLE (never ABANDON, which costs a life).
-- (GuiService.ErrorMessageChanged needs RobloxScript capability; the error prompt frame appearing under
-- CoreGui.RobloxPromptGui.promptOverlay is readable from here)
local reconnectConn = { Disconnect = function() end }
pcall(function()
	local overlay = CoreGui:WaitForChild("RobloxPromptGui", 10):WaitForChild("promptOverlay", 10)
	reconnectConn = overlay.ChildAdded:Connect(function(child)
		if not S.autoReconnect or child.Name ~= "ErrorPrompt" then return end
		log("Disconnected - rejoining in 5s")
		task.delay(5, function()
			pcall(function() game:GetService("TeleportService"):Teleport(game.PlaceId, player) end)
		end)
	end)
end)

local idleConn = player.Idled:Connect(function()
	if not S.antiAfk then return end
	-- Idled fires on a low-identity thread; VirtualUser needs the LocalUser capability (executor level)
	if setIdentity then pcall(setIdentity, 8) end
	pcall(function()
		local vu = game:GetService("VirtualUser")
		vu:CaptureController(); vu:ClickButton2(Vector2.new())
	end)
end)

---------------------------------------------------------------- UI (NCL HUB DQR template)
local T = {
	bg = Color3.fromRGB(11, 14, 27), panel = Color3.fromRGB(16, 20, 38), field = Color3.fromRGB(13, 17, 33),
	stroke = Color3.fromRGB(38, 46, 84), text = Color3.fromRGB(232, 236, 255), muted = Color3.fromRGB(128, 138, 172),
	accent = Color3.fromRGB(72, 92, 235), accent2 = Color3.fromRGB(128, 86, 242), green = Color3.fromRGB(28, 220, 150),
	pink = Color3.fromRGB(240, 45, 100), idle = Color3.fromRGB(28, 34, 62),
}
local TOGGLE_ON = Color3.fromRGB(40, 150, 70)
local NAV_BLUE, NAV_VIOLET = Color3.fromRGB(79, 124, 255), Color3.fromRGB(139, 92, 246)
local NAV_EDGE, NAV_ICON_ON = Color3.fromRGB(124, 92, 255), Color3.fromRGB(147, 170, 255)
local EDGE, INP = Color3.fromRGB(35, 40, 72), Color3.fromRGB(9, 11, 23)

-- one running tween per object + property set: a new tween on the same properties cancels the old one
local activeTweens = setmetatable({}, { __mode = "k" })
local function tween(inst, secs, goals, style)
	local names = {}
	for p in pairs(goals) do names[#names + 1] = p end
	table.sort(names)
	local key, running = table.concat(names, ","), activeTweens[inst]
	if running and running[key] then pcall(function() running[key]:Cancel() end); running[key] = nil end
	if secs <= 0 then for p, v in pairs(goals) do pcall(function() inst[p] = v end) end return end
	pcall(function()
		if not running then running = {}; activeTweens[inst] = running end
		local tw = TweenService:Create(inst, TweenInfo.new(secs, style or Enum.EasingStyle.Quint, Enum.EasingDirection.Out), goals)
		running[key] = tw; tw:Play()
	end)
end
local function round(o, r) local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r or 8); c.Parent = o; return c end
local function stroke(o, c, th)
	local s = Instance.new("UIStroke"); s.Color = c or T.stroke; s.Thickness = th or 1
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border; s.Parent = o; return s
end
-- soft top-to-bottom shading for panels/cards
local function polish(o, k)
	local g = Instance.new("UIGradient"); g.Rotation = 90
	g.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(k or 214, (k or 214) + 2, (k or 214) + 12)); g.Parent = o; return g
end
local function pad(o, l, r, t, b)
	local p = Instance.new("UIPadding")
	p.PaddingLeft, p.PaddingRight, p.PaddingTop, p.PaddingBottom = UDim.new(0, l or 0), UDim.new(0, r or 0), UDim.new(0, t or 0), UDim.new(0, b or 0)
	p.Parent = o; return p
end
local function makeText(parent, text, size, color, font, xAlign)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1; l.Text = text; l.TextSize = size; l.TextColor3 = color
	l.Font = font or Enum.Font.Gotham; l.TextXAlignment = xAlign or Enum.TextXAlignment.Left; l.Parent = parent
	return l
end

gui = Instance.new("ScreenGui")
gui.Name = "NCL HUB PL"; gui.ResetOnSpawn = false; gui.DisplayOrder = 200; gui.IgnoreGuiInset = true
if not pcall(function() gui.Parent = (gethui and gethui()) or CoreGui end) then gui.Parent = pgui end

local W, H = 900, 540
local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(W, H); main.AnchorPoint = Vector2.new(0.5, 0); main.Position = UDim2.fromScale(0.5, 0.08)
main.BackgroundColor3 = T.bg; main.BorderSizePixel = 0; main.Active = true; main.ClipsDescendants = true
main.Parent = gui
round(main, 14); stroke(main)
local uiScale = Instance.new("UIScale")
do
	local vp = Workspace.CurrentCamera.ViewportSize
	uiScale.Scale = math.clamp(math.min(vp.X / 940, vp.Y / 600), 0.45, 1)
end
uiScale.Parent = main

-- window open: grows from 92% with a small overshoot while a cover in the window colour fades away
local function popIn()
	local rest = uiScale.Scale
	uiScale.Scale = rest * 0.92
	tween(uiScale, 0.32, { Scale = rest }, Enum.EasingStyle.Back)
	local veil = Instance.new("Frame")
	veil.Size = UDim2.fromScale(1, 1); veil.BackgroundColor3 = T.bg; veil.BackgroundTransparency = 0.25
	veil.BorderSizePixel = 0; veil.ZIndex = 100; veil.Parent = main
	round(veil, 14)
	tween(veil, 0.3, { BackgroundTransparency = 1 })
	task.delay(0.34, function() veil:Destroy() end)
end
popIn()

-- The game draws its own cursor in PlayerGui, under this UI: show the system cursor while hovering the window.
-- Bound after every other render step so the game's own "hide the mouse" runs first and we win the frame.
local CURSOR_STEP = "NCL_PL_Cursor"
pcall(function() RunService:UnbindFromRenderStep(CURSOR_STEP) end)
-- The game draws its own cursor (PlayerGui.PlatformBattlesCursor); while over our window that one is switched off and
-- the system cursor shown instead, otherwise both show at once.
local gameCursorHidden = false
local function setGameCursor(on)
	local c = pgui:FindFirstChild("PlatformBattlesCursor")
	if c and c:IsA("LayerCollector") then c.Enabled = on end
	gameCursorHidden = not on
end
RunService:BindToRenderStep(CURSOR_STEP, Enum.RenderPriority.Last.Value + 100, function()
	local m, p, s = UIS:GetMouseLocation(), main.AbsolutePosition, main.AbsoluteSize
	local over = main.Visible and m.X >= p.X and m.X <= p.X + s.X and m.Y >= p.Y and m.Y <= p.Y + s.Y
	if over then
		UIS.MouseIconEnabled = true
		if not gameCursorHidden then setGameCursor(false) end
	elseif gameCursorHidden then
		setGameCursor(true)
	end
end)
local hoverConn = { Disconnect = function()
	pcall(function() RunService:UnbindFromRenderStep(CURSOR_STEP) end)
	if gameCursorHidden then setGameCursor(true) end
end }

-- HEADER
local header = Instance.new("Frame")
header.Size = UDim2.new(1, -24, 0, 64); header.Position = UDim2.fromOffset(12, 8)
header.BackgroundColor3 = T.panel; header.BorderSizePixel = 0; header.Parent = main
round(header, 12); stroke(header); polish(header)
do
	local line = Instance.new("Frame")
	line.Size = UDim2.new(1, -28, 0, 2); line.Position = UDim2.new(0, 14, 1, -2)
	line.BackgroundColor3 = Color3.new(1, 1, 1); line.BorderSizePixel = 0; line.Parent = header
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, T.accent), ColorSequenceKeypoint.new(0.5, T.accent2), ColorSequenceKeypoint.new(1, T.pink) })
	g.Parent = line

	-- logo + title: same as the Blade Ball menu (dark tile, violet border, soft blue "NCL", "NCL HUB" in one colour)
	local box = Instance.new("Frame")
	box.Size = UDim2.fromOffset(40, 40); box.Position = UDim2.fromOffset(12, 12)
	box.BackgroundColor3 = Color3.new(1, 1, 1); box.BorderSizePixel = 0; box.Parent = header
	local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(0, 10); bc.Parent = box
	do local bg = Instance.new("UIGradient"); bg.Rotation = 45; bg.Color = ColorSequence.new(Color3.fromRGB(22, 28, 61), Color3.fromRGB(10, 14, 26)); bg.Parent = box end
	do local bs = stroke(box, Color3.fromRGB(128, 86, 242)); bs.Transparency = 0.5 end
	local mark = makeText(box, "NCL", 14, Color3.fromRGB(143, 162, 255), Enum.Font.GothamBlack, Enum.TextXAlignment.Center)
	mark.Size = UDim2.fromScale(1, 1)

	local title = makeText(header, "NCL HUB", 22, Color3.fromRGB(143, 162, 255), Enum.Font.GothamBold)
	title.Size = UDim2.new(0, 170, 1, 0); title.Position = UDim2.fromOffset(60, 0)
	local div = Instance.new("Frame")
	div.Size = UDim2.fromOffset(1, 30); div.Position = UDim2.fromOffset(236, 17)
	div.BackgroundColor3 = T.stroke; div.BorderSizePixel = 0; div.Parent = header
end

-- drag by the whole header (Frame.Draggable only works on bare background and stutters)
local dragFrom, dragStart
header.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragFrom, dragStart = input.Position, main.Position
		local c
		c = input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then dragFrom = nil; c:Disconnect() end
		end)
	end
end)
local dragConn = UIS.InputChanged:Connect(function(input)
	if dragFrom and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local d = input.Position - dragFrom
		main.Position = UDim2.new(dragStart.X.Scale, dragStart.X.Offset + d.X, dragStart.Y.Scale, dragStart.Y.Offset + d.Y)
	end
end)

local pill = Instance.new("Frame")
pill.Size = UDim2.fromOffset(150, 28); pill.Position = UDim2.fromOffset(246, 18)
pill.BackgroundColor3 = T.muted; pill.BackgroundTransparency = 0.88; pill.BorderSizePixel = 0; pill.Parent = header
round(pill, 14)
local pillEdge = stroke(pill, T.muted); pillEdge.Transparency = 0.6
local dot = Instance.new("Frame")
dot.AnchorPoint = Vector2.new(0, 0.5); dot.Size = UDim2.fromOffset(8, 8); dot.Position = UDim2.new(0, 12, 0.5, 0)
dot.BackgroundColor3 = T.muted; dot.BorderSizePixel = 0; dot.Parent = pill
round(dot, 4)
local stateLabel = makeText(pill, "IDLE", 12, T.muted, Enum.Font.GothamBold)
stateLabel.Size = UDim2.new(1, -36, 1, 0); stateLabel.Position = UDim2.fromOffset(28, 0)
local statusLabel = makeText(header, "Status: Idle", 12, T.muted)
statusLabel.Size = UDim2.new(0, 330, 1, 0); statusLabel.Position = UDim2.fromOffset(408, 0); statusLabel.TextTruncate = Enum.TextTruncate.AtEnd

local function windowButton(x)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(34, 34); b.Position = UDim2.fromOffset(x, 15)
	b.BackgroundColor3 = T.field; b.Text = ""; b.BorderSizePixel = 0; b.AutoButtonColor = false; b.Parent = header
	b.Font = Enum.Font.GothamBold; b.TextSize = 15; b.TextColor3 = T.text
	round(b, 8); polish(b, 200)
	local s = stroke(b)
	b.MouseEnter:Connect(function() tween(s, 0.12, { Color = T.accent }) end)
	b.MouseLeave:Connect(function() tween(s, 0.2, { Color = T.stroke }) end)
	return b
end
local function bar(parent, w, h, rot)
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5); f.Position = UDim2.fromScale(0.5, 0.5); f.Size = UDim2.fromOffset(w, h)
	f.BackgroundColor3 = T.text; f.BorderSizePixel = 0; f.Rotation = rot or 0; f.Parent = parent
end
local hideQteBtn = windowButton(748); hideQteBtn.Text = "👁"
local minimizeBtn = windowButton(790); bar(minimizeBtn, 14, 2)
local closeBtn = windowButton(832); bar(closeBtn, 17, 2, 45); bar(closeBtn, 17, 2, -45)

local body = Instance.new("Frame")
body.Size = UDim2.fromScale(1, 1); body.BackgroundTransparency = 1; body.Parent = main

-- COMPONENTS
local refreshers = {}
local function onRefresh(f) table.insert(refreshers, f) end

local function MakeButton(text, color, parent)
	local b = Instance.new("TextButton")
	b.Text = text; b.Size = UDim2.new(1, 0, 0, 34); b.BackgroundColor3 = color; b.TextColor3 = T.text
	b.Font = Enum.Font.GothamSemibold; b.TextSize = 13; b.BorderSizePixel = 0; b.AutoButtonColor = false; b.Parent = parent
	round(b, 8)
	do local bs = Instance.new("UIStroke"); bs.Color = Color3.new(1, 1, 1); bs.Transparency = 0.85; bs.Thickness = 1
		bs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border; bs.Parent = b end
	local g = Instance.new("UIGradient"); g.Rotation = 90
	g.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(205, 208, 226)); g.Parent = b
	-- hover / press feedback via the gradient, so it never fights ON/OFF colours
	local function shade(bottom, s) tween(g, s or 0.12, { Color = ColorSequence.new(Color3.new(1, 1, 1), bottom) }) end
	b.MouseEnter:Connect(function() shade(Color3.fromRGB(245, 246, 255)) end)
	b.MouseLeave:Connect(function() shade(Color3.fromRGB(205, 208, 226)) end)
	b.MouseButton1Down:Connect(function() shade(Color3.fromRGB(150, 154, 180), 0.06) end)
	b.MouseButton1Up:Connect(function() shade(Color3.fromRGB(245, 246, 255), 0.1) end)
	return b
end

-- ON/OFF row: caption "<text>: ON/OFF", switch track + knob on the right that slides with a small overshoot
local function MakeToggle(text, key, parent)
	local b = MakeButton(text, T.idle, parent)
	b.TextXAlignment = Enum.TextXAlignment.Left
	pad(b, 12)
	local led = Instance.new("Frame")
	led.AnchorPoint = Vector2.new(1, 0.5); led.Position = UDim2.new(1, -12, 0.5, 0); led.Size = UDim2.fromOffset(34, 18)
	led.BackgroundColor3 = T.stroke; led.BorderSizePixel = 0; led.ZIndex = 3; led.Parent = b
	round(led, 9)
	local knob = Instance.new("Frame")
	knob.AnchorPoint = Vector2.new(0, 0.5); knob.Position = UDim2.new(0, 2, 0.5, 0); knob.Size = UDim2.fromOffset(14, 14)
	knob.BackgroundColor3 = Color3.new(1, 1, 1); knob.BorderSizePixel = 0; knob.ZIndex = 4; knob.Parent = led
	round(knob, 7)
	local glow = Instance.new("UIStroke"); glow.Color = T.green; glow.Transparency = 1; glow.Parent = led
	local edge = stroke(b)
	local first = true
	b.MouseButton1Click:Connect(function() S[key] = not S[key]; refresh() end)
	onRefresh(function()
		local on = S[key]
		b.Text = text .. ": " .. (on and "ON" or "OFF")
		if b.BackgroundColor3 ~= (on and TOGGLE_ON or T.idle) or first then
			local secs = first and 0 or 0.2
			b.BackgroundColor3 = on and TOGGLE_ON or T.idle
			tween(led, secs, { BackgroundColor3 = on and T.green or T.stroke })
			tween(glow, secs, { Transparency = on and 0.35 or 1 })
			tween(edge, secs, { Color = on and Color3.fromRGB(70, 220, 140) or T.stroke, Transparency = on and 0.35 or 0.6 })
			tween(knob, first and 0 or 0.24, { Position = on and UDim2.new(0, 18, 0.5, 0) or UDim2.new(0, 2, 0.5, 0) }, Enum.EasingStyle.Back)
			first = false
		end
	end)
	return b
end

local function MakeInput(placeholder, key, parent, secret)
	local box = Instance.new("TextBox")
	box.PlaceholderText = placeholder; box.PlaceholderColor3 = T.muted; box.Size = UDim2.new(1, 0, 0, 38)
	box.BackgroundColor3 = INP; box.TextColor3 = T.text; box.Font = Enum.Font.Gotham; box.TextSize = 13
	box.TextXAlignment = Enum.TextXAlignment.Left; box.ClearTextOnFocus = false; box.BorderSizePixel = 0
	box.TextTruncate = Enum.TextTruncate.AtEnd; box.Parent = parent
	round(box, 10)
	local s = stroke(box, EDGE)
	local function show() box.Text = (secret and S[key] ~= "") and string.rep("•", 28) or S[key] end
	show()
	box.Focused:Connect(function() tween(s, 0.15, { Color = T.accent, Thickness = 1.5 }); box.Text = S[key] end)
	box.FocusLost:Connect(function() tween(s, 0.2, { Color = EDGE, Thickness = 1 }); S[key] = box.Text; show() end)
	pad(box, 12, 12)
	return box
end

local function MakeRow(parent, height)
	local r = Instance.new("Frame")
	r.Size = UDim2.new(1, 0, 0, height or 38); r.BackgroundTransparency = 1; r.Parent = parent
	local l = Instance.new("UIListLayout")
	l.FillDirection = Enum.FillDirection.Horizontal; l.VerticalAlignment = Enum.VerticalAlignment.Center
	l.Padding = UDim.new(0, 8); l.SortOrder = Enum.SortOrder.LayoutOrder; l.Parent = r
	return r
end
local function rowSize(count) return UDim2.new(1 / count, -(count - 1) * 8 / count, 1, 0) end

local function MakeSectionLabel(text, parent)
	local l = makeText(parent, text:upper(), 11, Color3.fromRGB(201, 208, 245), Enum.Font.GothamBold)
	l.Size = UDim2.new(1, 0, 0, 18)
	pad(l, 12)
	local b = Instance.new("Frame")
	b.Size = UDim2.fromOffset(4, 14); b.Position = UDim2.new(0, -12, 0.5, -7)
	b.BackgroundColor3 = Color3.new(1, 1, 1); b.BorderSizePixel = 0; b.Parent = l
	round(b, 2)
	local g = Instance.new("UIGradient"); g.Rotation = 90; g.Color = ColorSequence.new(NAV_BLUE, NAV_VIOLET); g.Parent = b
	local gl = stroke(b, NAV_VIOLET, 2); gl.Transparency = 0.6
	return l
end

local function note(text, parent)
	local l = makeText(parent, text, 12, T.muted)
	l.Size = UDim2.new(1, 0, 0, 0); l.AutomaticSize = Enum.AutomaticSize.Y; l.TextWrapped = true
	return l
end

-- DROPDOWN: field shows the choice + chevron; the list is a floating card (dark, violet edge) under the field,
-- rows = icon + bold caption, hover tint, check mark on the selected one. Outside clicks / tab switches close it.
local popup = Instance.new("ScrollingFrame")
popup.BackgroundColor3 = Color3.fromRGB(13, 16, 36); popup.BorderSizePixel = 0; popup.ScrollBarThickness = 3
popup.ScrollBarImageColor3 = NAV_VIOLET; popup.CanvasSize = UDim2.new(); popup.AutomaticCanvasSize = Enum.AutomaticSize.Y
popup.ZIndex = 50; popup.Visible = false; popup.Parent = main
round(popup, 12)
do local e = stroke(popup, NAV_EDGE); e.Transparency = 0.35 end
pad(popup, 6, 8, 6, 6)
do local l = Instance.new("UIListLayout"); l.Padding = UDim.new(0, 4); l.SortOrder = Enum.SortOrder.LayoutOrder; l.Parent = popup end
local popupOwner
local chevrons = {} -- field -> its chevron label, flipped while that field's list is open

local function closePopup()
	if popupOwner and chevrons[popupOwner] then chevrons[popupOwner].Rotation = 0 end
	popup.Visible = false; popupOwner = nil
end
-- rows: { { caption, icon, selected, onClick, extra(rowButton) } }
local function openPopup(anchor, rows)
	for _, c in ipairs(popup:GetChildren()) do if c:IsA("GuiButton") or c:IsA("TextLabel") then c:Destroy() end end
	for i, r in ipairs(rows) do
		local item = Instance.new("TextButton")
		item.Size = UDim2.new(1, 0, 0, 36); item.LayoutOrder = i; item.Text = ""; item.AutoButtonColor = false
		item.BackgroundColor3 = r[3] and Color3.fromRGB(44, 42, 104) or Color3.fromRGB(21, 25, 50)
		item.BorderSizePixel = 0; item.ZIndex = 51; item.Parent = popup
		round(item, 8)
		if r[3] then stroke(item, NAV_EDGE) end
		local ic = makeText(item, r[2] or "", 16, T.text, Enum.Font.GothamBold, Enum.TextXAlignment.Center)
		ic.Size = UDim2.fromOffset(30, 36); ic.Position = UDim2.fromOffset(6, 0); ic.ZIndex = 52
		local cap = makeText(item, r[1], 13, r[3] and Color3.new(1, 1, 1) or Color3.fromRGB(190, 196, 230), Enum.Font.GothamBlack)
		cap.Size = UDim2.new(1, -110, 1, 0); cap.Position = UDim2.fromOffset(42, 0); cap.ZIndex = 52; cap.TextTruncate = Enum.TextTruncate.AtEnd
		if r[3] then
			local check = makeText(item, "✓", 14, NAV_ICON_ON, Enum.Font.GothamBold, Enum.TextXAlignment.Right)
			check.AnchorPoint = Vector2.new(1, 0.5); check.Position = UDim2.new(1, -10, 0.5, 0); check.Size = UDim2.fromOffset(18, 18); check.ZIndex = 52
		end
		local rest, hover = item.BackgroundColor3, Color3.fromRGB(33, 39, 80)
		item.MouseEnter:Connect(function() if not r[3] then tween(item, 0.15, { BackgroundColor3 = hover }) end end)
		item.MouseLeave:Connect(function() if not r[3] then tween(item, 0.15, { BackgroundColor3 = rest }) end end)
		item.MouseButton1Click:Connect(r[4])
		if r[5] then r[5](item) end
	end
	if #rows == 0 then
		local e = makeText(popup, "Nothing here yet", 12, T.muted, Enum.Font.Gotham, Enum.TextXAlignment.Center)
		e.Size = UDim2.new(1, 0, 0, 32); e.ZIndex = 51
	end
	local sc = uiScale.Scale
	local pos = anchor.AbsolutePosition - main.AbsolutePosition
	local n = math.max(#rows, 1)
	popup.Position = UDim2.fromOffset(pos.X / sc, (pos.Y + anchor.AbsoluteSize.Y) / sc + 6)
	popup.Size = UDim2.fromOffset(anchor.AbsoluteSize.X / sc, math.min(n * 40 + 8, 220))
	if popupOwner and popupOwner ~= anchor and chevrons[popupOwner] then chevrons[popupOwner].Rotation = 0 end
	popupOwner = anchor
	if chevrons[anchor] then chevrons[anchor].Rotation = 180 end
	popup.Visible = true
end

local function dropField(parent, placeholder)
	local f = Instance.new("TextButton")
	f.Size = UDim2.new(1, 0, 0, 40); f.BackgroundColor3 = INP; f.Text = ""; f.AutoButtonColor = false
	f.BorderSizePixel = 0; f.Parent = parent
	round(f, 10)
	local s = stroke(f, EDGE)
	local cap = makeText(f, placeholder, 13, T.muted, Enum.Font.GothamBold)
	cap.Size = UDim2.new(1, -50, 1, 0); cap.Position = UDim2.fromOffset(14, 0); cap.TextTruncate = Enum.TextTruncate.AtEnd
	local chev = makeText(f, "▼", 10, T.muted, Enum.Font.GothamBold, Enum.TextXAlignment.Center)
	chev.AnchorPoint = Vector2.new(1, 0.5); chev.Position = UDim2.new(1, -12, 0.5, 0); chev.Size = UDim2.fromOffset(18, 18)
	f.MouseEnter:Connect(function() tween(s, 0.12, { Color = T.accent }) end)
	f.MouseLeave:Connect(function() if popupOwner ~= f then tween(s, 0.2, { Color = EDGE }) end end)
	chevrons[f] = chev
	return f, cap
end

-- single-choice dropdown; label on the left, field on the right (DQR "MakeDropdownRow" layout)
local function MakeDropdown(label, key, options, parent)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 40); row.BackgroundTransparency = 1; row.Parent = parent
	makeText(row, label, 13, T.text, Enum.Font.GothamSemibold).Size = UDim2.new(0.42, 0, 1, 0)
	local holder = Instance.new("Frame"); holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(0.58, 0, 1, 0); holder.Position = UDim2.fromScale(0.42, 0); holder.Parent = row
	local f, cap = dropField(holder, "Select...")
	f.MouseButton1Click:Connect(function()
		if popupOwner == f then return closePopup() end
		local rows = {}
		for _, o in ipairs(options) do
			rows[#rows + 1] = { o[1]:upper(), o[2], S[key] == o[1], function() S[key] = o[1]; closePopup(); refresh() end }
		end
		openPopup(f, rows)
	end)
	onRefresh(function()
		for _, o in ipairs(options) do
			if o[1] == S[key] then cap.Text = (o[2] and o[2] .. "  " or "") .. o[1]; cap.TextColor3 = T.green end
		end
	end)
	return row
end

-- PAGES
local SIDEBAR_W, PAGE_X, PAGE_W, PAGE_H = 140, 162, 726, 388
local function createPage(title, subtitle)
	local p = Instance.new("ScrollingFrame")
	p.Size = UDim2.fromOffset(PAGE_W, PAGE_H); p.Position = UDim2.fromOffset(PAGE_X, 84)
	p.BackgroundColor3 = T.panel; p.BorderSizePixel = 0; p.ScrollBarThickness = 4; p.ScrollBarImageColor3 = T.accent
	p.CanvasSize = UDim2.new(); p.Visible = false; p.Parent = body
	round(p, 12); stroke(p); polish(p)
	pad(p, 16, 18, 14, 14)
	local l = Instance.new("UIListLayout"); l.SortOrder = Enum.SortOrder.LayoutOrder; l.Padding = UDim.new(0, 10); l.Parent = p
	l:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function() p.CanvasSize = UDim2.fromOffset(0, l.AbsoluteContentSize.Y + 28) end)
	p:GetPropertyChangedSignal("CanvasPosition"):Connect(closePopup)
	local head = Instance.new("Frame"); head.Size = UDim2.new(1, 0, 0, 42); head.BackgroundTransparency = 1; head.Parent = p
	makeText(head, title, 19, T.text, Enum.Font.GothamBold).Size = UDim2.new(1, 0, 0, 24)
	local sub = makeText(head, subtitle, 12, T.muted); sub.Size = UDim2.new(1, 0, 0, 16); sub.Position = UDim2.fromOffset(0, 25)
	return p
end

local playPage = createPage("Auto Play", "Join, host and start runs automatically.")
local battlePage = createPage("Battle", "Attack, skills, targets and QTE on your turn.")
local mapPage = createPage("Run Map", "Paths, events and chests between battles.")
local sellPage = createPage("Auto Sell", "Sell gear automatically by rarity and type.")
local hookPage = createPage("Webhook", "Send a summary to Discord when a run ends.")
local miscPage = createPage("Misc", "Quality-of-life extras.")
local setPage = createPage("Setting", "Config, keybind and script control.")

-- SIDEBAR
local sidebar = Instance.new("Frame")
sidebar.Size = UDim2.fromOffset(SIDEBAR_W, 444); sidebar.Position = UDim2.fromOffset(12, 84)
sidebar.BackgroundColor3 = T.panel; sidebar.BorderSizePixel = 0; sidebar.Parent = body
round(sidebar, 14); stroke(sidebar); polish(sidebar)
pad(sidebar, 8, 8, 8, 8)
local tabBar = Instance.new("ScrollingFrame")
tabBar.Size = UDim2.new(1, 0, 1, -112); tabBar.BackgroundTransparency = 1; tabBar.BorderSizePixel = 0
tabBar.ScrollBarThickness = 3; tabBar.ScrollBarImageColor3 = T.accent2; tabBar.ScrollBarImageTransparency = 0.4
tabBar.CanvasSize = UDim2.new(); tabBar.AutomaticCanvasSize = Enum.AutomaticSize.Y; tabBar.Parent = sidebar
pad(tabBar, 0, 2, 2, 2)
do local l = Instance.new("UIListLayout"); l.SortOrder = Enum.SortOrder.LayoutOrder; l.Padding = UDim.new(0, 4); l.Parent = tabBar end

-- nav icons drawn from plain Frames inside an 18x18 box (always render, recolour like stroke: currentColor)
local function iconPart(box, x, y, w, h, o)
	o = o or {}
	local p = Instance.new("Frame")
	p.Size = UDim2.fromOffset(w, h); p.Position = UDim2.fromOffset(x, y); p.BackgroundColor3 = Color3.new(1, 1, 1)
	p.BorderSizePixel = 0; p.Rotation = o.rot or 0; p.Parent = box
	if o.radius then round(p, o.radius) end
	if o.hollow then p.BackgroundTransparency = 1; stroke(p, Color3.new(1, 1, 1), o.hollow) end
	return p
end
local function paintIcon(box, color, animate)
	for _, part in ipairs(box:GetDescendants()) do
		if part:IsA("Frame") then tween(part, animate and 0.2 or 0, { BackgroundColor3 = color }) end
		if part:IsA("UIStroke") then tween(part, animate and 0.2 or 0, { Color = color }) end
	end
end
local navIcons = {
	["Auto Play"] = function(b) -- rounded square + play chevron
		iconPart(b, 1, 1, 16, 16, { radius = 5, hollow = 1.5 })
		iconPart(b, 5, 6, 7, 2, { radius = 1, rot = 45 }); iconPart(b, 5, 11, 7, 2, { radius = 1, rot = -45 })
	end,
	["Battle"] = function(b) -- crossed swords
		iconPart(b, 1, 8, 16, 2, { radius = 1, rot = 45 }); iconPart(b, 1, 8, 16, 2, { radius = 1, rot = -45 })
		iconPart(b, 1, 13, 4, 4, { radius = 2 }); iconPart(b, 13, 13, 4, 4, { radius = 2 })
	end,
	["Run Map"] = function(b) -- map pin
		iconPart(b, 4, 1, 10, 10, { radius = 5, hollow = 1.5 }); iconPart(b, 8, 10, 2, 6, { radius = 1 })
		iconPart(b, 2, 15, 14, 2, { radius = 1 })
	end,
	["Auto Sell"] = function(b) -- price tag
		iconPart(b, 4, 4, 11, 11, { radius = 3, hollow = 1.5, rot = 45 }); iconPart(b, 6, 6, 3, 3, { radius = 2 })
	end,
	["Webhook"] = function(b) -- bell
		iconPart(b, 4, 3, 10, 10, { radius = 5, hollow = 1.5 }); iconPart(b, 2, 12, 14, 2, { radius = 1 })
		iconPart(b, 7, 15, 4, 3, { radius = 2 })
	end,
	["Misc"] = function(b) -- three dots
		iconPart(b, 3, 8, 3, 3, { radius = 2 }); iconPart(b, 8, 8, 3, 3, { radius = 2 }); iconPart(b, 13, 8, 3, 3, { radius = 2 })
	end,
	["Setting"] = function(b) -- sliders
		iconPart(b, 2, 4, 14, 2, { radius = 1 }); iconPart(b, 11, 2, 6, 6, { radius = 3, hollow = 1.5 })
		iconPart(b, 2, 9, 14, 2, { radius = 1 }); iconPart(b, 4, 7, 6, 6, { radius = 3, hollow = 1.5 })
		iconPart(b, 2, 14, 14, 2, { radius = 1 }); iconPart(b, 9, 12, 6, 6, { radius = 3, hollow = 1.5 })
	end,
}

local tabs, bottomBar, currentTab = {}, nil, nil
local curtain = Instance.new("Frame")
curtain.BackgroundColor3 = T.panel; curtain.BorderSizePixel = 0; curtain.ZIndex = 40; curtain.Visible = false; curtain.Parent = body
round(curtain, 12)
local enterId = 0
local function switchTab(i)
	local prev = currentTab
	currentTab = i
	closePopup()
	for k, t in ipairs(tabs) do
		local on = k == i
		t.page.Visible = on
		tween(t.page, 0, { Position = UDim2.fromOffset(PAGE_X, 84) })
		tween(t.btn, 0.2, { BackgroundTransparency = on and 0 or 0.975, TextColor3 = on and T.text or Color3.fromRGB(170, 179, 221) })
		t.bar.Visible = on
	end
	-- page slide + fade: in 18px from the right while a cover in the page colour fades away
	if prev and prev ~= i then
		local page, home = tabs[i].page, UDim2.fromOffset(PAGE_X, 84)
		enterId += 1
		local id = enterId
		page.Position = home + UDim2.fromOffset(18, 0)
		curtain.Size, curtain.Position, curtain.BackgroundTransparency, curtain.Visible = page.Size, page.Position, 0.2, true
		tween(page, 0.28, { Position = home })
		tween(curtain, 0.28, { Position = home, BackgroundTransparency = 1 })
		task.delay(0.32, function() if enterId == id then curtain.Visible = false end end)
	end
end
local function createTab(text, page)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, 40); b.BackgroundColor3 = Color3.new(1, 1, 1); b.BackgroundTransparency = 0.975
	b.Text = text; b.TextTransparency = 1; b.TextColor3 = Color3.fromRGB(170, 179, 221); b.BorderSizePixel = 0; b.AutoButtonColor = false; b.Parent = tabBar
	round(b, 10)
	local g = Instance.new("UIGradient"); g.Color = ColorSequence.new(NAV_BLUE, NAV_VIOLET); g.Transparency = NumberSequence.new(0.74, 0.9); g.Parent = b
	local edge = stroke(b, NAV_EDGE); edge.Transparency = 1
	local strip = Instance.new("Frame")
	strip.Size = UDim2.new(0, 3, 1, -12); strip.Position = UDim2.fromOffset(0, 6); strip.BackgroundColor3 = Color3.new(1, 1, 1)
	strip.BorderSizePixel = 0; strip.Visible = false; strip.Parent = b
	round(strip, 2)
	do local sg = Instance.new("UIGradient"); sg.Rotation = 90; sg.Color = ColorSequence.new(NAV_BLUE, NAV_VIOLET); sg.Parent = strip end
	do local gl = stroke(strip, NAV_VIOLET, 2); gl.Transparency = 0.6 end
	local content = Instance.new("Frame")
	content.Size = UDim2.new(1, -13, 1, 0); content.Position = UDim2.fromOffset(13, 0); content.BackgroundTransparency = 1; content.Parent = b
	do
		local l = Instance.new("UIListLayout"); l.FillDirection = Enum.FillDirection.Horizontal
		l.VerticalAlignment = Enum.VerticalAlignment.Center; l.SortOrder = Enum.SortOrder.LayoutOrder; l.Padding = UDim.new(0, 9); l.Parent = content
	end
	local iconBox = Instance.new("Frame"); iconBox.Size = UDim2.fromOffset(18, 18); iconBox.BackgroundTransparency = 1
	iconBox.LayoutOrder = 1; iconBox.Parent = content
	if navIcons[text] then navIcons[text](iconBox) end
	local cap = makeText(content, text, 13, Color3.fromRGB(170, 179, 221), Enum.Font.GothamBold)
	cap.Size = UDim2.new(1, -27, 1, 0); cap.LayoutOrder = 2
	b:GetPropertyChangedSignal("TextColor3"):Connect(function() cap.TextColor3 = b.TextColor3 end)
	local function syncActive(animate)
		tween(edge, animate and 0.2 or 0, { Transparency = strip.Visible and 0.62 or 1 })
		paintIcon(iconBox, strip.Visible and NAV_ICON_ON or Color3.fromRGB(170, 179, 221), animate)
	end
	strip:GetPropertyChangedSignal("Visible"):Connect(function() syncActive(true) end)
	syncActive(false)
	table.insert(tabs, { btn = b, page = page, bar = strip })
	local i = #tabs
	b.MouseButton1Click:Connect(function() switchTab(i) end)
	b.MouseEnter:Connect(function() if not strip.Visible then tween(b, 0.12, { TextColor3 = T.text, BackgroundTransparency = 0.92 }) end end)
	b.MouseLeave:Connect(function() if not strip.Visible then tween(b, 0.2, { TextColor3 = Color3.fromRGB(170, 179, 221), BackgroundTransparency = 0.975 }) end end)
end
createTab("Auto Play", playPage)
createTab("Battle", battlePage)
createTab("Run Map", mapPage)
createTab("Auto Sell", sellPage)
createTab("Webhook", hookPage)
createTab("Misc", miscPage)
createTab("Setting", setPage)

-- CARD: rounded surface with a title + one-line hint, its controls stacked inside (every section of every page)
local CARD = Color3.fromRGB(17, 20, 42)
local function Card(page, title, hint)
	local c = Instance.new("Frame")
	c.Size = UDim2.new(1, 0, 0, 0); c.AutomaticSize = Enum.AutomaticSize.Y; c.BackgroundColor3 = Color3.fromRGB(21, 26, 56)
	c.BorderSizePixel = 0; c.Parent = page
	round(c, 12); stroke(c, EDGE); polish(c, 200)
	pad(c, 14, 14, 12, 14)
	local l = Instance.new("UIListLayout"); l.Padding = UDim.new(0, 8); l.SortOrder = Enum.SortOrder.LayoutOrder; l.Parent = c
	local head = Instance.new("Frame"); head.BackgroundTransparency = 1; head.Size = UDim2.new(1, 0, 0, 20)
	head.AutomaticSize = Enum.AutomaticSize.Y; head.Parent = c
	local bar = Instance.new("Frame")
	bar.Size = UDim2.fromOffset(4, 16); bar.Position = UDim2.fromOffset(0, 2); bar.BackgroundColor3 = Color3.new(1, 1, 1)
	bar.BorderSizePixel = 0; bar.Parent = head
	round(bar, 2)
	do local g = Instance.new("UIGradient"); g.Rotation = 90; g.Color = ColorSequence.new(NAV_BLUE, NAV_VIOLET); g.Parent = bar end
	do local gl = stroke(bar, NAV_VIOLET, 2); gl.Transparency = 0.6 end
	local t = makeText(head, title, 14, T.text, Enum.Font.GothamBold); t.Size = UDim2.new(1, -14, 0, 20); t.Position = UDim2.fromOffset(14, 0)
	if hint then
		local h = makeText(head, hint, 11, T.muted); h.Size = UDim2.new(1, -14, 0, 14); h.Position = UDim2.fromOffset(14, 22)
		h.AutomaticSize = Enum.AutomaticSize.Y; h.TextWrapped = true
		pad(head, 0, 0, 0, 2)
	end
	return c
end
local function pair(parent, a, b)
	local r = MakeRow(parent, 36)
	MakeToggle(a[1], a[2], r).Size = rowSize(2)
	MakeToggle(b[1], b[2], r).Size = rowSize(2)
	return r
end

-- AUTO PLAY
do
	local c = Card(playPage, "Automation", "Next Act: CONTINUE, NEXT FLOOR, CLAIM. Next Path: map card, camp / event choice, TO BATTLE. Replay: PLAY AGAIN.")
	pair(c, { "Auto Join", "autoJoin" }, { "Auto Replay", "autoReplay" })
	pair(c, { "Auto Next Act", "autoContinue" }, { "Auto Next Path", "autoPath" })
	MakeToggle("Stop at 1 life (safety: no new run, gear is wiped on the last life)", "stopAtLife", c)
end
local mpRow
do
	local c = Card(playPage, "Run setup", "Background clicks run the game's own button code; Mouse moves a virtual cursor.")
	MakeDropdown("Mode", "mode", { { "Solo", "🧍" }, { "Multiplayer", "👥" } }, c)
	mpRow = MakeDropdown("Multiplayer", "mpMode", { { "Host", "🏠" }, { "Queue", "🎲" } }, c)
	MakeDropdown("Difficulty", "difficulty", { { "Normal", "🟢" }, { "Hard", "🟡" }, { "Nightmare", "🔴" }, { "Torment", "🟣" } }, c)
	MakeInput("Torment stage number (e.g. 35 = XXXV, empty = keep)", "tormentStage", c)
	MakeDropdown("Click with", "clickMode", { { "Background", "👻" }, { "Mouse", "🖱️" } }, c)
end
do
	local c = Card(playPage, "Party", "Host invites listed players in this server every 20s; Wait holds START until they joined.")
	pair(c, { "Auto Invite", "autoInvite" }, { "Wait for Party", "waitParty" })
	MakeInput("Usernames to invite, comma separated (friend1, friend2)", "inviteList", c)
	MakeToggle("Auto Accept Invites", "autoAccept", c)
end
do
	local c = Card(playPage, "Character", "From the main menu: opens Character Select and enters this slot. Locked slots are never bought.")
	MakeToggle("Auto Pick Slot", "autoSlot", c)
	MakeDropdown("Slot", "slotNum", { { "1", "1️⃣" }, { "2", "2️⃣" }, { "3", "3️⃣" }, { "4", "4️⃣" }, { "5", "5️⃣" }, { "6", "6️⃣" } }, c)
end

-- BATTLE
do
	local c = Card(battlePage, "Game Speed", "Speeds up battle animations, enemy turns and screens. Perfect QTE stays exact.")
	MakeDropdown("Speed", "gameSpeed", { { "1x", "🐢" }, { "2x", "⚡" }, { "3x", "🚀" } }, c)
end
do
	local c = Card(battlePage, "On your turn", "Auto Target skips foes that are already defeated.")
	pair(c, { "Auto Attack", "autoAttack" }, { "Auto Target", "autoTarget" })
	pair(c, { "Auto Skill", "autoSkill" }, { "Perfect QTE", "autoQTE" })
end
local skillField, skillCap
do
	local c = Card(battlePage, "Skill priority", "Synced from the game. Top to bottom; cooldown / low EN is skipped, then it attacks.")
	skillField, skillCap = dropField(c, "Select skills...")
end
local function skillRows()
	local rows = {}
	for i, sk in ipairs(S.skills) do
		rows[#rows + 1] = { i .. ".  " .. sk.name:upper(), sk.on and "✅" or "⬜", sk.on, function() sk.on = not sk.on; skillsDirty = true end,
			function(item)
				for j, glyph in ipairs({ "▲", "▼" }) do
					local a = Instance.new("TextButton")
					a.AnchorPoint = Vector2.new(1, 0.5); a.Size = UDim2.fromOffset(26, 24); a.Position = UDim2.new(1, j == 1 and -62 or -32, 0.5, 0)
					a.BackgroundColor3 = T.idle; a.Text = glyph; a.TextColor3 = T.text; a.Font = Enum.Font.GothamBold; a.TextSize = 11
					a.AutoButtonColor = false; a.BorderSizePixel = 0; a.ZIndex = 53; a.Parent = item
					round(a, 6)
					a.MouseButton1Click:Connect(function()
						local k = j == 1 and i - 1 or i + 1
						if S.skills[k] then S.skills[i], S.skills[k] = S.skills[k], S.skills[i]; skillsDirty = true end
					end)
				end
			end }
	end
	return rows
end
skillField.MouseButton1Click:Connect(function()
	if popupOwner == skillField then return closePopup() end
	openPopup(skillField, skillRows())
end)
local function renderSkills()
	local on = {}
	for _, sk in ipairs(S.skills) do if sk.on then on[#on + 1] = sk.name end end
	skillCap.Text = #S.skills == 0 and "No skills yet (synced on first turn)" or (#on == 0 and "Select skills..." or "⚡ " .. table.concat(on, ", "))
	skillCap.TextColor3 = #on == 0 and T.muted or T.green
	if popupOwner == skillField then openPopup(skillField, skillRows()) end -- live reorder while open
end
do
	local c = Card(battlePage, "Auto potion", "Drinks an HP Potion from the satchel under this HP % (game limit: 3 per run).")
	local r = MakeRow(c, 38)
	MakeToggle("Auto Potion", "autoPotion", r).Size = rowSize(2)
	MakeInput("HP below % (e.g. 40)", "potionPct", r).Size = rowSize(2)
end
do
	local c = Card(battlePage, "Target", "Enemy to hit first. Empty = first living foe.")
	MakeInput("Enemy name, e.g. HOLLOW WRAITH", "targetName", c)
end

-- RUN MAP
do
	local c = Card(mapPage, "Path", "Picks the card whose stars are closest to your choice; ties go left.")
	MakeToggle("Auto Next Path", "autoPath", c)
	MakeDropdown("Pick by", "pathBy", { { "Reward", "💰" }, { "Danger", "💀" } }, c)
	MakeDropdown("Stars", "pathStars", { { "1", "⭐" }, { "2", "⭐⭐" }, { "3", "⭐⭐⭐" }, { "4", "⭐⭐⭐⭐" }, { "5", "⭐⭐⭐⭐⭐" } }, c)
end
do
	local c = Card(mapPage, "Events & chests", "Preferred choice first, else random; Walk Away only when nothing else.")
	pair(c, { "Auto Event", "autoEvent" }, { "Auto Chest", "autoChest" })
	MakeInput("Preferred choices, comma separated (OFFER BLOOD)", "eventPrefer", c)
	local r = MakeRow(c, 38)
	makeText(r, "Offer Blood only above HP %", 13, T.text, Enum.Font.GothamSemibold).Size = rowSize(2)
	MakeInput("e.g. 50", "bloodMinHp", r).Size = rowSize(2)
end

-- AUTO SELL
-- chip: small rounded toggle for one key of a table setting (rarity / type), lit in the rarity's colour when on
local function chip(parent, label, tbl, key, color)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(0, 32); b.AutomaticSize = Enum.AutomaticSize.X; b.Text = label; b.Font = Enum.Font.GothamBold
	b.TextSize = 12; b.AutoButtonColor = false; b.BorderSizePixel = 0; b.Parent = parent
	round(b, 8); pad(b, 14, 14)
	local s = stroke(b, EDGE)
	b.MouseButton1Click:Connect(function() S[tbl][key] = not S[tbl][key] or nil; refresh() end)
	onRefresh(function()
		local on = S[tbl][key] == true
		b.BackgroundColor3 = on and color:Lerp(Color3.new(0, 0, 0), 0.15) or color:Lerp(INP, 0.82)
		b.TextColor3 = on and Color3.new(1, 1, 1) or color:Lerp(T.muted, 0.35)
		s.Color = on and color:Lerp(Color3.new(1, 1, 1), 0.25) or color:Lerp(EDGE, 0.65)
	end)
end
local function chipRow(parent)
	local r = Instance.new("Frame"); r.BackgroundTransparency = 1; r.Size = UDim2.new(1, 0, 0, 0); r.AutomaticSize = Enum.AutomaticSize.Y; r.Parent = parent
	local l = Instance.new("UIListLayout"); l.FillDirection = Enum.FillDirection.Horizontal; l.Wraps = true
	l.Padding = UDim.new(0, 8); l.SortOrder = Enum.SortOrder.LayoutOrder; l.Parent = r
	return r
end
do
	local c = Card(sellPage, "Auto Sell", "Every 30s outside battle. Worn, locked and unsellable pieces are never sold.")
	MakeToggle("Auto Sell", "autoSell", c)
	local r = MakeRow(c, 38)
	local now = MakeButton("Sell Now", Color3.fromRGB(19, 156, 98), r); now.Size = rowSize(2); now.Font = Enum.Font.GothamBold
	local stat = makeText(r, "", 12, T.muted); stat.Size = rowSize(2); stat.TextWrapped = true
	now.MouseButton1Click:Connect(function() task.spawn(sellPass, true); task.wait(0.2); refresh() end)
	onRefresh(function() stat.Text = sellNote end)
end
do
	local c = Card(sellPage, "Rarity", "Lit = sold. Secret is never sold.")
	local r = chipRow(c)
	local RC = {
		Common = Color3.fromRGB(170, 176, 190), Uncommon = Color3.fromRGB(72, 200, 110), Rare = Color3.fromRGB(70, 140, 255),
		Epic = Color3.fromRGB(170, 90, 245), Legendary = Color3.fromRGB(250, 170, 50),
	}
	for _, k in ipairs({ "Common", "Uncommon", "Rare", "Epic", "Legendary" }) do chip(r, k:upper(), "sellRarity", k, RC[k]) end
end
do
	local c = Card(sellPage, "Type", "Lit = sold.")
	local r = chipRow(c)
	for _, k in ipairs({ { "weapon", "⚔️ WEAPON" }, { "head", "🪖 HEAD" }, { "chest", "🛡️ CHEST" }, { "legs", "👖 LEGS" }, { "relic", "💍 RELIC" }, { "scroll", "📜 SCROLL" } }) do
		chip(r, k[2], "sellType", k[1], NAV_BLUE)
	end
end

-- WEBHOOK
local setResult
do
	local c = Card(hookPage, "Discord webhook", "Posts the result screen's stats when a run ends.")
	MakeInput("Paste Webhook URL...", "webhook", c, true)
	local testBtn = MakeButton("Send Test Message", NAV_BLUE, c)
	testBtn.Size = UDim2.new(1, 0, 0, 42); testBtn.Font = Enum.Font.GothamBold
	testBtn:FindFirstChildOfClass("UICorner").CornerRadius = UDim.new(0, 10)
	-- status line: dark rounded box, dot + result text (dot turns green once a send succeeded)
	local resultBox = Instance.new("Frame")
	resultBox.Size = UDim2.new(1, 0, 0, 40); resultBox.BackgroundColor3 = Color3.fromRGB(10, 13, 28); resultBox.BorderSizePixel = 0
	resultBox.Parent = c
	round(resultBox, 10); stroke(resultBox, EDGE)
	local resultDot = Instance.new("Frame")
	resultDot.AnchorPoint = Vector2.new(0, 0.5); resultDot.Position = UDim2.new(0, 13, 0.5, 0); resultDot.Size = UDim2.fromOffset(8, 8)
	resultDot.BackgroundColor3 = Color3.fromRGB(90, 96, 144); resultDot.BorderSizePixel = 0; resultDot.Parent = resultBox
	round(resultDot, 4)
	local hookResult = makeText(resultBox, "Result: nothing sent yet.", 12, T.muted)
	hookResult.Position = UDim2.fromOffset(30, 0); hookResult.Size = UDim2.new(1, -43, 1, 0); hookResult.TextWrapped = true
	setResult = function(ok, text)
		hookResult.Text = text
		resultDot.BackgroundColor3 = ok and T.green or Color3.fromRGB(90, 96, 144)
	end
	testBtn.MouseButton1Click:Connect(function()
		setResult(false, "Result: sending...")
		task.spawn(function()
			local ok, info = webhook("NCL HUB test", { "Webhook works for **" .. player.Name .. "**." }, 0x485CEB)
			setResult(ok, (ok and "Result: Sent OK - " or "Result: failed - ") .. info)
		end)
	end)
end
do
	local c = Card(hookPage, "Send when", "Each is sent once per result screen.")
	pair(c, { "Run finished", "hookClear" }, { "Died", "hookDeath" })
	MakeToggle("Chest loot (every chest opened)", "hookChest", c)
end
do
	local c = Card(hookPage, "Ping", "Mentioned in every message.")
	MakeInput("@everyone or a user ID (123456789012345678)", "pingId", c)
end

-- MISC
do
	local c = Card(miscPage, "Utility", "Hide QTE keeps Perfect QTE pressing unseen; Anti AFK stops the idle kick.")
	pair(c, { "Hide QTE", "hideQTE" }, { "Anti AFK", "antiAfk" })
	MakeToggle("FPS Boost (low graphics, no 3D world - steadier dodge timing)", "fpsBoost", c)
	MakeToggle("Auto Reconnect", "autoReconnect", c)
end

-- SETTING
local cfgNote
do
	local c = Card(setPage, "Config", "workspace/" .. SAVE)
	MakeToggle("Auto Save", "autoSave", c)
	local r = MakeRow(c, 38)
	local sv = MakeButton("Save Now", Color3.fromRGB(19, 156, 98), r); sv.Size = rowSize(2); sv.Font = Enum.Font.GothamBold
	local rs = MakeButton("Reset Default", Color3.fromRGB(194, 31, 74), r); rs.Size = rowSize(2); rs.Font = Enum.Font.GothamBold
	cfgNote = note("", c)
	sv.MouseButton1Click:Connect(function() cfgNote.Text = saveConfig() and "Saved." or "Save failed: executor has no writefile" end)
	rs.MouseButton1Click:Connect(function()
		local keep = S.skills
		applyConfig(HttpService:JSONDecode(HttpService:JSONEncode(DEFAULT)))
		S.skills = keep; skillsDirty = true
		cfgNote.Text = "Reset to defaults (skill list kept)."; refresh()
	end)
end
do
	local c = Card(setPage, "Interface", "Key that hides / shows this window.")
	MakeDropdown("Toggle UI key", "uiKey", { { "RightShift", "⌨️" }, { "RightControl", "⌨️" }, { "LeftAlt", "⌨️" }, { "Insert", "⌨️" }, { "F1", "⌨️" } }, c)
end

-- DISCORD (same invite as NCL HUB DQR)
local DISCORD_INVITE = "https://discord.gg/SuKX7Gc4B4"

-- BOTTOM BAR: run button
bottomBar = Instance.new("Frame")
bottomBar.Size = UDim2.fromOffset(PAGE_W, 46); bottomBar.Position = UDim2.fromOffset(PAGE_X, 482)
bottomBar.BackgroundTransparency = 1; bottomBar.Parent = body
local runBtn = MakeButton("", T.accent, bottomBar)
runBtn.Size = UDim2.fromScale(1, 1); runBtn.TextSize = 15; runBtn.Font = Enum.Font.GothamBlack
runBtn:FindFirstChildOfClass("UICorner").CornerRadius = UDim.new(0, 12)
do local gl = stroke(runBtn, Color3.fromRGB(147, 170, 255), 2); gl.Transparency = 0.45 end
-- redraw right away (the main loop may be busy for seconds) and ignore a second click in the same instant,
-- otherwise a click that looks ignored gets repeated and flips the macro straight back off
local lastRunClick = 0
runBtn.MouseButton1Click:Connect(function()
	if os.clock() - lastRunClick < 0.35 then return end
	lastRunClick = os.clock()
	S.running = not S.running
	log(S.running and "Started" or "Stopped")
	refresh()
end)

-- sidebar bottom: Discord (logo + caption), click copies the invite
local discordBtn = MakeButton("", Color3.fromRGB(88, 101, 242), sidebar)
discordBtn.AnchorPoint = Vector2.new(0, 1); discordBtn.Size = UDim2.new(1, 0, 0, 40); discordBtn.Position = UDim2.fromScale(0, 1)
do
	local ks = stroke(discordBtn, Color3.fromRGB(121, 131, 245))
	discordBtn.MouseEnter:Connect(function() ks.Color = Color3.fromRGB(190, 197, 255) end)
	discordBtn.MouseLeave:Connect(function() ks.Color = Color3.fromRGB(121, 131, 245) end)
	local cap = makeText(discordBtn, "DISCORD", 13, Color3.new(1, 1, 1), Enum.Font.GothamBold, Enum.TextXAlignment.Center)
	cap.Size = UDim2.fromScale(1, 1)
	discordBtn.MouseButton1Click:Connect(function()
		if setclipboard then setclipboard(DISCORD_INVITE) end
		cap.Text = "COPIED!"
		task.delay(1.5, function() if cap.Parent then cap.Text = "DISCORD" end end)
	end)
end
do -- sidebar info card (Roblox user + version), purely visual
	local ic = Instance.new("Frame"); ic.AnchorPoint = Vector2.new(0, 1); ic.Size = UDim2.new(1, 0, 0, 58)
	ic.Position = UDim2.new(0, 0, 1, -46); ic.BackgroundColor3 = Color3.fromRGB(21, 26, 56); ic.BorderSizePixel = 0; ic.Parent = sidebar
	round(ic, 10); stroke(ic, EDGE); polish(ic, 200)
	local av = Instance.new("Frame"); av.Size = UDim2.fromOffset(26, 26); av.Position = UDim2.fromOffset(8, 6)
	av.BackgroundColor3 = Color3.new(1, 1, 1); av.BorderSizePixel = 0; av.Parent = ic; round(av, 13)
	do local g = Instance.new("UIGradient"); g.Rotation = 45; g.Color = ColorSequence.new(NAV_BLUE, NAV_VIOLET); g.Parent = av end
	local ini = makeText(av, string.upper(string.sub(player.Name, 1, 1)), 12, Color3.new(1, 1, 1), Enum.Font.GothamBold, Enum.TextXAlignment.Center)
	ini.Size = UDim2.fromScale(1, 1)
	local cap = makeText(ic, "ROBLOX USER", 9, T.muted, Enum.Font.GothamBold); cap.Size = UDim2.new(1, -46, 0, 11); cap.Position = UDim2.fromOffset(40, 6)
	local nm = makeText(ic, player.Name, 12, T.text, Enum.Font.GothamBold); nm.Size = UDim2.new(1, -46, 0, 14); nm.Position = UDim2.fromOffset(40, 18)
	nm.TextTruncate = Enum.TextTruncate.AtEnd
	local dv = Instance.new("Frame"); dv.Size = UDim2.new(1, -16, 0, 1); dv.Position = UDim2.fromOffset(8, 36)
	dv.BackgroundColor3 = EDGE; dv.BorderSizePixel = 0; dv.Parent = ic
	local vc = makeText(ic, "VERSION", 9, T.muted, Enum.Font.GothamBold); vc.Size = UDim2.new(0.5, 0, 0, 16); vc.Position = UDim2.fromOffset(10, 40)
	local vb = Instance.new("Frame"); vb.Size = UDim2.fromOffset(44, 16); vb.AnchorPoint = Vector2.new(1, 0); vb.Position = UDim2.new(1, -8, 0, 40)
	vb.BackgroundColor3 = T.accent; vb.BackgroundTransparency = 0.7; vb.BorderSizePixel = 0; vb.Parent = ic; round(vb, 8)
	local vt = makeText(vb, "v1.0.0", 10, Color3.fromRGB(190, 200, 255), Enum.Font.GothamBold, Enum.TextXAlignment.Center); vt.Size = UDim2.fromScale(1, 1)
end
local unloadBtn
do
	local c = Card(setPage, "Script", "Removes the window and stops everything.")
	unloadBtn = MakeButton("Unload Script", Color3.fromRGB(194, 31, 74), c); unloadBtn.Font = Enum.Font.GothamBold
end

hideQteBtn.MouseButton1Click:Connect(function() S.hideQTE = not S.hideQTE; refresh() end)

refresh = function()
	if not alive then return end
	for _, f in ipairs(refreshers) do f() end
	if qte then qte.nclOn, qte.nclHide = S.autoQTE, S.autoQTE and S.hideQTE end
	if getgenv then getgenv().NCL_SPEED = tonumber(S.gameSpeed:match("%d+")) or 1 end
	if speed() > 1 then installSpeedHooks() end
	if boostOn ~= S.fpsBoost then applyBoost(S.fpsBoost) end
	if skillsDirty then skillsDirty = false; renderSkills() end
	if S.autoSave and HttpService:JSONEncode(S) ~= saved then saveConfig() end
	mpRow.Visible = S.mode == "Multiplayer"
	local col = S.running and T.green or T.muted
	stateLabel.Text = S.running and "MACRO ACTIVE" or "IDLE"
	stateLabel.TextColor3, dot.BackgroundColor3, pill.BackgroundColor3, pillEdge.Color = col, col, col, col
	statusLabel.Text = "Status: " .. (S.running and status or "Idle")
	runBtn.Text = S.running and "■   STOP SCRIPT" or "▶   RUN SCRIPT"
	runBtn.BackgroundColor3 = S.running and T.pink or T.accent
	hideQteBtn.TextTransparency = S.hideQTE and 0 or 0.6
end
switchTab(1)
refresh()

-- MINIMIZE: the window shrinks and fades away, a small NCL icon pops in (drag it anywhere, tap / click to reopen).
-- Its gradient ring spins slowly and the dot pulses green while the macro runs.
local mini = Instance.new("TextButton")
mini.Name = "NCLMiniIcon"; mini.Size = UDim2.fromOffset(64, 64); mini.AnchorPoint = Vector2.new(0.5, 0.5)
mini.Position = UDim2.new(0, 70, 0.5, 0); mini.BackgroundTransparency = 1; mini.Text = ""; mini.AutoButtonColor = false
mini.Visible = false; mini.ZIndex = 50; mini.Parent = gui
local miniScale = Instance.new("UIScale"); miniScale.Parent = mini
local ring = Instance.new("Frame")
ring.Size = UDim2.fromScale(1, 1); ring.BackgroundColor3 = Color3.new(1, 1, 1); ring.BorderSizePixel = 0; ring.ZIndex = 50; ring.Parent = mini
round(ring, 18)
local ringGrad = Instance.new("UIGradient")
ringGrad.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, T.accent), ColorSequenceKeypoint.new(0.5, T.accent2), ColorSequenceKeypoint.new(1, T.pink) })
ringGrad.Parent = ring
local tile = Instance.new("Frame")
tile.AnchorPoint = Vector2.new(0.5, 0.5); tile.Position = UDim2.fromScale(0.5, 0.5); tile.Size = UDim2.new(1, -6, 1, -6)
tile.BorderSizePixel = 0; tile.BackgroundColor3 = Color3.new(1, 1, 1); tile.ZIndex = 51; tile.Parent = mini
round(tile, 16)
do local g = Instance.new("UIGradient"); g.Rotation = 45; g.Color = ColorSequence.new(Color3.fromRGB(22, 28, 61), Color3.fromRGB(10, 14, 26)); g.Parent = tile end
local miniMark = makeText(tile, "NCL", 19, Color3.new(1, 1, 1), Enum.Font.GothamBlack, Enum.TextXAlignment.Center)
miniMark.Size = UDim2.fromScale(1, 1); miniMark.ZIndex = 52
do local g = Instance.new("UIGradient"); g.Color = ringGrad.Color; g.Parent = miniMark end
local miniDot = Instance.new("Frame")
miniDot.AnchorPoint = Vector2.new(1, 0); miniDot.Position = UDim2.new(1, 2, 0, -2); miniDot.Size = UDim2.fromOffset(14, 14)
miniDot.BackgroundColor3 = T.muted; miniDot.BorderSizePixel = 0; miniDot.ZIndex = 53; miniDot.Parent = mini
round(miniDot, 7); stroke(miniDot, T.bg, 2)

local minimized, hideToken, restScale = false, 0, uiScale.Scale
local function setMinimized(state)
	minimized = state
	hideToken += 1
	local token = hideToken
	closePopup()
	if state then
		restScale = uiScale.Scale
		tween(uiScale, 0.18, { Scale = restScale * 0.85 }, Enum.EasingStyle.Quad)
		local veil = Instance.new("Frame")
		veil.Size = UDim2.fromScale(1, 1); veil.BackgroundColor3 = T.bg; veil.BackgroundTransparency = 1
		veil.BorderSizePixel = 0; veil.ZIndex = 100; veil.Parent = main
		round(veil, 14)
		tween(veil, 0.18, { BackgroundTransparency = 0 })
		task.delay(0.2, function()
			veil:Destroy()
			if hideToken ~= token then return end
			main.Visible = false; uiScale.Scale = restScale
			mini.Visible = true; miniScale.Scale = 0.2
			tween(miniScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
		end)
	else
		tween(miniScale, 0.15, { Scale = 0.2 }, Enum.EasingStyle.Quad)
		task.delay(0.15, function()
			if hideToken ~= token then return end
			mini.Visible = false
			main.Visible = true; uiScale.Scale = restScale
			popIn()
		end)
	end
end
minimizeBtn.MouseButton1Click:Connect(function() setMinimized(true) end)

-- icon drag (mouse + touch): a press that moves less than 5px is a click and reopens the window
local miniFrom, miniStart, miniMoved
mini.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		miniFrom, miniStart, miniMoved = input.Position, mini.Position, false
		tween(miniScale, 0.1, { Scale = 0.92 })
		local c
		c = input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				c:Disconnect(); miniFrom = nil
				tween(miniScale, 0.15, { Scale = 1 }, Enum.EasingStyle.Back)
				if not miniMoved then setMinimized(false) end
			end
		end)
	end
end)
mini.MouseEnter:Connect(function() if not miniFrom then tween(miniScale, 0.15, { Scale = 1.08 }) end end)
mini.MouseLeave:Connect(function() if not miniFrom then tween(miniScale, 0.15, { Scale = 1 }) end end)
local miniDragConn = UIS.InputChanged:Connect(function(input)
	if miniFrom and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local d = input.Position - miniFrom
		if d.Magnitude > 5 then miniMoved = true end
		if miniMoved then mini.Position = UDim2.new(miniStart.X.Scale, miniStart.X.Offset + d.X, miniStart.Y.Scale, miniStart.Y.Offset + d.Y) end
	end
end)
-- ring spin + status pulse, only while the icon is on screen
local miniAnimConn = RunService.Heartbeat:Connect(function()
	if not mini.Visible then return end
	local t = os.clock()
	ringGrad.Rotation = (t * 60) % 360
	if S.running then
		miniDot.BackgroundColor3 = T.green
		miniDot.BackgroundTransparency = 0.25 + 0.25 * math.sin(t * 4)
	else
		miniDot.BackgroundColor3 = T.muted; miniDot.BackgroundTransparency = 0
	end
end)

local keyConn = UIS.InputBegan:Connect(function(input, typing)
	if typing then return end
	if input.KeyCode.Name == S.uiKey and minimized then
		setMinimized(false)
	elseif input.KeyCode.Name == S.uiKey then
		main.Visible = not main.Visible
		if main.Visible then popIn() else closePopup() end
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 and popup.Visible then
		-- click outside the open list closes it
		local m, p, s = UIS:GetMouseLocation(), popup.AbsolutePosition, popup.AbsoluteSize
		local ap, as = popupOwner.AbsolutePosition, popupOwner.AbsoluteSize
		local inside = function(pp, ss) return m.X >= pp.X and m.X <= pp.X + ss.X and m.Y >= pp.Y and m.Y <= pp.Y + ss.Y end
		if not inside(p, s) and not inside(ap, as) then closePopup() end
	end
end)

local function destroy()
	alive = false
	if qte then qte.nclOn = false end
	if getgenv then getgenv().NCL_SPEED = 1 end
	applyBoost(false)
	hoverConn:Disconnect(); keyConn:Disconnect(); idleConn:Disconnect(); dragConn:Disconnect(); stateConn:Disconnect(); reconnectConn:Disconnect()
	miniDragConn:Disconnect(); miniAnimConn:Disconnect()
	gui:Destroy()
end
closeBtn.MouseButton1Click:Connect(destroy)
unloadBtn.MouseButton1Click:Connect(destroy)
if getgenv then getgenv().NCL_PL = destroy end