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
	continue = { "CONTINUE", "TO BATTLE", "NEXT FLOOR", "NEXT", "CLAIM", "PLAY AGAIN", "RETURN TO CASTLE" },
}

local S = {
	running = false, autoJoin = true, autoAttack = true, autoSkill = false, autoTarget = true, autoContinue = true, autoQTE = true,
	mode = "Solo", mpMode = "Host", difficulty = "Normal", targetName = "", clickMode = "Background",
	skills = {}, autoChest = true, autoPath = true, pathStars = "3", pathBy = "Reward",
	autoEvent = true, eventPrefer = "OFFER BLOOD", hideQTE = true,
	autoInvite = false, inviteList = "", waitParty = true, autoAccept = false, autoPotion = false, potionPct = "40", bloodMinHp = "50", gameSpeed = "1x",
	autoSell = false, sellRarity = { Common = true, Uncommon = true }, sellType = { weapon = true, head = true, chest = true, legs = true, relic = true, scroll = true },
	webhook = "", pingId = "", hookClear = true, hookDeath = true, antiAfk = true, autoSave = true, uiKey = "RightShift",
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
local function scan()
	local list = {}
	for _, d in ipairs(pgui:GetDescendants()) do
		if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text ~= "" and not (gui and d:IsDescendantOf(gui)) then
			local t = norm(d.Text)
			if t ~= "" and shown(d) then list[#list + 1] = { t, d } end
		end
	end
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
					pcall(c.Fire, c)
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
	if S.clickMode == "Mouse" then pcall(mouseClick, b or g); return true end
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
local function pickTarget()
	if not S.autoTarget then return end
	task.wait(0.3)
	local page = pgui:FindFirstChild("FoesPage", true)
	if not page then return end
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
	if row and fireHandlers(row.Pick) then log("Target: " .. row.Name) end
end

---------------------------------------------------------------- WEBHOOK
local httpRequest = (syn and syn.request) or http_request or request or (http and http.request) or (fluxus and fluxus.request)
local runsDone, sessionStart = 0, os.time()

local function webhook(title, lines, color)
	if S.webhook == "" then return false, "no webhook URL" end
	if not httpRequest then return false, "executor has no request()" end
	local body = {
		username = "NCL HUB",
		embeds = { {
			title = title, description = table.concat(lines, "\n"), color = color or 0x485CEB,
			footer = { text = "Pixel Lineage | " .. player.Name }, timestamp = DateTime.now():ToIsoDate(),
		} },
	}
	if S.pingId ~= "" then body.content = S.pingId:match("^%d+$") and ("<@" .. S.pingId .. ">") or S.pingId end
	local ok, res = pcall(httpRequest, {
		Url = S.webhook, Method = "POST", Headers = { ["Content-Type"] = "application/json" }, Body = HttpService:JSONEncode(body),
	})
	if not ok or type(res) ~= "table" then return false, tostring(res) end
	local code = tonumber(res.StatusCode) or 0
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
	-- the list belongs to this hero: drop names this account doesn't have (configs are shared between accounts)
	if next(rows) then
		for i = #S.skills, 1, -1 do
			if not rows[S.skills[i].name] then table.remove(S.skills, i); skillsDirty = true end
		end
	end
	for name in pairs(rows) do
		local known = false
		for _, sk in ipairs(S.skills) do if sk.name == name then known = true end end
		if not known then table.insert(S.skills, { name = name, on = true }); skillsDirty = true end
	end
	return rows
end

---------------------------------------------------------------- PARTY + POTION
local RPGCommand = game:GetService("ReplicatedStorage"):WaitForChild("PlatformBattles"):WaitForChild("Remotes"):WaitForChild("RPGCommand")
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
	-- list title "HP <left>/3 | BREWS ..." : none left this run -> stop trying until the next run starts
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

local function gearProfile()
	local best, bn = nil, -1
	for _, t in ipairs(getgc and getgc(true) or {}) do
		if type(t) == "table" and type(rawget(t, "gearBag")) == "table" then
			local n = 0
			for _ in pairs(t.gearBag) do n += 1 end
			if n > bn then best, bn = t, n end
		end
	end
	return best
end

local function gearType(item)
	local ok, slots = pcall(function() return GearConfig.SlotsFor(item) end)
	local s = ok and type(slots) == "table" and slots[1] or nil
	return s and (s:match("^relic") and "relic" or s) or nil
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
		RPGCommand:FireServer("GearSellMany", { uids = uids })
		sellNote = ("Sold %d piece(s) for ~%d gold (%s)"):format(#uids, gold, os.date("%H:%M:%S"))
		log(sellNote)
	elseif manual then
		sellNote = "Nothing matches the rarity / type filter."
	end
	return #uids
end

local function step()
	local list = scan()
	reportEnd(list)
	if S.autoSell and os.clock() - lastSell > 30 and not find(list, TXT.attack) then sellPass() end
	local attack = find(list, TXT.attack)

	if attack and S.autoPotion and usePotion() then return 1.5 end
	if attack and S.autoPotion then list = scan(); attack = find(list, TXT.attack) end

	if (S.autoAttack or S.autoSkill) and attack then
		if S.autoSkill then
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
			attack = find(scan(), TXT.attack)
		end
		if attack then press(attack); log("Attack"); pickTarget() end
		return 1.5
	end

	if S.autoJoin then
		-- Picking a difficulty re-renders the window: every button found before it is destroyed, so re-scan.
		local function pickDiff()
			press(find(list, S.difficulty:upper())); task.wait(0.4)
			return scan()
		end
		-- own lobby (START RUN (n/max) or WAITING FOR READY): invite the listed players every 20s, and with Wait for
		-- party hold the start until everyone listed who is in this server has joined
		local startBtn = find(list, TXT.start)
		if (startBtn or find(list, TXT.waitReady)) and S.mode == "Multiplayer" and S.autoInvite then
			local want = invitees()
			if os.clock() - lastInvite > 20 and #want > 0 then
				lastInvite = os.clock()
				for _, p in ipairs(want) do RPGCommand:FireServer("RunLobby", { action = "invite", userId = p.UserId }) end
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

	if S.autoContinue then
		-- run map: cards RunMap.Cards.OptionN, each with two rows of 5 star icons (DANGER at y=7, REWARD at y=29). Pick the card whose chosen row is closest to S.pathStars; ties -> leftmost.
		local sign = S.autoPath and find(list, TXT.path)
		local cards = sign and sign:FindFirstAncestor("Cards")
		if cards then
			local best, bestDiff, bestN = nil, math.huge, 0
			local y, want = S.pathBy == "Danger" and 7 or 29, tonumber(S.pathStars) or 3
			for i = 1, 6 do
				local card = cards:FindFirstChild("Option" .. i)
				if card and card.Visible then
					local n = 0
					for _, row in ipairs(card:GetDescendants()) do
						-- each star is an "Icon" frame wrapping the drawn sprite named "star" or "starEmpty"
						if row:IsA("Frame") and row.Position.Y.Offset == y and row:FindFirstChild("Icon") then
							for _, c in ipairs(row:GetChildren()) do
								if c.Name == "Icon" and c:FindFirstChild("star", true) and not c:FindFirstChild("starEmpty", true) then n += 1 end
							end
						end
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
			for _, e in ipairs(list) do
				local b = e[2].Parent
				if e[2].Position.Y.Offset == 8 and b:IsA("TextButton") and b.Text == "" and b.BackgroundTransparency < 0.5 then
					opts[#opts + 1] = { e[1], b }
				end
			end
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
					press(e[2]); log("Chest: " .. e[1]); return 1
				end
			end
		end
		for _, w in ipairs(TXT.continue) do
			local c = find(list, w)
			if c then press(c); log("Click " .. w); return 1.5 end
		end
	end

	status = "Waiting..."
	return 0.2 -- poll fast: the turn menu / next screen is acted on as soon as it shows
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

---------------------------------------------------------------- GAME SPEED
-- Turns are paced by the server, but most of the time between them is the client waiting: battle animations,
-- the enemy "presentation" that gates DefenseTimingReady, the delay before a QTE result is sent, tweens, and this
-- macro's own pauses. All of those go through task.wait / task.delay / wait / delay / TweenService:Create, so those
-- are hooked once per VM and divided by getgenv().NCL_SPEED. QTE timing reads os.clock / GetServerTimeNow and is
-- not touched, so perfect presses stay exact.
local function speed() return (getgenv and getgenv().NCL_SPEED) or 1 end
if getgenv and not getgenv().NCL_SPEED_HOOKED and hookfunction and newcclosure then
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
			if speed() ~= 1 and self == TweenService and typeof(info) == "TweenInfo" and not checkcaller() and getnamecallmethod() == "Create" then
				local s = speed()
				-- rebuilt TweenInfo; reading/constructing here is not a namecall, so the method above stays "Create"
				local ti = TweenInfo.new(info.Time / s, info.EasingStyle, info.EasingDirection, info.RepeatCount, info.Reverses, info.DelayTime / s)
				return old(self, ti, ...)
			end
			return old(self, info, ...)
		end))
	end)
end

---------------------------------------------------------------- AUTO QTE
-- Hooks the game's PixelQTE class (found in GC, shared by every instance through __index) and presses its own
-- pressHandler at the perfect moment, from inside the per-frame step the game runs via self:_run(step).
-- Attack marks (archer/fist/spear/bard): each round starts with _pip(n, "active"); progress = elapsed / targetSeconds,
--   PERFECT when progress hits (openFrom + openTo) / 2. Graded on the client, server gets ThiefSlashResult {hits}.
-- Defense: graded on the server from pressedAt; perfect at startedAt + target * duration (+-32ms).
local qte = getgenv and getgenv().NCL_PL_QTE
if not qte and getgc then
	for _, t in ipairs(getgc(true)) do
		if type(t) == "table" and rawget(t, "_defense") and rawget(t, "_timedMarks") and rawget(t, "_send") then qte = t; break end
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
			return send(self, name, data, ...)
		end
		qte._run = function(self, step, ...)
			return o.run(self, function(...)
				local r = step(...)
				-- Frames are 16ms+ apart and the perfect window shrinks to 18ms on a dodge streak, so once the moment is
				-- within 50ms, spin inside this frame until it arrives and press then (costs one short frame hitch).
				-- The spin is capped at 60ms of real time: server time may only tick per frame, and an uncapped wait on it
				-- inside a frame never ends (that froze the game once).
				local function spinUntil(target, clock)
					local cap = os.clock() + 0.06
					while clock() < target and os.clock() < cap do end
				end
				local now = Workspace:GetServerTimeNow()
				local at, m, hits = self.nclPressAt, self.nclMarks, self.nclStrikes
				if at and self.defense and self.defense.token == self.nclPressToken and now >= at - 0.05 then
					self.nclPressAt = nil
					spinUntil(at, function() return Workspace:GetServerTimeNow() end)
					if self.pressHandler then self.pressHandler() end
				elseif hits and hits[1] and self.defense and self.defense.token == self.nclPressToken and now >= hits[1] - 0.05 then
					-- barrage: one press per strike, in order
					local t = table.remove(hits, 1)
					spinUntil(t, function() return Workspace:GetServerTimeNow() end)
					if self.pressHandler then self.pressHandler() end
				elseif m and m.at and os.clock() >= m.at - 0.05 then
					local t = m.at
					m.at = nil
					spinUntil(t, os.clock)
					if self.pressHandler then self.pressHandler() end
				end
				return r
			end, ...)
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
-- NCL HUB/PixelLineage/debug.txt, rewritten every 3s: visible texts, the button behind each, and the log.
if writefile then
	task.spawn(function()
		while alive do
			pcall(function()
				local out = { "== " .. os.date() .. "  running=" .. tostring(S.running) .. "  status=" .. status, "", "== VISIBLE TEXT" }
				for _, e in ipairs(scan()) do
					local b = buttonOf(e[2])
					out[#out + 1] = string.format("%q [%s] %s | %s", e[1], e[2].ClassName, e[2]:GetFullName(), b and b:GetFullName() or "no button")
				end
				out[#out + 1] = ""; out[#out + 1] = "== LOG"
				for _, l in ipairs(logs) do out[#out + 1] = l end
				ensureDir()
				writefile(DIR .. "/debug.txt", table.concat(out, "\n"))
			end)
			task.wait(3)
		end
	end)
end

local idleConn = player.Idled:Connect(function()
	if not S.antiAfk then return end
	local vu = game:GetService("VirtualUser")
	vu:CaptureController(); vu:ClickButton2(Vector2.new())
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
RunService:BindToRenderStep(CURSOR_STEP, Enum.RenderPriority.Last.Value + 100, function()
	if not main.Visible then return end
	local m, p, s = UIS:GetMouseLocation(), main.AbsolutePosition, main.AbsoluteSize
	if m.X >= p.X and m.X <= p.X + s.X and m.Y >= p.Y and m.Y <= p.Y + s.Y then UIS.MouseIconEnabled = true end
end)
local hoverConn = { Disconnect = function() pcall(function() RunService:UnbindFromRenderStep(CURSOR_STEP) end) end }

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

	-- logo: dark rounded square with a blue -> purple -> pink "NCL"
	local box = Instance.new("Frame")
	box.Size = UDim2.fromOffset(40, 40); box.Position = UDim2.fromOffset(12, 12)
	box.BackgroundColor3 = Color3.fromRGB(10, 14, 26); box.BorderSizePixel = 0; box.Parent = header
	local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(0.24, 0); bc.Parent = box
	local mark = makeText(box, "NCL", 14, Color3.new(1, 1, 1), Enum.Font.GothamBlack, Enum.TextXAlignment.Center)
	mark.Size = UDim2.fromScale(1, 1)
	local mg = Instance.new("UIGradient")
	mg.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(64, 132, 255)), ColorSequenceKeypoint.new(0.5, Color3.fromRGB(160, 90, 245)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(240, 70, 145)),
	})
	mg.Parent = mark

	local title = makeText(header, '<font color="#FFFFFF">NCL</font> <font color="#5C86FF">HUB</font>', 24, T.text, Enum.Font.GothamBlack)
	title.RichText = true; title.Size = UDim2.new(0, 170, 1, 0); title.Position = UDim2.fromOffset(60, 0)
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
tabBar.Size = UDim2.new(1, 0, 1, -48); tabBar.BackgroundTransparency = 1; tabBar.BorderSizePixel = 0
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
		tween(t.btn, 0.2, { BackgroundTransparency = on and 0 or 1, TextColor3 = on and T.text or T.muted })
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
	b.Size = UDim2.new(1, 0, 0, 40); b.BackgroundColor3 = Color3.new(1, 1, 1); b.BackgroundTransparency = 1
	b.Text = text; b.TextTransparency = 1; b.TextColor3 = T.muted; b.BorderSizePixel = 0; b.AutoButtonColor = false; b.Parent = tabBar
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
	local cap = makeText(content, text, 13, T.muted, Enum.Font.GothamBold)
	cap.Size = UDim2.new(1, -27, 1, 0); cap.LayoutOrder = 2
	b:GetPropertyChangedSignal("TextColor3"):Connect(function() cap.TextColor3 = b.TextColor3 end)
	local function syncActive(animate)
		tween(edge, animate and 0.2 or 0, { Transparency = strip.Visible and 0.62 or 1 })
		paintIcon(iconBox, strip.Visible and NAV_ICON_ON or T.muted, animate)
	end
	strip:GetPropertyChangedSignal("Visible"):Connect(function() syncActive(true) end)
	syncActive(false)
	table.insert(tabs, { btn = b, page = page, bar = strip })
	local i = #tabs
	b.MouseButton1Click:Connect(function() switchTab(i) end)
	b.MouseEnter:Connect(function() if not strip.Visible then tween(b, 0.12, { TextColor3 = T.text, BackgroundTransparency = 0.85 }) end end)
	b.MouseLeave:Connect(function() if not strip.Visible then tween(b, 0.2, { TextColor3 = T.muted, BackgroundTransparency = 1 }) end end)
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
	c.Size = UDim2.new(1, 0, 0, 0); c.AutomaticSize = Enum.AutomaticSize.Y; c.BackgroundColor3 = CARD
	c.BorderSizePixel = 0; c.Parent = page
	round(c, 12); stroke(c, EDGE)
	pad(c, 14, 14, 12, 14)
	local l = Instance.new("UIListLayout"); l.Padding = UDim.new(0, 8); l.SortOrder = Enum.SortOrder.LayoutOrder; l.Parent = c
	local head = Instance.new("Frame"); head.BackgroundTransparency = 1; head.Size = UDim2.new(1, 0, 0, hint and 34 or 20); head.Parent = c
	local bar = Instance.new("Frame")
	bar.Size = UDim2.fromOffset(4, 16); bar.Position = UDim2.fromOffset(0, 2); bar.BackgroundColor3 = Color3.new(1, 1, 1)
	bar.BorderSizePixel = 0; bar.Parent = head
	round(bar, 2)
	do local g = Instance.new("UIGradient"); g.Rotation = 90; g.Color = ColorSequence.new(NAV_BLUE, NAV_VIOLET); g.Parent = bar end
	do local gl = stroke(bar, NAV_VIOLET, 2); gl.Transparency = 0.6 end
	local t = makeText(head, title, 14, T.text, Enum.Font.GothamBold); t.Size = UDim2.new(1, -14, 0, 20); t.Position = UDim2.fromOffset(14, 0)
	if hint then
		local h = makeText(head, hint, 11, T.muted); h.Size = UDim2.new(1, -14, 0, 14); h.Position = UDim2.fromOffset(14, 20)
		h.TextTruncate = Enum.TextTruncate.AtEnd
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
	local c = Card(playPage, "Automation", "Joins runs and clicks through result / continue screens.")
	pair(c, { "Auto Join", "autoJoin" }, { "Auto Continue", "autoContinue" })
end
local mpRow
do
	local c = Card(playPage, "Run setup", "Background clicks run the game's own button code; Mouse moves a virtual cursor.")
	MakeDropdown("Mode", "mode", { { "Solo", "🧍" }, { "Multiplayer", "👥" } }, c)
	mpRow = MakeDropdown("Multiplayer", "mpMode", { { "Host", "🏠" }, { "Queue", "🎲" } }, c)
	MakeDropdown("Difficulty", "difficulty", { { "Normal", "🟢" }, { "Hard", "🟡" }, { "Nightmare", "🔴" }, { "Torment", "🟣" } }, c)
	MakeDropdown("Click with", "clickMode", { { "Background", "👻" }, { "Mouse", "🖱️" } }, c)
end
do
	local c = Card(playPage, "Party", "Host invites listed players in this server every 20s; Wait holds START until they joined.")
	pair(c, { "Auto Invite", "autoInvite" }, { "Wait for Party", "waitParty" })
	MakeInput("Usernames to invite, comma separated (friend1, friend2)", "inviteList", c)
	MakeToggle("Auto Accept Invites", "autoAccept", c)
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
	MakeToggle("Auto Path", "autoPath", c)
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
		b.BackgroundColor3 = on and color:Lerp(Color3.new(0, 0, 0), 0.55) or INP
		b.TextColor3 = on and Color3.new(1, 1, 1) or T.muted
		s.Color = on and color or EDGE
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
end
do
	local c = Card(hookPage, "Ping", "Mentioned in every message.")
	MakeInput("@everyone or a user ID (123456789012345678)", "pingId", c)
end

-- MISC
do
	local c = Card(miscPage, "Utility", "Hide QTE keeps Perfect QTE pressing unseen; Anti AFK stops the idle kick.")
	pair(c, { "Hide QTE", "hideQTE" }, { "Anti AFK", "antiAfk" })
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

-- DISCORD (same invite + logo as NCL HUB DQR): the real logo is written once to the workspace and loaded with
-- getcustomasset; a gradient "D" mark is drawn underneath so something always shows.
local DISCORD_INVITE = "https://discord.gg/SuKX7Gc4B4"
local DISCORD_LOGO_B64 = "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"
local function discordLogoBytes()
	local chars, lookup = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", {}
	for i = 1, #chars do lookup[chars:sub(i, i)] = i - 1 end
	local out, bits, nbits = {}, 0, 0
	for i = 1, #DISCORD_LOGO_B64 do
		local v = lookup[DISCORD_LOGO_B64:sub(i, i)]
		if v then
			bits = bits * 64 + v; nbits += 6
			if nbits >= 8 then
				nbits -= 8
				local byte = math.floor(bits / (2 ^ nbits))
				out[#out + 1] = string.char(byte)
				bits -= byte * (2 ^ nbits)
			end
		end
	end
	return table.concat(out)
end
local function discordMark(parent)
	local box = Instance.new("Frame")
	box.Size = UDim2.fromScale(1, 1); box.BackgroundColor3 = Color3.fromRGB(10, 12, 22); box.BorderSizePixel = 0; box.Parent = parent
	local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(0.26, 0); bc.Parent = box
	local d = makeText(box, "D", 14, Color3.new(1, 1, 1), Enum.Font.GothamBlack, Enum.TextXAlignment.Center)
	d.Size = UDim2.fromScale(1, 1)
	local g = Instance.new("UIGradient"); g.Rotation = 45; g.Color = ColorSequence.new(Color3.fromRGB(88, 101, 242), Color3.fromRGB(114, 137, 218)); g.Parent = d
	pcall(function()
		local path = DIR .. "/discordlogo.png"
		ensureDir()
		if not (isfile and isfile(path)) then writefile(path, discordLogoBytes()) end
		local asset = getcustomasset(path)
		if asset and tostring(asset) ~= "" then
			local img = Instance.new("ImageLabel")
			img.Size = UDim2.fromScale(1, 1); img.BackgroundTransparency = 1; img.Image = asset; img.ScaleType = Enum.ScaleType.Fit
			img.ZIndex = box.ZIndex + 2; img.Parent = parent
		end
	end)
	return box
end

-- BOTTOM BAR: run button
bottomBar = Instance.new("Frame")
bottomBar.Size = UDim2.fromOffset(PAGE_W, 46); bottomBar.Position = UDim2.fromOffset(PAGE_X, 482)
bottomBar.BackgroundTransparency = 1; bottomBar.Parent = body
local runBtn = MakeButton("", T.accent, bottomBar)
runBtn.Size = UDim2.fromScale(1, 1); runBtn.TextSize = 15; runBtn.Font = Enum.Font.GothamBlack
runBtn:FindFirstChildOfClass("UICorner").CornerRadius = UDim.new(0, 12)
do local gl = stroke(runBtn, Color3.fromRGB(147, 170, 255)); gl.Transparency = 0.55 end
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
	local holder = Instance.new("Frame"); holder.BackgroundTransparency = 1; holder.Size = UDim2.fromOffset(22, 22)
	holder.AnchorPoint = Vector2.new(0, 0.5); holder.Position = UDim2.new(0, 14, 0.5, 0); holder.Parent = discordBtn
	discordMark(holder)
	local cap = makeText(discordBtn, "DISCORD", 13, Color3.new(1, 1, 1), Enum.Font.GothamBold)
	cap.Size = UDim2.new(1, -46, 1, 0); cap.Position = UDim2.fromOffset(44, 0)
	discordBtn.MouseButton1Click:Connect(function()
		if setclipboard then setclipboard(DISCORD_INVITE) end
		cap.Text = "COPIED!"
		task.delay(1.5, function() if cap.Parent then cap.Text = "DISCORD" end end)
	end)
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

local minimized = false
minimizeBtn.MouseButton1Click:Connect(function()
	minimized = not minimized
	body.Visible = not minimized
	closePopup()
	tween(main, 0.25, { Size = UDim2.fromOffset(W, minimized and 80 or H) })
end)

local keyConn = UIS.InputBegan:Connect(function(input, typing)
	if typing then return end
	if input.KeyCode.Name == S.uiKey then
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
	hoverConn:Disconnect(); keyConn:Disconnect(); idleConn:Disconnect(); dragConn:Disconnect()
	gui:Destroy()
end
closeBtn.MouseButton1Click:Connect(destroy)
unloadBtn.MouseButton1Click:Connect(destroy)
if getgenv then getgenv().NCL_PL = destroy end
