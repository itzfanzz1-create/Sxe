--[[
  Blair Helper v1.0
  Fitur: GUI, ESP Player, ESP Item, Fullbright, ESP Ghost, ESP Room Ghost, Smart Ghost Guesser

  CATATAN PENTING:
  Dump game yang dikirim isinya hanya daftar nama script (semua gagal di-decompile),
  jadi nama objek asli di Workspace tidak diketahui. Script ini mendeteksi hantu
  secara heuristik (nama model mengandung "ghost"). Kalau tidak ketemu, ubah CFG.GhostNameHints
  atau set getgenv().BlairGhostName = "NamaModelHantu" (cek pakai Dex Explorer).
]]

if getgenv and getgenv().BlairHelperCleanup then
	pcall(getgenv().BlairHelperCleanup)
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local UIS = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LP = Players.LocalPlayer

------------------------------------------------------------------
-- CONFIG
------------------------------------------------------------------
local CFG = {
	GhostNameHints = { "ghost", "entity", "specter" },
	RoomNameHints = { "room" },
	RoomAttrNames = { "FavoriteRoom", "FavRoom", "GhostRoom", "favoriteRoom" },
	SampleInterval = 0.1, -- detik antar sampel gerak hantu
	SightRange = 70, -- jarak maksimum hantu dianggap "melihat" player (studs)
	SightAngle = 120, -- sudut pandang hantu (derajat)
	TeleportDist = 18, -- lompatan posisi yang dianggap teleport
	MinSamples = 20, -- minimal sampel sebelum menebak
	RoomCell = 14, -- ukuran sel grid untuk estimasi ruangan hantu
}

------------------------------------------------------------------
-- STATE & CLEANUP
------------------------------------------------------------------
local conns = {}
local function track(c) conns[#conns + 1] = c return c end

local State = {
	ESP = false,
	ItemESP = false,
	Fullbright = false,
	GhostESP = false,
	RoomESP = false,
	Guesser = true,
}

local gui -- ScreenGui
local espFolder

local function parentGui(g)
	local ok, hui = pcall(function() return gethui and gethui() end)
	if ok and hui then g.Parent = hui return end
	if not pcall(function() g.Parent = game:GetService("CoreGui") end) then
		g.Parent = LP:WaitForChild("PlayerGui")
	end
end

------------------------------------------------------------------
-- HELPERS
------------------------------------------------------------------
local function myRoot()
	local c = LP.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function nameMatch(n, list)
	n = string.lower(n)
	for _, h in ipairs(list) do
		if string.find(n, h, 1, true) then return true end
	end
	return false
end

local function modelRoot(m)
	return m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart", true)
end

------------------------------------------------------------------
-- ESP TAG (billboard + highlight)
------------------------------------------------------------------
local function makeTag(adornee, highlightTarget, color)
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(160, 34)
	bb.StudsOffset = Vector3.new(0, 3, 0)
	bb.AlwaysOnTop = true
	bb.Adornee = adornee
	bb.ResetOnSpawn = false
	bb.Parent = espFolder

	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.BackgroundTransparency = 1
	lbl.TextColor3 = color
	lbl.TextStrokeTransparency = 0
	lbl.Font = Enum.Font.GothamBold
	lbl.TextSize = 13
	lbl.Text = ""
	lbl.Parent = bb

	local hl
	if highlightTarget then
		hl = Instance.new("Highlight")
		hl.Adornee = highlightTarget
		hl.FillColor = color
		hl.OutlineColor = color
		hl.FillTransparency = 0.65
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		hl.Parent = espFolder
	end
	return { bb = bb, lbl = lbl, hl = hl }
end

local function destroyTag(t)
	if t.bb then t.bb:Destroy() end
	if t.hl then t.hl:Destroy() end
end

local function dist(part)
	local r = myRoot()
	if r and part then return math.floor((part.Position - r.Position).Magnitude) end
	return 0
end

------------------------------------------------------------------
-- FULLBRIGHT
------------------------------------------------------------------
local origLight
local function applyFullbright()
	Lighting.Brightness = 2
	Lighting.ClockTime = 14
	Lighting.FogEnd = 1e6
	Lighting.FogStart = 1e6
	Lighting.GlobalShadows = false
	Lighting.Ambient = Color3.fromRGB(190, 190, 190)
	Lighting.OutdoorAmbient = Color3.fromRGB(190, 190, 190)
end

local function setFullbright(on)
	if on then
		origLight = origLight or {
			Brightness = Lighting.Brightness,
			ClockTime = Lighting.ClockTime,
			FogEnd = Lighting.FogEnd,
			FogStart = Lighting.FogStart,
			GlobalShadows = Lighting.GlobalShadows,
			Ambient = Lighting.Ambient,
			OutdoorAmbient = Lighting.OutdoorAmbient,
		}
	elseif origLight then
		for k, v in pairs(origLight) do pcall(function() Lighting[k] = v end) end
		origLight = nil
	end
end

------------------------------------------------------------------
-- GHOST FINDER
------------------------------------------------------------------
local ghost, ghostRoot
local function isGoodGhost(m)
	if not m or not m.Parent or not m:IsA("Model") then return false end
	if Players:GetPlayerFromCharacter(m) then return false end
	local r = modelRoot(m)
	return r ~= nil
end

local function findGhost()
	if ghost and isGoodGhost(ghost) then
		ghostRoot = modelRoot(ghost)
		return ghost
	end
	ghost, ghostRoot = nil, nil
	local manual = getgenv and getgenv().BlairGhostName
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d:IsA("Model") and not Players:GetPlayerFromCharacter(d) then
			local match
			if manual then
				match = (d.Name == manual)
			else
				match = nameMatch(d.Name, CFG.GhostNameHints) or d:GetAttribute("IsGhost") == true
			end
			if match and isGoodGhost(d) then
				ghost = d
				ghostRoot = modelRoot(d)
				return d
			end
		end
	end
	return nil
end

------------------------------------------------------------------
-- ESP UPDATE (player, item, ghost)
------------------------------------------------------------------
local playerTags, itemTags = {}, {}
local ghostTag

local function updatePlayerESP()
	for plr, t in pairs(playerTags) do
		if not plr.Parent or not State.ESP or not plr.Character then
			destroyTag(t)
			playerTags[plr] = nil
		end
	end
	if not State.ESP then return end
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= LP and plr.Character then
			local root = plr.Character:FindFirstChild("HumanoidRootPart")
			if root then
				local t = playerTags[plr]
				if t and t.bb.Adornee ~= root then
					destroyTag(t)
					t = nil
				end
				if not t then
					t = makeTag(root, plr.Character, Color3.fromRGB(80, 200, 255))
					playerTags[plr] = t
				end
				local hum = plr.Character:FindFirstChildOfClass("Humanoid")
				local hp = hum and math.floor(hum.Health) or 0
				t.lbl.Text = string.format("%s [%dm] HP:%d", plr.DisplayName, dist(root), hp)
			end
		end
	end
end

local lastItemScan = 0
local function updateItemESP()
	if not State.ItemESP then
		for k, t in pairs(itemTags) do destroyTag(t) itemTags[k] = nil end
		return
	end
	if os.clock() - lastItemScan > 2 then
		lastItemScan = os.clock()
		local found, n = {}, 0
		for _, d in ipairs(Workspace:GetDescendants()) do
			if d:IsA("ProximityPrompt") then
				local p = d.Parent
				if p and p:IsA("BasePart") then
					found[p] = (d.ObjectText ~= "" and d.ObjectText) or (d.ActionText ~= "" and d.ActionText) or p.Name
					n += 1
					if n >= 80 then break end
				end
			end
		end
		for part, t in pairs(itemTags) do
			if not found[part] then destroyTag(t) itemTags[part] = nil end
		end
		for part, label in pairs(found) do
			if not itemTags[part] then
				local t = makeTag(part, nil, Color3.fromRGB(255, 220, 90))
				t.lbl.TextSize = 11
				t.label = label
				itemTags[part] = t
			else
				itemTags[part].label = label
			end
		end
	end
	for part, t in pairs(itemTags) do
		if part.Parent then
			t.lbl.Text = string.format("%s [%dm]", t.label or part.Name, dist(part))
		end
	end
end

local function updateGhostESP()
	if not State.GhostESP then
		if ghostTag then destroyTag(ghostTag) ghostTag = nil end
		return
	end
	findGhost()
	if not ghost or not ghostRoot then
		if ghostTag then destroyTag(ghostTag) ghostTag = nil end
		return
	end
	if ghostTag and ghostTag.bb.Adornee ~= ghostRoot then
		destroyTag(ghostTag)
		ghostTag = nil
	end
	if not ghostTag then
		ghostTag = makeTag(ghostRoot, ghost, Color3.fromRGB(255, 60, 60))
	end
	ghostTag.lbl.Text = string.format("GHOST [%dm]", dist(ghostRoot))
end

------------------------------------------------------------------
-- ROOM ESP (ruangan hantu)
------------------------------------------------------------------
local roomGrid = {} -- ["x:z"] = {t=dwell, sx, sz, sy}
local roomTag, roomHL, roomPart
local roomLabelText = "Ghost Room (estimasi)"
local lastRoomScan = 0

local function readRoomName()
	-- coba baca atribut / value bawaan game kalau ada
	local sources = { ghost, Workspace, ReplicatedStorage }
	for _, src in ipairs(sources) do
		if src then
			for _, a in ipairs(CFG.RoomAttrNames) do
				local v = src:GetAttribute(a)
				if typeof(v) == "string" and v ~= "" then return v end
				local ch = src:FindFirstChild(a)
				if ch and ch:IsA("StringValue") and ch.Value ~= "" then return ch.Value end
				if ch and ch:IsA("ObjectValue") and ch.Value then return ch.Value.Name, ch.Value end
			end
		end
	end
	return nil
end

local function findRoomInstanceByName(name)
	for _, d in ipairs(Workspace:GetDescendants()) do
		if (d:IsA("Model") or d:IsA("Folder") or d:IsA("BasePart")) and d.Name == name then
			return d
		end
	end
end

local function findRoomContaining(pos)
	local best, bestVol
	for _, d in ipairs(Workspace:GetDescendants()) do
		if (d:IsA("Model") or d:IsA("Folder")) and nameMatch(d.Name, CFG.RoomNameHints) then
			local ok, cf, size
			if d:IsA("Model") then
				ok, cf, size = pcall(function() local c, s = d:GetBoundingBox() return c, s end)
				if ok and cf then
					local rel = cf:PointToObjectSpace(pos)
					if math.abs(rel.X) <= size.X / 2 and math.abs(rel.Y) <= size.Y / 2 + 8 and math.abs(rel.Z) <= size.Z / 2 then
						local vol = size.X * size.Y * size.Z
						if not bestVol or vol < bestVol then best, bestVol = d, vol end
					end
				end
			end
		elseif d:IsA("BasePart") and nameMatch(d.Name, CFG.RoomNameHints) then
			local rel = d.CFrame:PointToObjectSpace(pos)
			local s = d.Size
			if math.abs(rel.X) <= s.X / 2 and math.abs(rel.Z) <= s.Z / 2 and math.abs(rel.Y) <= s.Y / 2 + 8 then
				local vol = s.X * s.Y * s.Z
				if not bestVol or vol < bestVol then best, bestVol = d, vol end
			end
		end
	end
	return best
end

local function recordRoomSample(dt, speed)
	if not ghostRoot then return end
	-- dwell time: waktu hantu berada di area (lebih berbobot saat pelan / diam)
	local p = ghostRoot.Position
	local cx = math.floor(p.X / CFG.RoomCell)
	local cz = math.floor(p.Z / CFG.RoomCell)
	local key = cx .. ":" .. cz
	local c = roomGrid[key]
	if not c then
		c = { t = 0, cx = cx, cz = cz, sy = 0, n = 0 }
		roomGrid[key] = c
	end
	local w = speed < 3 and 1.5 or 0.5
	c.t += dt * w
	c.sy += p.Y
	c.n += 1
end

local function bestRoomCenter()
	local best, bestScore
	for _, c in pairs(roomGrid) do
		local score = 0
		for dx = -1, 1 do
			for dz = -1, 1 do
				local n = roomGrid[(c.cx + dx) .. ":" .. (c.cz + dz)]
				if n then score += n.t * ((dx == 0 and dz == 0) and 1 or 0.5) end
			end
		end
		if not bestScore or score > bestScore then best, bestScore = c, score end
	end
	if not best then return nil end
	return Vector3.new((best.cx + 0.5) * CFG.RoomCell, best.sy / math.max(best.n, 1), (best.cz + 0.5) * CFG.RoomCell), bestScore
end

local function clearRoomVisual()
	if roomTag then destroyTag(roomTag) roomTag = nil end
	if roomHL then roomHL:Destroy() roomHL = nil end
	if roomPart then roomPart:Destroy() roomPart = nil end
end

local function updateRoomESP()
	if not State.RoomESP then clearRoomVisual() return end
	local named, inst = readRoomName()
	local target, label
	if named then
		inst = inst or findRoomInstanceByName(named)
		label = "Ghost Room: " .. named
		target = inst
	end
	local center = bestRoomCenter()
	if not target and center and os.clock() - lastRoomScan > 4 then
		lastRoomScan = os.clock()
		target = findRoomContaining(center)
		if target then
			roomLabelText = "Ghost Room: " .. target.Name .. " (estimasi)"
		else
			roomLabelText = "Ghost Room (estimasi)"
		end
		roomHL = roomHL
		if roomHL then roomHL.Adornee = nil end
		clearRoomVisual()
		if target and (target:IsA("Model") or target:IsA("BasePart")) then
			roomHL = Instance.new("Highlight")
			roomHL.Adornee = target
			roomHL.FillColor = Color3.fromRGB(190, 80, 255)
			roomHL.OutlineColor = Color3.fromRGB(190, 80, 255)
			roomHL.FillTransparency = 0.8
			roomHL.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			roomHL.Parent = espFolder
		end
	end
	label = label or roomLabelText
	local pos = center
	if inst and inst:IsA("Model") then
		local ok, cf = pcall(function() return inst:GetBoundingBox() end)
		if ok then pos = cf.Position end
	elseif inst and inst:IsA("BasePart") then
		pos = inst.Position
	end
	if not pos then clearRoomVisual() return end
	if not roomPart then
		roomPart = Instance.new("Part")
		roomPart.Anchored = true
		roomPart.CanCollide = false
		roomPart.CanQuery = false
		roomPart.CanTouch = false
		roomPart.Transparency = 1
		roomPart.Size = Vector3.new(1, 1, 1)
		roomPart.Parent = espFolder
	end
	roomPart.Position = pos
	if not roomTag then
		roomTag = makeTag(roomPart, nil, Color3.fromRGB(190, 80, 255))
	end
	local r = myRoot()
	local d = r and math.floor((pos - r.Position).Magnitude) or 0
	roomTag.lbl.Text = string.format("%s [%dm]", label, d)
end

------------------------------------------------------------------
-- SMART GHOST GUESSER
------------------------------------------------------------------
local G = {}
local function resetGuesser()
	G = {
		last = nil, lastT = nil,
		losSpeeds = {}, noLosSpeeds = {},
		early = {}, late = {},
		all = {},
		losDur = 0,
		teleports = 0,
		samples = 0,
	}
	roomGrid = {}
end
resetGuesser()

local function push(t, v, cap)
	t[#t + 1] = v
	if #t > cap then table.remove(t, 1) end
end

local function avg(t)
	if #t == 0 then return nil end
	local s = 0
	for _, v in ipairs(t) do s += v end
	return s / #t
end

local function stddev(t, m)
	if #t < 2 or not m then return nil end
	local s = 0
	for _, v in ipairs(t) do s += (v - m) ^ 2 end
	return math.sqrt(s / #t)
end

local function ghostSeesMe(dir)
	local r = myRoot()
	if not r or not ghostRoot then return false end
	local toMe = r.Position - ghostRoot.Position
	local d = toMe.Magnitude
	if d > CFG.SightRange or d < 0.1 then return false end
	local flatDir = Vector3.new(dir.X, 0, dir.Z)
	local flatTo = Vector3.new(toMe.X, 0, toMe.Z)
	if flatDir.Magnitude < 0.01 or flatTo.Magnitude < 0.01 then return false end
	local ang = math.deg(math.acos(math.clamp(flatDir.Unit:Dot(flatTo.Unit), -1, 1)))
	if ang > CFG.SightAngle / 2 then return false end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ghost, LP.Character }
	local origin = ghostRoot.Position + Vector3.new(0, 2, 0)
	local hit = Workspace:Raycast(origin, (r.Position + Vector3.new(0, 1.5, 0)) - origin, params)
	return hit == nil
end

local function sampleGhost()
	if not State.Guesser then return end
	findGhost()
	if not ghostRoot then G.last = nil return end
	local now = os.clock()
	local p = ghostRoot.Position
	if G.last then
		local dt = now - G.lastT
		if dt > 0.02 then
			local delta = p - G.last
			local flat = Vector3.new(delta.X, 0, delta.Z)
			if flat.Magnitude > CFG.TeleportDist then
				G.teleports += 1
				G.losDur = 0
			else
				local speed = flat.Magnitude / dt
				recordRoomSample(dt, speed)
				if speed > 0.6 then
					local los = ghostSeesMe(flat)
					G.samples += 1
					push(G.all, speed, 300)
					if los then
						G.losDur += dt
						push(G.losSpeeds, speed, 200)
						if G.losDur < 1.5 then push(G.early, speed, 100)
						elseif G.losDur > 4 then push(G.late, speed, 100) end
					else
						G.losDur = 0
						push(G.noLosSpeeds, speed, 200)
					end
				end
			end
			G.last, G.lastT = p, now
		end
	else
		G.last, G.lastT = p, now
	end
end

local function closeness(x, target, sigma)
	return math.exp(-((x - target) ^ 2) / (2 * sigma * sigma))
end

-- Edit tabel ini sesuai hantu asli Blair (lihat wiki). f(F) -> skor 0..1
local Profiles = {
	{
		name = "Revenant",
		f = function(F)
			if F.ratio then return 0.1 + 0.9 * closeness(F.ratio, 2.7, 0.9) end
			return 0.15 * (F.cv and math.min(F.cv * 2, 1) or 0)
		end,
	},
	{
		name = "Konstan (Spirit/Normal)",
		f = function(F)
			local s = 0.2
			if F.cv then s = closeness(F.cv, 0.04, 0.12) end
			if F.ratio then s = s * (0.2 + 0.8 * closeness(F.ratio, 1.0, 0.25)) end
			return s
		end,
	},
	{
		name = "Ramp (makin cepat saat dilihat lama)",
		f = function(F)
			if F.ramp then
				local s = closeness(F.ramp, 1.8, 0.5)
				if F.ratio then s = s * (0.3 + 0.7 * closeness(F.ratio, 1.5, 0.7)) end
				return 0.05 + 0.95 * s
			end
			return 0.08
		end,
	},
	{
		name = "Teleporter / Blink",
		f = function(F)
			if F.teleports >= 3 then return 0.9 end
			if F.teleports >= 1 then return 0.4 end
			return 0.03
		end,
	},
	{
		name = "Variabel (kecepatan acak)",
		f = function(F)
			if not F.cv then return 0.1 end
			local s = closeness(F.cv, 0.3, 0.12)
			if F.ratio then s = s * (0.3 + 0.7 * closeness(F.ratio, 1.0, 0.35)) end
			return s
		end,
	},
}

local function computeGuesses()
	if G.samples < CFG.MinSamples then return nil end
	local F = { teleports = G.teleports }
	local aAll = avg(G.all)
	local sd = stddev(G.all, aAll)
	F.cv = (aAll and sd and aAll > 0) and (sd / aAll) or nil
	if #G.losSpeeds >= 8 and #G.noLosSpeeds >= 8 then
		F.ratio = avg(G.losSpeeds) / math.max(avg(G.noLosSpeeds), 0.1)
	end
	if #G.early >= 5 and #G.late >= 5 then
		F.ramp = avg(G.late) / math.max(avg(G.early), 0.1)
	end
	local out, total = {}, 0
	for _, p in ipairs(Profiles) do
		local s = math.max(p.f(F), 0.001)
		out[#out + 1] = { name = p.name, score = s }
		total += s
	end
	for _, o in ipairs(out) do o.pct = o.score / total end
	table.sort(out, function(a, b) return a.pct > b.pct end)
	return out, F
end

------------------------------------------------------------------
-- GUI
------------------------------------------------------------------
gui = Instance.new("ScreenGui")
gui.Name = "BlairHelper"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
parentGui(gui)

espFolder = Instance.new("Folder")
espFolder.Name = "ESP"
espFolder.Parent = gui

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(270, 400)
main.Position = UDim2.fromOffset(20, 80)
main.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
main.BorderSizePixel = 0
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)

local top = Instance.new("Frame")
top.Size = UDim2.new(1, 0, 0, 30)
top.BackgroundColor3 = Color3.fromRGB(110, 40, 170)
top.BorderSizePixel = 0
top.Parent = main
Instance.new("UICorner", top).CornerRadius = UDim.new(0, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -70, 1, 0)
title.Position = UDim2.fromOffset(10, 0)
title.BackgroundTransparency = 1
title.Text = "Blair Helper v1.0"
title.TextColor3 = Color3.new(1, 1, 1)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = top

local function topBtn(txt, xoff)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(28, 22)
	b.Position = UDim2.new(1, xoff, 0, 4)
	b.BackgroundColor3 = Color3.fromRGB(60, 20, 100)
	b.Text = txt
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Font = Enum.Font.GothamBold
	b.TextSize = 14
	b.BorderSizePixel = 0
	b.Parent = top
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
	return b
end
local minBtn = topBtn("-", -64)
local closeBtn = topBtn("X", -32)

local body = Instance.new("ScrollingFrame")
body.Size = UDim2.new(1, -12, 1, -38)
body.Position = UDim2.fromOffset(6, 34)
body.BackgroundTransparency = 1
body.BorderSizePixel = 0
body.ScrollBarThickness = 3
body.AutomaticCanvasSize = Enum.AutomaticSize.Y
body.CanvasSize = UDim2.new()
body.Parent = main
local layout = Instance.new("UIListLayout", body)
layout.Padding = UDim.new(0, 6)

local function toggle(text, key, onChange)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, -6, 0, 28)
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamMedium
	b.TextSize = 13
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Parent = body
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
	local function refresh()
		b.Text = text .. ": " .. (State[key] and "ON" or "OFF")
		b.BackgroundColor3 = State[key] and Color3.fromRGB(40, 140, 80) or Color3.fromRGB(50, 50, 62)
	end
	refresh()
	b.MouseButton1Click:Connect(function()
		State[key] = not State[key]
		refresh()
		if onChange then onChange(State[key]) end
	end)
end

local function header(text)
	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(1, -6, 0, 18)
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextColor3 = Color3.fromRGB(190, 150, 255)
	l.Font = Enum.Font.GothamBold
	l.TextSize = 12
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = body
	return l
end

header("VISUAL")
toggle("ESP Player", "ESP")
toggle("ESP Item", "ItemESP")
toggle("Fullbright", "Fullbright", setFullbright)
header("HANTU")
toggle("ESP Ghost", "GhostESP")
toggle("ESP Room Ghost", "RoomESP", function(on) if not on then clearRoomVisual() end end)
toggle("Smart Ghost Guesser", "Guesser")
header("TEBAKAN HANTU")

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -6, 0, 30)
status.BackgroundTransparency = 1
status.TextWrapped = true
status.TextColor3 = Color3.fromRGB(200, 200, 210)
status.Font = Enum.Font.Gotham
status.TextSize = 11
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.Text = "Menunggu hantu..."
status.Parent = body

local rows = {}
for i = 1, 3 do
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -6, 0, 34)
	row.BackgroundColor3 = Color3.fromRGB(34, 34, 46)
	row.BorderSizePixel = 0
	row.Parent = body
	Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

	local bar = Instance.new("Frame")
	bar.Size = UDim2.fromScale(0, 1)
	bar.BackgroundColor3 = Color3.fromRGB(150, 60, 220)
	bar.BackgroundTransparency = 0.45
	bar.BorderSizePixel = 0
	bar.Parent = row
	Instance.new("UICorner", bar).CornerRadius = UDim.new(0, 6)

	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(1, -8, 1, 0)
	lbl.Position = UDim2.fromOffset(6, 0)
	lbl.BackgroundTransparency = 1
	lbl.TextColor3 = Color3.new(1, 1, 1)
	lbl.Font = Enum.Font.GothamMedium
	lbl.TextSize = 12
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Text = "-"
	lbl.Parent = row
	rows[i] = { bar = bar, lbl = lbl }
end

local resetBtn = Instance.new("TextButton")
resetBtn.Size = UDim2.new(1, -6, 0, 26)
resetBtn.BackgroundColor3 = Color3.fromRGB(150, 50, 50)
resetBtn.BorderSizePixel = 0
resetBtn.Text = "Reset Data Tebakan"
resetBtn.TextColor3 = Color3.new(1, 1, 1)
resetBtn.Font = Enum.Font.GothamMedium
resetBtn.TextSize = 12
resetBtn.Parent = body
Instance.new("UICorner", resetBtn).CornerRadius = UDim.new(0, 6)
resetBtn.MouseButton1Click:Connect(resetGuesser)

local function updateGuessUI()
	if not State.Guesser then
		status.Text = "Guesser nonaktif."
		for _, r in ipairs(rows) do r.lbl.Text = "-" r.bar.Size = UDim2.fromScale(0, 1) end
		return
	end
	if not ghost then
		status.Text = "Hantu belum ketemu. Set getgenv().BlairGhostName kalau perlu."
		for _, r in ipairs(rows) do r.lbl.Text = "-" r.bar.Size = UDim2.fromScale(0, 1) end
		return
	end
	local out, F = computeGuesses()
	if not out then
		status.Text = string.format("Mengumpulkan data gerak... (%d/%d sampel)", G.samples, CFG.MinSamples)
		for _, r in ipairs(rows) do r.lbl.Text = "-" r.bar.Size = UDim2.fromScale(0, 1) end
		return
	end
	status.Text = string.format(
		"Sampel:%d | Lihat player:%d | Teleport:%d%s",
		G.samples, #G.losSpeeds, G.teleports,
		F.ratio and string.format(" | Rasio kecepatan:%.1fx", F.ratio) or " | (butuh data dilihat vs tidak)"
	)
	for i, r in ipairs(rows) do
		local o = out[i]
		if o then
			r.lbl.Text = string.format("%s  %d%%", o.name, math.floor(o.pct * 100 + 0.5))
			r.bar.Size = UDim2.fromScale(o.pct, 1)
		end
	end
end

-- drag
do
	local dragging, startPos, startInput
	track(top.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			startPos = main.Position
			startInput = i.Position
		end
	end))
	track(UIS.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - startInput
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end))
	track(UIS.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))
end

local minimized = false
minBtn.MouseButton1Click:Connect(function()
	minimized = not minimized
	body.Visible = not minimized
	main.Size = minimized and UDim2.fromOffset(270, 30) or UDim2.fromOffset(270, 400)
end)

------------------------------------------------------------------
-- MAIN LOOPS
------------------------------------------------------------------
local acc, accUI, accSample = 0, 0, 0
track(RunService.Heartbeat:Connect(function(dt)
	acc += dt
	accUI += dt
	accSample += dt

	if State.Fullbright then applyFullbright() end

	if accSample >= CFG.SampleInterval then
		accSample = 0
		pcall(sampleGhost)
	end

	if acc >= 0.1 then
		acc = 0
		pcall(updatePlayerESP)
		pcall(updateItemESP)
		pcall(updateGhostESP)
		pcall(updateRoomESP)
	end

	if accUI >= 0.5 then
		accUI = 0
		pcall(updateGuessUI)
	end
end))

local function cleanup()
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	setFullbright(false)
	if gui then gui:Destroy() end
	if getgenv then getgenv().BlairHelperCleanup = nil end
end

closeBtn.MouseButton1Click:Connect(cleanup)
if getgenv then getgenv().BlairHelperCleanup = cleanup end
