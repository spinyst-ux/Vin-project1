--[[
    NCL HUB: Pixel Lineage - Standalone UI
    Ripped & Cleaned from PixelLineage.lua
    Bisa di-run langsung di executor mana aja / di game apa aja buat preview/test UI.
]]

if getgenv and getgenv().NCL_PL_UI then
	pcall(getgenv().NCL_PL_UI)
end

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local CoreGui = game:GetService("CoreGui")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer or Players:GetPropertyChangedSignal("LocalPlayer"):Wait() or Players.LocalPlayer
local pgui = player:WaitForChild("PlayerGui")

-- Dummy / Default State
local S = {
	running = false,
	autoJoin = true,
	autoAttack = true,
	autoSkill = false,
	autoTarget = true,
	autoContinue = true,
	autoQTE = true,
	mode = "Solo",
	mpMode = "Host",
	difficulty = "Normal",
	targetName = "",
	clickMode = "Background",
	skills = {
		{ name = "Quick Slash", on = true },
		{ name = "Shadow Step", on = true },
		{ name = "Blade Tempest", on = false },
	},
	autoChest = true,
	autoPath = true,
	pathStars = "3",
	pathBy = "Reward",
	autoEvent = true,
	eventPrefer = "OFFER BLOOD",
	hideQTE = true,
	autoInvite = false,
	inviteList = "",
	waitParty = true,
	autoAccept = false,
	autoPotion = false,
	potionPct = "40",
	bloodMinHp = "50",
	gameSpeed = "1x",
	autoSell = false,
	sellRarity = { Common = true, Uncommon = true },
	sellType = { weapon = true, head = true, chest = true, legs = true, relic = true, scroll = true },
	webhook = "",
	pingId = "",
	hookClear = true,
	hookDeath = true,
	antiAfk = true,
	autoReconnect = true,
	autoSave = true,
	uiKey = "RightShift",
}

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
		if DEFAULT[k] ~= nil and type(v) == type(DEFAULT[k]) then
			S[k] = v
		end
	end
end

pcall(function()
	if isfile and isfile(SAVE) then
		applyConfig(HttpService:JSONDecode(readfile(SAVE)))
	end
end)

local saved = ""
local function saveConfig()
	if not writefile then return false end
	ensureDir()
	saved = HttpService:JSONEncode(S)
	return pcall(writefile, SAVE, saved)
end

local alive, status, logs, gui = true, "Idle", {}, nil
local refresh
local skillsDirty = true
local sellNote = "Auto Sell: idle"

local function log(m)
	table.insert(logs, 1, os.date("%H:%M:%S") .. "  " .. m)
	if #logs > 60 then table.remove(logs) end
	status = m
end

local httpRequest = (syn and syn.request) or http_request or request or (http and http.request) or (fluxus and fluxus.request)
local function webhook(title, lines, color)
	if S.webhook == "" then return false, "no webhook URL" end
	if not httpRequest then return false, "executor has no request()" end
	local body = {
		username = "NCL HUB",
		embeds = { {
			title = title,
			description = table.concat(lines, "\n"),
			color = color or 0x485CEB,
			footer = { text = "Pixel Lineage | " .. player.Name },
			timestamp = DateTime.now():ToIsoDate(),
		} },
	}
	if S.pingId ~= "" then
		body.content = S.pingId:match("^%d+$") and ("<@" .. S.pingId .. ">") or S.pingId
	end
	local ok, res = pcall(httpRequest, {
		Url = S.webhook,
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = HttpService:JSONEncode(body),
	})
	if not ok or type(res) ~= "table" then return false, tostring(res) end
	local code = tonumber(res.StatusCode) or 0
	return code >= 200 and code < 300, "HTTP " .. code
end

---------------------------------------------------------------- UI (NCL HUB DQR template)
local T = {
	bg = Color3.fromRGB(11, 14, 27),
	panel = Color3.fromRGB(16, 20, 38),
	field = Color3.fromRGB(13, 17, 33),
	stroke = Color3.fromRGB(38, 46, 84),
	text = Color3.fromRGB(232, 236, 255),
	muted = Color3.fromRGB(128, 138, 172),
	accent = Color3.fromRGB(72, 92, 235),
	accent2 = Color3.fromRGB(128, 86, 242),
	green = Color3.fromRGB(28, 220, 150),
	pink = Color3.fromRGB(240, 45, 100),
	idle = Color3.fromRGB(28, 34, 62),
}
local TOGGLE_ON = Color3.fromRGB(40, 150, 70)
local NAV_BLUE, NAV_VIOLET = Color3.fromRGB(79, 124, 255), Color3.fromRGB(139, 92, 246)
local NAV_EDGE, NAV_ICON_ON = Color3.fromRGB(124, 92, 255), Color3.fromRGB(147, 170, 255)
local EDGE, INP = Color3.fromRGB(35, 40, 72), Color3.fromRGB(9, 11, 23)

local activeTweens = setmetatable({}, { __mode = "k" })
local function tween(inst, secs, goals, style)
	local names = {}
	for p in pairs(goals) do names[#names + 1] = p end
	table.sort(names)
	local key, running = table.concat(names, ","), activeTweens[inst]
	if running and running[key] then
		pcall(function() running[key]:Cancel() end)
		running[key] = nil
	end
	if secs <= 0 then
		for p, v in pairs(goals) do pcall(function() inst[p] = v end) end
		return
	end
	pcall(function()
		if not running then running = {}; activeTweens[inst] = running end
		local tw = TweenService:Create(inst, TweenInfo.new(secs, style or Enum.EasingStyle.Quint, Enum.EasingDirection.Out), goals)
		running[key] = tw
		tw:Play()
	end)
end

local function round(o, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 8)
	c.Parent = o
	return c
end

local function stroke(o, c, th)
	local s = Instance.new("UIStroke")
	s.Color = c or T.stroke
	s.Thickness = th or 1
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = o
	return s
end

local function polish(o, k)
	local g = Instance.new("UIGradient")
	g.Rotation = 90
	g.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(k or 214, (k or 214) + 2, (k or 214) + 12))
	g.Parent = o
	return g
end

local function pad(o, l, r, t, b)
	local p = Instance.new("UIPadding")
	p.PaddingLeft, p.PaddingRight, p.PaddingTop, p.PaddingBottom = UDim.new(0, l or 0), UDim.new(0, r or 0), UDim.new(0, t or 0), UDim.new(0, b or 0)
	p.Parent = o
	return p
end

local function makeText(parent, text, size, color, font, xAlign)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextSize = size
	l.TextColor3 = color
	l.Font = font or Enum.Font.Gotham
	l.TextXAlignment = xAlign or Enum.TextXAlignment.Left
	l.Parent = parent
	return l
end

gui = Instance.new("ScreenGui")
gui.Name = "NCL_HUB_PL_UI"
gui.ResetOnSpawn = false
gui.DisplayOrder = 200
gui.IgnoreGuiInset = true
if not pcall(function() gui.Parent = (gethui and gethui()) or CoreGui end) then
	gui.Parent = pgui
end

local W, H = 900, 540
local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(W, H)
main.AnchorPoint = Vector2.new(0.5, 0)
main.Position = UDim2.fromScale(0.5, 0.08)
main.BackgroundColor3 = T.bg
main.BorderSizePixel = 0
main.Active = true
main.ClipsDescendants = true
main.Parent = gui
round(main, 14)
stroke(main)

local uiScale = Instance.new("UIScale")
do
	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
	uiScale.Scale = math.clamp(math.min(vp.X / 940, vp.Y / 600), 0.45, 1)
end
uiScale.Parent = main

local function popIn()
	local rest = uiScale.Scale
	uiScale.Scale = rest * 0.92
	tween(uiScale, 0.32, { Scale = rest }, Enum.EasingStyle.Back)
	local veil = Instance.new("Frame")
	veil.Size = UDim2.fromScale(1, 1)
	veil.BackgroundColor3 = T.bg
	veil.BackgroundTransparency = 0.25
	veil.BorderSizePixel = 0
	veil.ZIndex = 100
	veil.Parent = main
	round(veil, 14)
	tween(veil, 0.3, { BackgroundTransparency = 1 })
	task.delay(0.34, function() veil:Destroy() end)
end
popIn()

-- HEADER
local header = Instance.new("Frame")
header.Size = UDim2.new(1, -24, 0, 64)
header.Position = UDim2.fromOffset(12, 8)
header.BackgroundColor3 = T.panel
header.BorderSizePixel = 0
header.Parent = main
round(header, 12)
stroke(header)
polish(header)

do
	local line = Instance.new("Frame")
	line.Size = UDim2.new(1, -28, 0, 2)
	line.Position = UDim2.new(0, 14, 1, -2)
	line.BackgroundColor3 = Color3.new(1, 1, 1)
	line.BorderSizePixel = 0
	line.Parent = header
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, T.accent),
		ColorSequenceKeypoint.new(0.5, T.accent2),
		ColorSequenceKeypoint.new(1, T.pink),
	})
	g.Parent = line

	local box = Instance.new("Frame")
	box.Size = UDim2.fromOffset(40, 40)
	box.Position = UDim2.fromOffset(12, 12)
	box.BackgroundColor3 = Color3.fromRGB(10, 14, 26)
	box.BorderSizePixel = 0
	box.Parent = header
	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(0.24, 0)
	bc.Parent = box

	local mark = makeText(box, "NCL", 14, Color3.new(1, 1, 1), Enum.Font.GothamBlack, Enum.TextXAlignment.Center)
	mark.Size = UDim2.fromScale(1, 1)
	local mg = Instance.new("UIGradient")
	mg.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(64, 132, 255)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(160, 90, 245)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(240, 70, 145)),
	})
	mg.Parent = mark

	local title = makeText(header, '<font color="#FFFFFF">NCL</font> <font color="#5C86FF">HUB</font>', 24, T.text, Enum.Font.GothamBlack)
	title.RichText = true
	title.Size = UDim2.new(0, 170, 1, 0)
	title.Position = UDim2.fromOffset(60, 0)

	local div = Instance.new("Frame")
	div.Size = UDim2.fromOffset(1, 30)
	div.Position = UDim2.fromOffset(236, 17)
	div.BackgroundColor3 = T.stroke
	div.BorderSizePixel = 0
	div.Parent = header
end

-- Draggable
local dragFrom, dragStart
header.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragFrom, dragStart = input.Position, main.Position
		local c
		c = input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragFrom = nil
				c:Disconnect()
			end
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
pill.Size = UDim2.fromOffset(150, 28)
pill.Position = UDim2.fromOffset(246, 18)
pill.BackgroundColor3 = T.muted
pill.BackgroundTransparency = 0.88
pill.BorderSizePixel = 0
pill.Parent = header
round(pill, 14)
local pillEdge = stroke(pill, T.muted)
pillEdge.Transparency = 0.6

local dot = Instance.new("Frame")
dot.AnchorPoint = Vector2.new(0, 0.5)
dot.Size = UDim2.fromOffset(8, 8)
dot.Position = UDim2.new(0, 12, 0.5, 0)
dot.BackgroundColor3 = T.muted
dot.BorderSizePixel = 0
dot.Parent = pill
round(dot, 4)

local stateLabel = makeText(pill, "IDLE", 12, T.muted, Enum.Font.GothamBold)
stateLabel.Size = UDim2.new(1, -36, 1, 0)
stateLabel.Position = UDim2.fromOffset(28, 0)

local statusLabel = makeText(header, "Status: Idle", 12, T.muted)
statusLabel.Size = UDim2.new(0, 330, 1, 0)
statusLabel.Position = UDim2.fromOffset(408, 0)
statusLabel.TextTruncate = Enum.TextTruncate.AtEnd

local function windowButton(x)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(34, 34)
	b.Position = UDim2.fromOffset(x, 15)
	b.BackgroundColor3 = T.field
	b.Text = ""
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	b.Parent = header
	b.Font = Enum.Font.GothamBold
	b.TextSize = 15
	b.TextColor3 = T.text
	round(b, 8)
	polish(b, 200)
	local s = stroke(b)
	b.MouseEnter:Connect(function() tween(s, 0.12, { Color = T.accent }) end)
	b.MouseLeave:Connect(function() tween(s, 0.2, { Color = T.stroke }) end)
	return b
end

local function bar(parent, w, h, rot)
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(0.5, 0.5)
	f.Size = UDim2.fromOffset(w, h)
	f.BackgroundColor3 = T.text
	f.BorderSizePixel = 0
	f.Rotation = rot or 0
	f.Parent = parent
end

local hideQteBtn = windowButton(748)
hideQteBtn.Text = "👁"
local minimizeBtn = windowButton(790)
bar(minimizeBtn, 14, 2)
local closeBtn = windowButton(832)
bar(closeBtn, 17, 2, 45)
bar(closeBtn, 17, 2, -45)

local body = Instance.new("Frame")
body.Size = UDim2.fromScale(1, 1)
body.BackgroundTransparency = 1
body.Parent = main

-- COMPONENTS
local refreshers = {}
local function onRefresh(f) table.insert(refreshers, f) end

local function MakeButton(text, color, parent)
	local b = Instance.new("TextButton")
	b.Text = text
	b.Size = UDim2.new(1, 0, 0, 34)
	b.BackgroundColor3 = color
	b.TextColor3 = T.text
	b.Font = Enum.Font.GothamSemibold
	b.TextSize = 13
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	b.Parent = parent
	round(b, 8)
	local g = Instance.new("UIGradient")
	g.Rotation = 90
	g.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(205, 208, 226))
	g.Parent = b
	local function shade(bottom, s)
		tween(g, s or 0.12, { Color = ColorSequence.new(Color3.new(1, 1, 1), bottom) })
	end
	b.MouseEnter:Connect(function() shade(Color3.fromRGB(245, 246, 255)) end)
	b.MouseLeave:Connect(function() shade(Color3.fromRGB(205, 208, 226)) end)
	b.MouseButton1Down:Connect(function() shade(Color3.fromRGB(150, 154, 180), 0.06) end)
	b.MouseButton1Up:Connect(function() shade(Color3.fromRGB(245, 246, 255), 0.1) end)
	return b
end

local function MakeToggle(text, key, parent)
	local b = MakeButton(text, T.idle, parent)
	b.TextXAlignment = Enum.TextXAlignment.Left
	pad(b, 12)
	local led = Instance.new("Frame")
	led.AnchorPoint = Vector2.new(1, 0.5)
	led.Position = UDim2.new(1, -12, 0.5, 0)
	led.Size = UDim2.fromOffset(34, 18)
	led.BackgroundColor3 = T.stroke
	led.BorderSizePixel = 0
	led.ZIndex = 3
	led.Parent = b
	round(led, 9)

	local knob = Instance.new("Frame")
	knob.AnchorPoint = Vector2.new(0, 0.5)
	knob.Position = UDim2.new(0, 2, 0.5, 0)
	knob.Size = UDim2.fromOffset(14, 14)
	knob.BackgroundColor3 = Color3.new(1, 1, 1)
	knob.BorderSizePixel = 0
	knob.ZIndex = 4
	knob.Parent = led
	round(knob, 7)

	local glow = Instance.new("UIStroke")
	glow.Color = T.green
	glow.Transparency = 1
	glow.Parent = led

	local edge = stroke(b)
	local first = true
	b.MouseButton1Click:Connect(function()
		S[key] = not S[key]
		refresh()
	end)

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
	box.PlaceholderText = placeholder
	box.PlaceholderColor3 = T.muted
	box.Size = UDim2.new(1, 0, 0, 38)
	box.BackgroundColor3 = INP
	box.TextColor3 = T.text
	box.Font = Enum.Font.Gotham
	box.TextSize = 13
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.ClearTextOnFocus = false
	box.BorderSizePixel = 0
	box.TextTruncate = Enum.TextTruncate.AtEnd
	box.Parent = parent
	round(box, 10)
	local s = stroke(box, EDGE)
	local function show()
		box.Text = (secret and S[key] ~= "") and string.rep("•", 28) or S[key]
	end
	show()
	box.Focused:Connect(function()
		tween(s, 0.15, { Color = T.accent, Thickness = 1.5 })
		box.Text = S[key]
	end)
	box.FocusLost:Connect(function()
		tween(s, 0.2, { Color = EDGE, Thickness = 1 })
		S[key] = box.Text
		show()
	end)
	pad(box, 12, 12)
	return box
end

local function MakeRow(parent, height)
	local r = Instance.new("Frame")
	r.Size = UDim2.new(1, 0, 0, height or 38)
	r.BackgroundTransparency = 1
	r.Parent = parent
	local l = Instance.new("UIListLayout")
	l.FillDirection = Enum.FillDirection.Horizontal
	l.VerticalAlignment = Enum.VerticalAlignment.Center
	l.Padding = UDim.new(0, 8)
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Parent = r
	return r
end

local function rowSize(count)
	return UDim2.new(1 / count, -(count - 1) * 8 / count, 1, 0)
end

local function note(text, parent)
	local l = makeText(parent, text, 12, T.muted)
	l.Size = UDim2.new(1, 0, 0, 0)
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.TextWrapped = true
	return l
end

-- DROPDOWNS
local popup = Instance.new("ScrollingFrame")
popup.BackgroundColor3 = Color3.fromRGB(13, 16, 36)
popup.BorderSizePixel = 0
popup.ScrollBarThickness = 3
popup.ScrollBarImageColor3 = NAV_VIOLET
popup.CanvasSize = UDim2.new()
popup.AutomaticCanvasSize = Enum.AutomaticSize.Y
popup.ZIndex = 50
popup.Visible = false
popup.Parent = main
round(popup, 12)
do local e = stroke(popup, NAV_EDGE); e.Transparency = 0.35 end
pad(popup, 6, 8, 6, 6)
do local l = Instance.new("UIListLayout"); l.Padding = UDim.new(0, 4); l.SortOrder = Enum.SortOrder.LayoutOrder; l.Parent = popup end
local popupOwner
local chevrons = {}

local function closePopup()
	if popupOwner and chevrons[popupOwner] then chevrons[popupOwner].Rotation = 0 end
	popup.Visible = false
	popupOwner = nil
end

local function openPopup(anchor, rows)
	for _, c in ipairs(popup:GetChildren()) do
		if c:IsA("GuiButton") or c:IsA("TextLabel") then c:Destroy() end
	end
	for i, r in ipairs(rows) do
		local item = Instance.new("TextButton")
		item.Size = UDim2.new(1, 0, 0, 36)
		item.LayoutOrder = i
		item.Text = ""
		item.AutoButtonColor = false
		item.BackgroundColor3 = r[3] and Color3.fromRGB(44, 42, 104) or Color3.fromRGB(21, 25, 50)
		item.BorderSizePixel = 0
		item.ZIndex = 51
		item.Parent = popup
		round(item, 8)
		if r[3] then stroke(item, NAV_EDGE) end
		local ic = makeText(item, r[2] or "", 16, T.text, Enum.Font.GothamBold, Enum.TextXAlignment.Center)
		ic.Size = UDim2.fromOffset(30, 36)
		ic.Position = UDim2.fromOffset(6, 0)
		ic.ZIndex = 52
		local cap = makeText(item, r[1], 13, r[3] and Color3.new(1, 1, 1) or Color3.fromRGB(190, 196, 230), Enum.Font.GothamBlack)
		cap.Size = UDim2.new(1, -110, 1, 0)
		cap.Position = UDim2.fromOffset(42, 0)
		cap.ZIndex = 52
		cap.TextTruncate = Enum.TextTruncate.AtEnd
		if r[3] then
			local check = makeText(item, "✓", 14, NAV_ICON_ON, Enum.Font.GothamBold, Enum.TextXAlignment.Right)
			check.AnchorPoint = Vector2.new(1, 0.5)
			check.Position = UDim2.new(1, -10, 0.5, 0)
			check.Size = UDim2.fromOffset(18, 18)
			check.ZIndex = 52
		end
		local rest, hover = item.BackgroundColor3, Color3.fromRGB(33, 39, 80)
		item.MouseEnter:Connect(function() if not r[3] then tween(item, 0.15, { BackgroundColor3 = hover }) end end)
		item.MouseLeave:Connect(function() if not r[3] then tween(item, 0.15, { BackgroundColor3 = rest }) end end)
		item.MouseButton1Click:Connect(r[4])
		if r[5] then r[5](item) end
	end
	if #rows == 0 then
		local e = makeText(popup, "Nothing here yet", 12, T.muted, Enum.Font.Gotham, Enum.TextXAlignment.Center)
		e.Size = UDim2.new(1, 0, 0, 32)
		e.ZIndex = 51
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
	f.Size = UDim2.new(1, 0, 0, 40)
	f.BackgroundColor3 = INP
	f.Text = ""
	f.AutoButtonColor = false
	f.BorderSizePixel = 0
	f.Parent = parent
	round(f, 10)
	local s = stroke(f, EDGE)
	local cap = makeText(f, placeholder, 13, T.muted, Enum.Font.GothamBold)
	cap.Size = UDim2.new(1, -50, 1, 0)
	cap.Position = UDim2.fromOffset(14, 0)
	cap.TextTruncate = Enum.TextTruncate.AtEnd
	local chev = makeText(f, "▼", 10, T.muted, Enum.Font.GothamBold, Enum.TextXAlignment.Center)
	chev.AnchorPoint = Vector2.new(1, 0.5)
	chev.Position = UDim2.new(1, -12, 0.5, 0)
	chev.Size = UDim2.fromOffset(18, 18)
	f.MouseEnter:Connect(function() tween(s, 0.12, { Color = T.accent }) end)
	f.MouseLeave:Connect(function() if popupOwner ~= f then tween(s, 0.2, { Color = EDGE }) end end)
	chevrons[f] = chev
	return f, cap
end

local function MakeDropdown(label, key, options, parent)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 40)
	row.BackgroundTransparency = 1
	row.Parent = parent
	makeText(row, label, 13, T.text, Enum.Font.GothamSemibold).Size = UDim2.new(0.42, 0, 1, 0)
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(0.58, 0, 1, 0)
	holder.Position = UDim2.fromScale(0.42, 0)
	holder.Parent = row
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
			if o[1] == S[key] then
				cap.Text = (o[2] and o[2] .. "  " or "") .. o[1]
				cap.TextColor3 = T.green
			end
		end
	end)
	return row
end

-- PAGES
local SIDEBAR_W, PAGE_X, PAGE_W, PAGE_H = 140, 162, 726, 388
local function createPage(title, subtitle)
	local p = Instance.new("ScrollingFrame")
	p.Size = UDim2.fromOffset(PAGE_W, PAGE_H)
	p.Position = UDim2.fromOffset(PAGE_X, 84)
	p.BackgroundColor3 = T.panel
	p.BorderSizePixel = 0
	p.ScrollBarThickness = 4
	p.ScrollBarImageColor3 = T.accent
	p.CanvasSize = UDim2.new()
	p.Visible = false
	p.Parent = body
	round(p, 12)
	stroke(p)
	polish(p)
	pad(p, 16, 18, 14, 14)
	local l = Instance.new("UIListLayout")
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Padding = UDim.new(0, 10)
	l.Parent = p
	l:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		p.CanvasSize = UDim2.fromOffset(0, l.AbsoluteContentSize.Y + 28)
	end)
	p:GetPropertyChangedSignal("CanvasPosition"):Connect(closePopup)
	local head = Instance.new("Frame")
	head.Size = UDim2.new(1, 0, 0, 42)
	head.BackgroundTransparency = 1
	head.Parent = p
	makeText(head, title, 19, T.text, Enum.Font.GothamBold).Size = UDim2.new(1, 0, 0, 24)
	local sub = makeText(head, subtitle, 12, T.muted)
	sub.Size = UDim2.new(1, 0, 0, 16)
	sub.Position = UDim2.fromOffset(0, 25)
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
sidebar.Size = UDim2.fromOffset(SIDEBAR_W, 444)
sidebar.Position = UDim2.fromOffset(12, 84)
sidebar.BackgroundColor3 = T.panel
sidebar.BorderSizePixel = 0
sidebar.Parent = body
round(sidebar, 14)
stroke(sidebar)
polish(sidebar)
pad(sidebar, 8, 8, 8, 8)

local tabBar = Instance.new("ScrollingFrame")
tabBar.Size = UDim2.new(1, 0, 1, -48)
tabBar.BackgroundTransparency = 1
tabBar.BorderSizePixel = 0
tabBar.ScrollBarThickness = 3
tabBar.ScrollBarImageColor3 = T.accent2
tabBar.ScrollBarImageTransparency = 0.4
tabBar.CanvasSize = UDim2.new()
tabBar.AutomaticCanvasSize = Enum.AutomaticSize.Y
tabBar.Parent = sidebar
pad(tabBar, 0, 2, 2, 2)
do local l = Instance.new("UIListLayout"); l.SortOrder = Enum.SortOrder.LayoutOrder; l.Padding = UDim.new(0, 4); l.Parent = tabBar end

local function iconPart(box, x, y, w, h, o)
	o = o or {}
	local p = Instance.new("Frame")
	p.Size = UDim2.fromOffset(w, h)
	p.Position = UDim2.fromOffset(x, y)
	p.BackgroundColor3 = Color3.new(1, 1, 1)
	p.BorderSizePixel = 0
	p.Rotation = o.rot or 0
	p.Parent = box
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
	["Auto Play"] = function(b)
		iconPart(b, 1, 1, 16, 16, { radius = 5, hollow = 1.5 })
		iconPart(b, 5, 6, 7, 2, { radius = 1, rot = 45 })
		iconPart(b, 5, 11, 7, 2, { radius = 1, rot = -45 })
	end,
	["Battle"] = function(b)
		iconPart(b, 1, 8, 16, 2, { radius = 1, rot = 45 })
		iconPart(b, 1, 8, 16, 2, { radius = 1, rot = -45 })
		iconPart(b, 1, 13, 4, 4, { radius = 2 })
		iconPart(b, 13, 13, 4, 4, { radius = 2 })
	end,
	["Run Map"] = function(b)
		iconPart(b, 4, 1, 10, 10, { radius = 5, hollow = 1.5 })
		iconPart(b, 8, 10, 2, 6, { radius = 1 })
		iconPart(b, 2, 15, 14, 2, { radius = 1 })
	end,
	["Auto Sell"] = function(b)
		iconPart(b, 4, 4, 11, 11, { radius = 3, hollow = 1.5, rot = 45 })
		iconPart(b, 6, 6, 3, 3, { radius = 2 })
	end,
	["Webhook"] = function(b)
		iconPart(b, 4, 3, 10, 10, { radius = 5, hollow = 1.5 })
		iconPart(b, 2, 12, 14, 2, { radius = 1 })
		iconPart(b, 7, 15, 4, 3, { radius = 2 })
	end,
	["Misc"] = function(b)
		iconPart(b, 3, 8, 3, 3, { radius = 2 })
		iconPart(b, 8, 8, 3, 3, { radius = 2 })
		iconPart(b, 13, 8, 3, 3, { radius = 2 })
	end,
	["Setting"] = function(b)
		iconPart(b, 2, 4, 14, 2, { radius = 1 })
		iconPart(b, 11, 2, 6, 6, { radius = 3, hollow = 1.5 })
		iconPart(b, 2, 9, 14, 2, { radius = 1 })
		iconPart(b, 4, 7, 6, 6, { radius = 3, hollow = 1.5 })
		iconPart(b, 2, 14, 14, 2, { radius = 1 })
		iconPart(b, 9, 12, 6, 6, { radius = 3, hollow = 1.5 })
	end,
}

local tabs, bottomBar, currentTab = {}, nil, nil
local curtain = Instance.new("Frame")
curtain.BackgroundColor3 = T.panel
curtain.BorderSizePixel = 0
curtain.ZIndex = 40
curtain.Visible = false
curtain.Parent = body
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
	b.Size = UDim2.new(1, 0, 0, 40)
	b.BackgroundColor3 = Color3.new(1, 1, 1)
	b.BackgroundTransparency = 1
	b.Text = text
	b.TextTransparency = 1
	b.TextColor3 = T.muted
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	b.Parent = tabBar
	round(b, 10)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(NAV_BLUE, NAV_VIOLET)
	g.Transparency = NumberSequence.new(0.74, 0.9)
	g.Parent = b
	local edge = stroke(b, NAV_EDGE)
	edge.Transparency = 1
	local strip = Instance.new("Frame")
	strip.Size = UDim2.new(0, 3, 1, -12)
	strip.Position = UDim2.fromOffset(0, 6)
	strip.BackgroundColor3 = Color3.new(1, 1, 1)
	strip.BorderSizePixel = 0
	strip.Visible = false
	strip.Parent = b
	round(strip, 2)
	do local sg = Instance.new("UIGradient"); sg.Rotation = 90; sg.Color = ColorSequence.new(NAV_BLUE, NAV_VIOLET); sg.Parent = strip end
	do local gl = stroke(strip, NAV_VIOLET, 2); gl.Transparency = 0.6 end
	local content = Instance.new("Frame")
	content.Size = UDim2.new(1, -13, 1, 0)
	content.Position = UDim2.fromOffset(13, 0)
	content.BackgroundTransparency = 1
	content.Parent = b
	do
		local l = Instance.new("UIListLayout")
		l.FillDirection = Enum.FillDirection.Horizontal
		l.VerticalAlignment = Enum.VerticalAlignment.Center
		l.SortOrder = Enum.SortOrder.LayoutOrder
		l.Padding = UDim.new(0, 9)
		l.Parent = content
	end
	local iconBox = Instance.new("Frame")
	iconBox.Size = UDim2.fromOffset(18, 18)
	iconBox.BackgroundTransparency = 1
	iconBox.LayoutOrder = 1
	iconBox.Parent = content
	if navIcons[text] then navIcons[text](iconBox) end
	local cap = makeText(content, text, 13, T.muted, Enum.Font.GothamBold)
	cap.Size = UDim2.new(1, -27, 1, 0)
	cap.LayoutOrder = 2
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

local CARD = Color3.fromRGB(17, 20, 42)
local function Card(page, title, hint)
	local c = Instance.new("Frame")
	c.Size = UDim2.new(1, 0, 0, 0)
	c.AutomaticSize = Enum.AutomaticSize.Y
	c.BackgroundColor3 = CARD
	c.BorderSizePixel = 0
	c.Parent = page
	round(c, 12)
	stroke(c, EDGE)
	pad(c, 14, 14, 12, 14)
	local l = Instance.new("UIListLayout")
	l.Padding = UDim.new(0, 8)
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Parent = c
	local head = Instance.new("Frame")
	head.BackgroundTransparency = 1
	head.Size = UDim2.new(1, 0, 0, 20)
	head.AutomaticSize = Enum.AutomaticSize.Y
	head.Parent = c
	local b = Instance.new("Frame")
	b.Size = UDim2.fromOffset(4, 16)
	b.Position = UDim2.fromOffset(0, 2)
	b.BackgroundColor3 = Color3.new(1, 1, 1)
	b.BorderSizePixel = 0
	b.Parent = head
	round(b, 2)
	do local g = Instance.new("UIGradient"); g.Rotation = 90; g.Color = ColorSequence.new(NAV_BLUE, NAV_VIOLET); g.Parent = b end
	do local gl = stroke(b, NAV_VIOLET, 2); gl.Transparency = 0.6 end
	local t = makeText(head, title, 14, T.text, Enum.Font.GothamBold)
	t.Size = UDim2.new(1, -14, 0, 20)
	t.Position = UDim2.fromOffset(14, 0)
	if hint then
		local h = makeText(head, hint, 11, T.muted)
		h.Size = UDim2.new(1, -14, 0, 14)
		h.Position = UDim2.fromOffset(14, 22)
		h.AutomaticSize = Enum.AutomaticSize.Y
		h.TextWrapped = true
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

-- AUTO PLAY PAGE
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

-- BATTLE PAGE
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
		rows[#rows + 1] = {
			i .. ".  " .. sk.name:upper(),
			sk.on and "✅" or "⬜",
			sk.on,
			function() sk.on = not sk.on; skillsDirty = true; refresh() end,
			function(item)
				for j, glyph in ipairs({ "▲", "▼" }) do
					local a = Instance.new("TextButton")
					a.AnchorPoint = Vector2.new(1, 0.5)
					a.Size = UDim2.fromOffset(26, 24)
					a.Position = UDim2.new(1, j == 1 and -62 or -32, 0.5, 0)
					a.BackgroundColor3 = T.idle
					a.Text = glyph
					a.TextColor3 = T.text
					a.Font = Enum.Font.GothamBold
					a.TextSize = 11
					a.AutoButtonColor = false
					a.BorderSizePixel = 0
					a.ZIndex = 53
					a.Parent = item
					round(a, 6)
					a.MouseButton1Click:Connect(function()
						local k = j == 1 and i - 1 or i + 1
						if S.skills[k] then
							S.skills[i], S.skills[k] = S.skills[k], S.skills[i]
							skillsDirty = true
							refresh()
						end
					end)
				end
			end
		}
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
	if popupOwner == skillField then openPopup(skillField, skillRows()) end
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

-- RUN MAP PAGE
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

-- AUTO SELL PAGE
local function chip(parent, label, tbl, key, color)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(0, 32)
	b.AutomaticSize = Enum.AutomaticSize.X
	b.Text = label
	b.Font = Enum.Font.GothamBold
	b.TextSize = 12
	b.AutoButtonColor = false
	b.BorderSizePixel = 0
	b.Parent = parent
	round(b, 8)
	pad(b, 14, 14)
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
	local r = Instance.new("Frame")
	r.BackgroundTransparency = 1
	r.Size = UDim2.new(1, 0, 0, 0)
	r.AutomaticSize = Enum.AutomaticSize.Y
	r.Parent = parent
	local l = Instance.new("UIListLayout")
	l.FillDirection = Enum.FillDirection.Horizontal
	l.Wraps = true
	l.Padding = UDim.new(0, 8)
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Parent = r
	return r
end

do
	local c = Card(sellPage, "Auto Sell", "Every 30s outside battle. Worn, locked and unsellable pieces are never sold.")
	MakeToggle("Auto Sell", "autoSell", c)
	local r = MakeRow(c, 38)
	local now = MakeButton("Sell Now", Color3.fromRGB(19, 156, 98), r)
	now.Size = rowSize(2)
	now.Font = Enum.Font.GothamBold
	local stat = makeText(r, "", 12, T.muted)
	stat.Size = rowSize(2)
	stat.TextWrapped = true
	now.MouseButton1Click:Connect(function()
		sellNote = "Simulated manual sell performed (" .. os.date("%H:%M:%S") .. ")"
		refresh()
	end)
	onRefresh(function() stat.Text = sellNote end)
end
do
	local c = Card(sellPage, "Rarity", "Lit = sold. Secret is never sold.")
	local r = chipRow(c)
	local RC = {
		Common = Color3.fromRGB(170, 176, 190),
		Uncommon = Color3.fromRGB(72, 200, 110),
		Rare = Color3.fromRGB(70, 140, 255),
		Epic = Color3.fromRGB(170, 90, 245),
		Legendary = Color3.fromRGB(250, 170, 50),
	}
	for _, k in ipairs({ "Common", "Uncommon", "Rare", "Epic", "Legendary" }) do
		chip(r, k:upper(), "sellRarity", k, RC[k])
	end
end
do
	local c = Card(sellPage, "Type", "Lit = sold.")
	local r = chipRow(c)
	for _, k in ipairs({
		{ "weapon", "⚔️ WEAPON" },
		{ "head", "🪖 HEAD" },
		{ "chest", "🛡️ CHEST" },
		{ "legs", "👖 LEGS" },
		{ "relic", "💍 RELIC" },
		{ "scroll", "📜 SCROLL" },
	}) do
		chip(r, k[2], "sellType", k[1], NAV_BLUE)
	end
end

-- WEBHOOK PAGE
local setResult
do
	local c = Card(hookPage, "Discord webhook", "Posts the result screen's stats when a run ends.")
	MakeInput("Paste Webhook URL...", "webhook", c, true)
	local testBtn = MakeButton("Send Test Message", NAV_BLUE, c)
	testBtn.Size = UDim2.new(1, 0, 0, 42)
	testBtn.Font = Enum.Font.GothamBold
	testBtn:FindFirstChildOfClass("UICorner").CornerRadius = UDim.new(0, 10)
	local resultBox = Instance.new("Frame")
	resultBox.Size = UDim2.new(1, 0, 0, 40)
	resultBox.BackgroundColor3 = Color3.fromRGB(10, 13, 28)
	resultBox.BorderSizePixel = 0
	resultBox.Parent = c
	round(resultBox, 10)
	stroke(resultBox, EDGE)
	local resultDot = Instance.new("Frame")
	resultDot.AnchorPoint = Vector2.new(0, 0.5)
	resultDot.Position = UDim2.new(0, 13, 0.5, 0)
	resultDot.Size = UDim2.fromOffset(8, 8)
	resultDot.BackgroundColor3 = Color3.fromRGB(90, 96, 144)
	resultDot.BorderSizePixel = 0
	resultDot.Parent = resultBox
	round(resultDot, 4)
	local hookResult = makeText(resultBox, "Result: nothing sent yet.", 12, T.muted)
	hookResult.Position = UDim2.fromOffset(30, 0)
	hookResult.Size = UDim2.new(1, -43, 1, 0)
	hookResult.TextWrapped = true
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

-- MISC PAGE
do
	local c = Card(miscPage, "Utility", "Hide QTE keeps Perfect QTE pressing unseen; Anti AFK stops the idle kick.")
	pair(c, { "Hide QTE", "hideQTE" }, { "Anti AFK", "antiAfk" })
	MakeToggle("Auto Reconnect", "autoReconnect", c)
end

-- SETTING PAGE
local cfgNote
do
	local c = Card(setPage, "Config", "workspace/" .. SAVE)
	MakeToggle("Auto Save", "autoSave", c)
	local r = MakeRow(c, 38)
	local sv = MakeButton("Save Now", Color3.fromRGB(19, 156, 98), r)
	sv.Size = rowSize(2)
	sv.Font = Enum.Font.GothamBold
	local rs = MakeButton("Reset Default", Color3.fromRGB(194, 31, 74), r)
	rs.Size = rowSize(2)
	rs.Font = Enum.Font.GothamBold
	cfgNote = note("", c)
	sv.MouseButton1Click:Connect(function()
		cfgNote.Text = saveConfig() and "Saved." or "Save failed: executor has no writefile"
	end)
	rs.MouseButton1Click:Connect(function()
		local keep = S.skills
		applyConfig(HttpService:JSONDecode(HttpService:JSONEncode(DEFAULT)))
		S.skills = keep
		skillsDirty = true
		cfgNote.Text = "Reset to defaults (skill list kept)."
		refresh()
	end)
end
do
	local c = Card(setPage, "Interface", "Key that hides / shows this window.")
	MakeDropdown("Toggle UI key", "uiKey", { { "RightShift", "⌨️" }, { "RightControl", "⌨️" }, { "LeftAlt", "⌨️" }, { "Insert", "⌨️" }, { "F1", "⌨️" } }, c)
end

local DISCORD_INVITE = "https://discord.gg/SuKX7Gc4B4"

-- BOTTOM BAR: run button
bottomBar = Instance.new("Frame")
bottomBar.Size = UDim2.fromOffset(PAGE_W, 46)
bottomBar.Position = UDim2.fromOffset(PAGE_X, 482)
bottomBar.BackgroundTransparency = 1
bottomBar.Parent = body

local runBtn = MakeButton("", T.accent, bottomBar)
runBtn.Size = UDim2.fromScale(1, 1)
runBtn.TextSize = 15
runBtn.Font = Enum.Font.GothamBlack
runBtn:FindFirstChildOfClass("UICorner").CornerRadius = UDim.new(0, 12)
do local gl = stroke(runBtn, Color3.fromRGB(147, 170, 255)); gl.Transparency = 0.55 end

local lastRunClick = 0
runBtn.MouseButton1Click:Connect(function()
	if os.clock() - lastRunClick < 0.35 then return end
	lastRunClick = os.clock()
	S.running = not S.running
	log(S.running and "Started" or "Stopped")
	refresh()
end)

-- DISCORD BUTTON
local discordBtn = MakeButton("", Color3.fromRGB(88, 101, 242), sidebar)
discordBtn.AnchorPoint = Vector2.new(0, 1)
discordBtn.Size = UDim2.new(1, 0, 0, 40)
discordBtn.Position = UDim2.fromScale(0, 1)
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

local unloadBtn
do
	local c = Card(setPage, "Script", "Removes the window and stops everything.")
	unloadBtn = MakeButton("Unload Script", Color3.fromRGB(194, 31, 74), c)
	unloadBtn.Font = Enum.Font.GothamBold
end

hideQteBtn.MouseButton1Click:Connect(function()
	S.hideQTE = not S.hideQTE
	refresh()
end)

refresh = function()
	if not alive then return end
	for _, f in ipairs(refreshers) do f() end
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
		local m, p, s = UIS:GetMouseLocation(), popup.AbsolutePosition, popup.AbsoluteSize
		local ap, as = popupOwner.AbsolutePosition, popupOwner.AbsoluteSize
		local inside = function(pp, ss) return m.X >= pp.X and m.X <= pp.X + ss.X and m.Y >= pp.Y and m.Y <= pp.Y + ss.Y end
		if not inside(p, s) and not inside(ap, as) then closePopup() end
	end
end)

local function destroy()
	alive = false
	keyConn:Disconnect()
	dragConn:Disconnect()
	gui:Destroy()
end

closeBtn.MouseButton1Click:Connect(destroy)
unloadBtn.MouseButton1Click:Connect(destroy)
if getgenv then getgenv().NCL_PL_UI = destroy end
