--==========================================================================
--  CON EX  :  COMBAT EDITION  (v3)
--  Base: original Con Ex.  TBOT + Always Backstab + Speed Multiplier are
--  ported from Kicia (Rivals rebuild).  RTX removed.  The GUI is hosted in
--  a protected parent so it stays usable while the Roblox Escape menu is
--  open.  "L" still toggles the window.
--
--  WHAT CHANGED VS ORIGINAL CON EX
--   * RTX / GRAPHICS section deleted (button + lighting/reflectance code).
--     Client tab now holds only the color pickers (ESP / Background / Aim).
--   * Tab bar is now 4 tabs: Client / ESP / Combat / Aim.
--   * New COMBAT tab:
--       - TBOT: triggerbot ported from Kicia's Triggerbot module
--         (kicia.txt 54221-54344): crosshair ray -> reaction-time
--         accumulator -> hold fire -> release-time tail.  Modes
--         Always / Hold / Toggle, rebindable key, team check.
--         Defaults faithful to Kicia: ReactionTime = 0, ReleaseTime = 0.
--         Click delivery uses executor mouse1press/mouse1release with a
--         VirtualUser fallback; Kicia's own route
--         (FighterState:Input("StartShooting")) needs Kicia's internal
--         fighter-context plumbing, which a standalone build doesn't have.
--       - ALWAYS BACKSTAB: ported from Kicia's ViewAngleDriver +
--         always_backstab module (kicia.txt 26187-26524, 29702-29777):
--         rawset hook on ClientFighterCharacterJoints.Update injecting
--         CameraRotationRaw, EncodeCameraRotation upvalue swap inside
--         FighterController._CameraReplicationLoop, slot-10 payload that
--         mirrors the closest alive enemy's root orientation (<= 20 studs),
--         spoof fired through a cloned FireServer on
--         Remotes/Replication/Fighter/UpdateCameraRotation and undone with
--         a ping-delayed flush of the real angle.
--         Standalone adaptations: enemies scanned via Players + team skip
--         (Kicia: fighters.EnemyByPlayer), server head origin approximated
--         as root + 1.75 studs (Kicia: CharacterController:GetServerHeadOrigin),
--         knife gate checks Character/Backpack for "Knife" (Kicia:
--         ItemBehaviors:FindMeleeByName), extra nil/type guards added.
--       - SPEED MULTIPLIER: ported from Kicia's movement.WalkSpeed module
--         (kicia.txt 55575-55697): locates MechanicsController.__index
--         ._GetWalkSpeed, scans its upvalues for the BASE_WALKSPEED table
--         and swaps in a multiplying proxy.  Where Kicia kicks the user on
--         unexpected proxy reads ("Unexpected behavior (client physics 1)"),
--         we serve the real value instead; if the hook cannot load at all,
--         a Humanoid.WalkSpeed enforcement loop takes over (our fallback).
--   * ESCAPE MENU USAGE: the ScreenGuis parent to gethui() when the
--     executor provides a real hidden UI, else they are protected and
--     parented to CoreGui, else PlayerGui (Kicia's hudParent pattern, with
--     protectgui for syn-family executors).  CoreGui-level GUIs render
--     above the Roblox menu overlay and keep receiving mouse input while
--     the Escape menu is open.  TBOT additionally refuses to fire while
--     the cursor is over the panel, so sliders stay safe to drag mid-fight.
--   * Everything else (ESP, Aimbot, color sliders, drag, L-toggle) is the
--     original Con Ex code.  One dead reference in the Box ESP toggle
--     (a stray `withinRange` global read) was cleaned up.
--==========================================================================

local Players          = game:GetService("Players")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- executor function resolver (Kicia's K.fn helper, kicia.txt line 32)
local function execfn(name)
	local v
	pcall(function() v = getfenv(0)[name] end)
	if type(v) ~= "function" then pcall(function() v = getfenv()[name] end) end
	return type(v) == "function" and v or nil
end
local cloneref = execfn("cloneref") or function(x) return x end

-- ── ESP STATE (original Con Ex) ──────────────────────────
local espEnabled   = false
local showNames    = true
local showHealth   = true
local showBox      = false
local showBoxESP   = false
local espMaxDist   = 300  -- max stud distance for ESP visibility
local showDistance = true
local espColor     = Color3.fromHSV(0, 1, 0.9)
local espObjects   = {}

-- window visibility (L key); hoisted so the TBOT engine can read it too
local guiVisible = true

-- ── SCREEN GUI (hosted for Escape-menu usage) ────────────
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "ConEx_Combat"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.DisplayOrder = 999999

local guiHost
do
	local ok, hui = pcall(function()
		return (type(gethui) == "function") and gethui() or nil
	end)
	if ok and hui ~= nil and pcall(function() screenGui.Parent = hui end) then
		guiHost = hui
	else
		local protectGui = execfn("protectgui")
		if not protectGui and type(syn) == "table" and type(syn.protect_gui) == "function" then
			protectGui = syn.protect_gui
		end
		if protectGui then pcall(protectGui, screenGui) end
		local coreOk, coreGui = pcall(game.GetService, game, "CoreGui")
		if coreOk and coreGui and pcall(function() screenGui.Parent = coreGui end) then
			guiHost = coreGui
		else
			guiHost = playerGui
			screenGui.Parent = guiHost
		end
	end
end

-- ── BG BOX ───────────────────────────────────────────────
local bgBox = Instance.new("Frame")
bgBox.Name = "BgBox"
bgBox.Size = UDim2.new(0, 300, 0, 486)
bgBox.Position = UDim2.new(0.633, 0, 0.084, 0)
bgBox.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
bgBox.BorderSizePixel = 0
bgBox.Active = true
bgBox.Draggable = false
bgBox.ZIndex = 5
bgBox.Parent = screenGui
Instance.new("UICorner", bgBox).CornerRadius = UDim.new(0, 10)

local bgStroke = Instance.new("UIStroke")
bgStroke.Color = Color3.fromRGB(60, 60, 60)
bgStroke.Thickness = 1
bgStroke.Parent = bgBox

-- ── DRAG BAR ─────────────────────────────────────────────
local dragBar = Instance.new("Frame")
dragBar.Name = "DragBar"
dragBar.Size = UDim2.new(1, 0, 0, 36)
dragBar.Position = UDim2.new(0, 0, 0, 0)
dragBar.BackgroundColor3 = Color3.fromRGB(10, 10, 10)
dragBar.BorderSizePixel = 0
dragBar.Active = true
dragBar.ZIndex = 8
dragBar.Parent = bgBox
Instance.new("UICorner", dragBar).CornerRadius = UDim.new(0, 10)

local dragBarFix = Instance.new("Frame")
dragBarFix.Size = UDim2.new(1, 0, 0.5, 0)
dragBarFix.Position = UDim2.new(0, 0, 0.5, 0)
dragBarFix.BackgroundColor3 = Color3.fromRGB(10, 10, 10)
dragBarFix.BorderSizePixel = 0
dragBarFix.ZIndex = 8
dragBarFix.Parent = dragBar

local dragIcon = Instance.new("TextLabel")
dragIcon.Size = UDim2.new(1, 0, 1, 0)
dragIcon.BackgroundTransparency = 1
dragIcon.Text = "⠿  Con Ex : Combat  [L]"
dragIcon.TextColor3 = Color3.fromRGB(160, 160, 160)
dragIcon.Font = Enum.Font.GothamBold
dragIcon.TextSize = 13
dragIcon.ZIndex = 9
dragIcon.Parent = dragBar

-- ── TAB BAR (4 tabs now) ─────────────────────────────────
local tabBar = Instance.new("Frame")
tabBar.Size = UDim2.new(1, 0, 0, 36)
tabBar.Position = UDim2.new(0, 0, 0, 36)
tabBar.BackgroundColor3 = Color3.fromRGB(15, 15, 15)
tabBar.BorderSizePixel = 0
tabBar.ZIndex = 8
tabBar.Parent = bgBox

local function makeTabButton(text, xScale)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(0.25, 0, 1, 0)
	btn.Position = UDim2.new(xScale, 0, 0, 0)
	btn.BackgroundColor3 = Color3.fromRGB(22, 22, 22)
	btn.BorderSizePixel = 0
	btn.Text = text
	btn.TextColor3 = Color3.fromRGB(120, 120, 120)
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 13
	btn.ZIndex = 9
	btn.Parent = tabBar
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
	return btn
end

local clientTab = makeTabButton("Client", 0)
clientTab.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
clientTab.TextColor3       = Color3.fromRGB(255, 255, 255)
local espTab    = makeTabButton("ESP", 0.25)
local combatTab = makeTabButton("Combat", 0.5)
local aimTab    = makeTabButton("Aim", 0.75)

local tabUnderline = Instance.new("Frame")
tabUnderline.Size = UDim2.new(0.25, 0, 0, 2)
tabUnderline.Position = UDim2.new(0, 0, 1, -2)
tabUnderline.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
tabUnderline.BorderSizePixel = 0
tabUnderline.ZIndex = 10
tabUnderline.Parent = tabBar

-- ── CLIENT PANEL (RTX removed, color pickers shifted up) ─
local clientPanel = Instance.new("Frame")
clientPanel.Size = UDim2.new(1, 0, 1, -72)
clientPanel.Position = UDim2.new(0, 0, 0, 72)
clientPanel.BackgroundTransparency = 1
clientPanel.ClipsDescendants = true
clientPanel.ZIndex = 6
clientPanel.Visible = true
clientPanel.Parent = bgBox

local clientScroll = Instance.new("ScrollingFrame")
clientScroll.Size = UDim2.new(1, 0, 1, 0)
clientScroll.Position = UDim2.new(0, 0, 0, 0)
clientScroll.BackgroundTransparency = 1
clientScroll.BorderSizePixel = 0
clientScroll.ScrollBarThickness = 4
clientScroll.ScrollBarImageColor3 = Color3.fromRGB(80, 80, 80)
clientScroll.CanvasSize = UDim2.new(0, 0, 0, 220)
clientScroll.ZIndex = 6
clientScroll.Parent = clientPanel

-- ── ESP COLOR SECTION ────────────────────────────────────
local espColorLabel = Instance.new("TextLabel")
espColorLabel.Size = UDim2.new(1, -40, 0, 18)
espColorLabel.Position = UDim2.new(0, 20, 0, 8)
espColorLabel.BackgroundTransparency = 1
espColorLabel.Text = "ESP COLOR"
espColorLabel.TextColor3 = Color3.fromRGB(100, 100, 100)
espColorLabel.Font = Enum.Font.GothamBold
espColorLabel.TextSize = 11
espColorLabel.TextXAlignment = Enum.TextXAlignment.Left
espColorLabel.ZIndex = 7
espColorLabel.Parent = clientScroll

local track = Instance.new("Frame")
track.Size = UDim2.new(0, 260, 0, 14)
track.Position = UDim2.new(0.5, -130, 0, 30)
track.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
track.BorderSizePixel = 0
track.ZIndex = 7
track.Parent = clientScroll
Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)

local gradient = Instance.new("UIGradient")
gradient.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0,    Color3.fromHSV(0,    1, 1)),
	ColorSequenceKeypoint.new(0.17, Color3.fromHSV(0.17, 1, 1)),
	ColorSequenceKeypoint.new(0.33, Color3.fromHSV(0.33, 1, 1)),
	ColorSequenceKeypoint.new(0.5,  Color3.fromHSV(0.5,  1, 1)),
	ColorSequenceKeypoint.new(0.67, Color3.fromHSV(0.67, 1, 1)),
	ColorSequenceKeypoint.new(0.83, Color3.fromHSV(0.83, 1, 1)),
	ColorSequenceKeypoint.new(1,    Color3.fromHSV(1,    1, 1)),
})
gradient.Parent = track

local knob = Instance.new("Frame")
knob.Size = UDim2.new(0, 20, 0, 20)
knob.Position = UDim2.new(0, -10, 0.5, -10)
knob.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
knob.BorderSizePixel = 0
knob.ZIndex = 9
knob.Parent = track
Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

local knobStroke = Instance.new("UIStroke")
knobStroke.Color = Color3.fromRGB(255, 255, 255)
knobStroke.Thickness = 2
knobStroke.Transparency = 0.4
knobStroke.Parent = knob

local hexLabel = Instance.new("TextLabel")
hexLabel.Size = UDim2.new(1, -40, 0, 14)
hexLabel.Position = UDim2.new(0, 20, 0, 48)
hexLabel.BackgroundTransparency = 1
hexLabel.Text = "#FF0000"
hexLabel.TextColor3 = Color3.fromRGB(120, 120, 120)
hexLabel.Font = Enum.Font.Code
hexLabel.TextSize = 10
hexLabel.TextXAlignment = Enum.TextXAlignment.Left
hexLabel.ZIndex = 7
hexLabel.Parent = clientScroll

-- ── BACKGROUND COLOR SECTION ─────────────────────────────
local bgColorLabel = Instance.new("TextLabel")
bgColorLabel.Size = UDim2.new(1, -40, 0, 18)
bgColorLabel.Position = UDim2.new(0, 20, 0, 72)
bgColorLabel.BackgroundTransparency = 1
bgColorLabel.Text = "BACKGROUND COLOR"
bgColorLabel.TextColor3 = Color3.fromRGB(100, 100, 100)
bgColorLabel.Font = Enum.Font.GothamBold
bgColorLabel.TextSize = 11
bgColorLabel.TextXAlignment = Enum.TextXAlignment.Left
bgColorLabel.ZIndex = 7
bgColorLabel.Parent = clientScroll

local bgTrack = Instance.new("Frame")
bgTrack.Size = UDim2.new(0, 260, 0, 14)
bgTrack.Position = UDim2.new(0.5, -130, 0, 94)
bgTrack.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
bgTrack.BorderSizePixel = 0
bgTrack.ZIndex = 7
bgTrack.Parent = clientScroll
Instance.new("UICorner", bgTrack).CornerRadius = UDim.new(1, 0)

local bgGradient = Instance.new("UIGradient")
bgGradient.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0,    Color3.fromHSV(0,    1, 1)),
	ColorSequenceKeypoint.new(0.17, Color3.fromHSV(0.17, 1, 1)),
	ColorSequenceKeypoint.new(0.33, Color3.fromHSV(0.33, 1, 1)),
	ColorSequenceKeypoint.new(0.5,  Color3.fromHSV(0.5,  1, 1)),
	ColorSequenceKeypoint.new(0.67, Color3.fromHSV(0.67, 1, 1)),
	ColorSequenceKeypoint.new(0.83, Color3.fromHSV(0.83, 1, 1)),
	ColorSequenceKeypoint.new(1,    Color3.fromHSV(1,    1, 1)),
})
bgGradient.Parent = bgTrack

local bgKnob = Instance.new("Frame")
bgKnob.Size = UDim2.new(0, 20, 0, 20)
bgKnob.Position = UDim2.new(0, -10, 0.5, -10)
bgKnob.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
bgKnob.BorderSizePixel = 0
bgKnob.ZIndex = 9
bgKnob.Parent = bgTrack
Instance.new("UICorner", bgKnob).CornerRadius = UDim.new(1, 0)

local bgKnobStroke = Instance.new("UIStroke")
bgKnobStroke.Color = Color3.fromRGB(255, 255, 255)
bgKnobStroke.Thickness = 2
bgKnobStroke.Transparency = 0.4
bgKnobStroke.Parent = bgKnob

local bgHexLabel = Instance.new("TextLabel")
bgHexLabel.Size = UDim2.new(1, -40, 0, 14)
bgHexLabel.Position = UDim2.new(0, 20, 0, 112)
bgHexLabel.BackgroundTransparency = 1
bgHexLabel.Text = "#000000"
bgHexLabel.TextColor3 = Color3.fromRGB(120, 120, 120)
bgHexLabel.Font = Enum.Font.Code
bgHexLabel.TextSize = 10
bgHexLabel.TextXAlignment = Enum.TextXAlignment.Left
bgHexLabel.ZIndex = 7
bgHexLabel.Parent = clientScroll

-- ── AIMBOT CIRCLE COLOR SECTION ──────────────────────────
local aimColorLabel = Instance.new("TextLabel")
aimColorLabel.Size = UDim2.new(1, -40, 0, 18)
aimColorLabel.Position = UDim2.new(0, 20, 0, 136)
aimColorLabel.BackgroundTransparency = 1
aimColorLabel.Text = "AIM CIRCLE COLOR"
aimColorLabel.TextColor3 = Color3.fromRGB(100, 100, 100)
aimColorLabel.Font = Enum.Font.GothamBold
aimColorLabel.TextSize = 11
aimColorLabel.TextXAlignment = Enum.TextXAlignment.Left
aimColorLabel.ZIndex = 7
aimColorLabel.Parent = clientScroll

local aimTrack = Instance.new("Frame")
aimTrack.Size = UDim2.new(0, 260, 0, 14)
aimTrack.Position = UDim2.new(0.5, -130, 0, 158)
aimTrack.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
aimTrack.BorderSizePixel = 0
aimTrack.ZIndex = 7
aimTrack.Parent = clientScroll
Instance.new("UICorner", aimTrack).CornerRadius = UDim.new(1, 0)

local aimTrackGradient = Instance.new("UIGradient")
aimTrackGradient.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0,    Color3.fromHSV(0,    1, 1)),
	ColorSequenceKeypoint.new(0.17, Color3.fromHSV(0.17, 1, 1)),
	ColorSequenceKeypoint.new(0.33, Color3.fromHSV(0.33, 1, 1)),
	ColorSequenceKeypoint.new(0.5,  Color3.fromHSV(0.5,  1, 1)),
	ColorSequenceKeypoint.new(0.67, Color3.fromHSV(0.67, 1, 1)),
	ColorSequenceKeypoint.new(0.83, Color3.fromHSV(0.83, 1, 1)),
	ColorSequenceKeypoint.new(1,    Color3.fromHSV(1,    1, 1)),
})
aimTrackGradient.Parent = aimTrack

local aimKnob = Instance.new("Frame")
aimKnob.Size = UDim2.new(0, 20, 0, 20)
-- Start knob at hue 0 (red, matching default fovStroke color)
aimKnob.Position = UDim2.new(0, -10, 0.5, -10)
aimKnob.BackgroundColor3 = Color3.fromRGB(255, 60, 60)
aimKnob.BorderSizePixel = 0
aimKnob.ZIndex = 9
aimKnob.Parent = aimTrack
Instance.new("UICorner", aimKnob).CornerRadius = UDim.new(1, 0)

local aimKnobStroke = Instance.new("UIStroke")
aimKnobStroke.Color = Color3.fromRGB(255, 255, 255)
aimKnobStroke.Thickness = 2
aimKnobStroke.Transparency = 0.4
aimKnobStroke.Parent = aimKnob

local aimHexLabel = Instance.new("TextLabel")
aimHexLabel.Size = UDim2.new(1, -40, 0, 14)
aimHexLabel.Position = UDim2.new(0, 20, 0, 176)
aimHexLabel.BackgroundTransparency = 1
aimHexLabel.Text = "#FF3C3C"
aimHexLabel.TextColor3 = Color3.fromRGB(120, 120, 120)
aimHexLabel.Font = Enum.Font.Code
aimHexLabel.TextSize = 10
aimHexLabel.TextXAlignment = Enum.TextXAlignment.Left
aimHexLabel.ZIndex = 7
aimHexLabel.Parent = clientScroll

-- ── AIM PANEL ────────────────────────────────────────────
local aimPanel = Instance.new("Frame")
aimPanel.Size = UDim2.new(1, 0, 1, -72)
aimPanel.Position = UDim2.new(0, 0, 0, 72)
aimPanel.BackgroundTransparency = 1
aimPanel.ClipsDescendants = true
aimPanel.ZIndex = 6
aimPanel.Visible = false
aimPanel.Parent = bgBox

local aimScroll = Instance.new("ScrollingFrame")
aimScroll.Size = UDim2.new(1, 0, 1, 0)
aimScroll.Position = UDim2.new(0, 0, 0, 0)
aimScroll.BackgroundTransparency = 1
aimScroll.BorderSizePixel = 0
aimScroll.ScrollBarThickness = 4
aimScroll.ScrollBarImageColor3 = Color3.fromRGB(80, 80, 80)
aimScroll.CanvasSize = UDim2.new(0, 0, 0, 320)
aimScroll.ZIndex = 6
aimScroll.Parent = aimPanel

-- Aimbot state
local aimbotEnabled = false
local aimbotFov     = 150  -- radius in pixels
local aimbotSmooth  = 0.05 -- 0=instant, 1=never reaches
local aimbotMaxDist = 100  -- max stud distance to lock on (10-500)

-- FOV circle overlay (separate ScreenGui so it draws on top of world)
local fovGui = Instance.new("ScreenGui")
fovGui.Name = "AimbotFovGui"
fovGui.ResetOnSpawn = false
fovGui.IgnoreGuiInset = true
fovGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
fovGui.DisplayOrder = 999998
fovGui.Parent = guiHost

-- Draw FOV circle using a Frame with UICorner + UIStroke (no image needed)
local fovCircle = Instance.new("Frame")
fovCircle.Name = "FovCircle"
fovCircle.AnchorPoint = Vector2.new(0.5, 0.5)
fovCircle.BackgroundTransparency = 1
fovCircle.BorderSizePixel = 0
fovCircle.Size = UDim2.new(0, aimbotFov * 2, 0, aimbotFov * 2)
fovCircle.Visible = false
fovCircle.ZIndex = 100
fovCircle.Parent = fovGui
Instance.new("UICorner", fovCircle).CornerRadius = UDim.new(1, 0)

local fovStroke = Instance.new("UIStroke")
fovStroke.Color = Color3.fromRGB(255, 60, 60)
fovStroke.Thickness = 1.5
fovStroke.Transparency = 0.2
fovStroke.Parent = fovCircle

-- ── AIM PANEL UI ─────────────────────────────────────────
local aimSectionLabel = Instance.new("TextLabel")
aimSectionLabel.Size = UDim2.new(1, -40, 0, 18)
aimSectionLabel.Position = UDim2.new(0, 20, 0, 8)
aimSectionLabel.BackgroundTransparency = 1
aimSectionLabel.Text = "AIMBOT"
aimSectionLabel.TextColor3 = Color3.fromRGB(100, 100, 100)
aimSectionLabel.Font = Enum.Font.GothamBold
aimSectionLabel.TextSize = 11
aimSectionLabel.TextXAlignment = Enum.TextXAlignment.Left
aimSectionLabel.ZIndex = 7
aimSectionLabel.Parent = aimScroll

local aimbotBtn = Instance.new("TextButton")
aimbotBtn.Size = UDim2.new(1, -40, 0, 40)
aimbotBtn.Position = UDim2.new(0, 20, 0, 30)
aimbotBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
aimbotBtn.BorderSizePixel = 0
aimbotBtn.Text = "Aimbot  OFF"
aimbotBtn.TextColor3 = Color3.fromRGB(160, 160, 160)
aimbotBtn.Font = Enum.Font.GothamBold
aimbotBtn.TextSize = 14
aimbotBtn.ZIndex = 7
aimbotBtn.Parent = aimScroll
Instance.new("UICorner", aimbotBtn).CornerRadius = UDim.new(0, 8)

local aimbotStroke = Instance.new("UIStroke")
aimbotStroke.Color = Color3.fromRGB(70, 70, 70)
aimbotStroke.Thickness = 1
aimbotStroke.Parent = aimbotBtn

-- FOV label + slider ──────────────────────────────────────
local fovSectionLabel = Instance.new("TextLabel")
fovSectionLabel.Size = UDim2.new(1, -40, 0, 18)
fovSectionLabel.Position = UDim2.new(0, 20, 0, 86)
fovSectionLabel.BackgroundTransparency = 1
fovSectionLabel.Text = "FOV RADIUS  ( " .. aimbotFov .. " px )"
fovSectionLabel.TextColor3 = Color3.fromRGB(100, 100, 100)
fovSectionLabel.Font = Enum.Font.GothamBold
fovSectionLabel.TextSize = 11
fovSectionLabel.TextXAlignment = Enum.TextXAlignment.Left
fovSectionLabel.ZIndex = 7
fovSectionLabel.Parent = aimScroll

local fovTrack = Instance.new("Frame")
fovTrack.Size = UDim2.new(0, 260, 0, 14)
fovTrack.Position = UDim2.new(0.5, -130, 0, 108)
fovTrack.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
fovTrack.BorderSizePixel = 0
fovTrack.ZIndex = 7
fovTrack.Parent = aimScroll
Instance.new("UICorner", fovTrack).CornerRadius = UDim.new(1, 0)

local fovFill = Instance.new("Frame")
fovFill.Size = UDim2.new(aimbotFov / 400, 0, 1, 0)
fovFill.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
fovFill.BorderSizePixel = 0
fovFill.ZIndex = 8
fovFill.Parent = fovTrack
Instance.new("UICorner", fovFill).CornerRadius = UDim.new(1, 0)

local fovKnob = Instance.new("Frame")
fovKnob.Size = UDim2.new(0, 20, 0, 20)
fovKnob.Position = UDim2.new(aimbotFov / 400, -10, 0.5, -10)
fovKnob.BackgroundColor3 = Color3.fromRGB(220, 80, 80)
fovKnob.BorderSizePixel = 0
fovKnob.ZIndex = 9
fovKnob.Parent = fovTrack
Instance.new("UICorner", fovKnob).CornerRadius = UDim.new(1, 0)
local fovKnobStroke = Instance.new("UIStroke")
fovKnobStroke.Color = Color3.fromRGB(255,255,255)
fovKnobStroke.Thickness = 2
fovKnobStroke.Transparency = 0.5
fovKnobStroke.Parent = fovKnob

-- Smooth label + slider ───────────────────────────────────
local smoothSectionLabel = Instance.new("TextLabel")
smoothSectionLabel.Size = UDim2.new(1, -40, 0, 18)
smoothSectionLabel.Position = UDim2.new(0, 20, 0, 140)
smoothSectionLabel.BackgroundTransparency = 1
smoothSectionLabel.Text = "SMOOTH  ( " .. math.floor(aimbotSmooth * 100) .. "% )"
smoothSectionLabel.TextColor3 = Color3.fromRGB(100, 100, 100)
smoothSectionLabel.Font = Enum.Font.GothamBold
smoothSectionLabel.TextSize = 11
smoothSectionLabel.TextXAlignment = Enum.TextXAlignment.Left
smoothSectionLabel.ZIndex = 7
smoothSectionLabel.Parent = aimScroll

local smoothTrack = Instance.new("Frame")
smoothTrack.Size = UDim2.new(0, 260, 0, 14)
smoothTrack.Position = UDim2.new(0.5, -130, 0, 162)
smoothTrack.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
smoothTrack.BorderSizePixel = 0
smoothTrack.ZIndex = 7
smoothTrack.Parent = aimScroll
Instance.new("UICorner", smoothTrack).CornerRadius = UDim.new(1, 0)

local smoothFill = Instance.new("Frame")
smoothFill.Size = UDim2.new(aimbotSmooth, 0, 1, 0)
smoothFill.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
smoothFill.BorderSizePixel = 0
smoothFill.ZIndex = 8
smoothFill.Parent = smoothTrack
Instance.new("UICorner", smoothFill).CornerRadius = UDim.new(1, 0)

local smoothKnob = Instance.new("Frame")
smoothKnob.Size = UDim2.new(0, 20, 0, 20)
smoothKnob.Position = UDim2.new(aimbotSmooth, -10, 0.5, -10)
smoothKnob.BackgroundColor3 = Color3.fromRGB(220, 80, 80)
smoothKnob.BorderSizePixel = 0
smoothKnob.ZIndex = 9
smoothKnob.Parent = smoothTrack
Instance.new("UICorner", smoothKnob).CornerRadius = UDim.new(1, 0)
local smoothKnobStroke = Instance.new("UIStroke")
smoothKnobStroke.Color = Color3.fromRGB(255,255,255)
smoothKnobStroke.Thickness = 2
smoothKnobStroke.Transparency = 0.5
smoothKnobStroke.Parent = smoothKnob

-- MAX DISTANCE slider ────────────────────────────────────
local distSectionLabel = Instance.new("TextLabel")
distSectionLabel.Size = UDim2.new(1, -40, 0, 18)
distSectionLabel.Position = UDim2.new(0, 20, 0, 194)
distSectionLabel.BackgroundTransparency = 1
distSectionLabel.Text = "MAX DISTANCE  ( " .. aimbotMaxDist .. " studs )"
distSectionLabel.TextColor3 = Color3.fromRGB(100, 100, 100)
distSectionLabel.Font = Enum.Font.GothamBold
distSectionLabel.TextSize = 11
distSectionLabel.TextXAlignment = Enum.TextXAlignment.Left
distSectionLabel.ZIndex = 7
distSectionLabel.Parent = aimScroll

local distTrack = Instance.new("Frame")
distTrack.Size = UDim2.new(0, 260, 0, 14)
distTrack.Position = UDim2.new(0.5, -130, 0, 216)
distTrack.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
distTrack.BorderSizePixel = 0
distTrack.ZIndex = 7
distTrack.Parent = aimScroll
Instance.new("UICorner", distTrack).CornerRadius = UDim.new(1, 0)

local distFill = Instance.new("Frame")
distFill.Size = UDim2.new((aimbotMaxDist - 10) / 490, 0, 1, 0)
distFill.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
distFill.BorderSizePixel = 0
distFill.ZIndex = 8
distFill.Parent = distTrack
Instance.new("UICorner", distFill).CornerRadius = UDim.new(1, 0)

local distKnob = Instance.new("Frame")
distKnob.Size = UDim2.new(0, 20, 0, 20)
distKnob.Position = UDim2.new((aimbotMaxDist - 10) / 490, -10, 0.5, -10)
distKnob.BackgroundColor3 = Color3.fromRGB(220, 80, 80)
distKnob.BorderSizePixel = 0
distKnob.ZIndex = 9
distKnob.Parent = distTrack
Instance.new("UICorner", distKnob).CornerRadius = UDim.new(1, 0)
local distKnobStroke = Instance.new("UIStroke")
distKnobStroke.Color = Color3.fromRGB(255,255,255)
distKnobStroke.Thickness = 2
distKnobStroke.Transparency = 0.5
distKnobStroke.Parent = distKnob

local aimInfoLabel = Instance.new("TextLabel")
aimInfoLabel.Size = UDim2.new(1, -40, 0, 40)
aimInfoLabel.Position = UDim2.new(0, 20, 0, 250)
aimInfoLabel.BackgroundTransparency = 1
aimInfoLabel.Text = "Hold right mouse button to aim.\nTargets head inside the FOV circle."
aimInfoLabel.TextColor3 = Color3.fromRGB(90, 90, 90)
aimInfoLabel.Font = Enum.Font.Gotham
aimInfoLabel.TextSize = 11
aimInfoLabel.TextXAlignment = Enum.TextXAlignment.Left
aimInfoLabel.TextWrapped = true
aimInfoLabel.ZIndex = 7
aimInfoLabel.Parent = aimScroll

-- Aimbot toggle
aimbotBtn.MouseButton1Click:Connect(function()
	aimbotEnabled = not aimbotEnabled
	if aimbotEnabled then
		aimbotBtn.Text       = "Aimbot  ON"
		aimbotBtn.TextColor3 = Color3.fromRGB(255, 80, 80)
		TweenService:Create(aimbotBtn,    TweenInfo.new(0.15), { BackgroundColor3 = Color3.fromRGB(45, 15, 15) }):Play()
		TweenService:Create(aimbotStroke, TweenInfo.new(0.15), { Color = Color3.fromRGB(200, 60, 60) }):Play()
		fovCircle.Visible = true
	else
		aimbotBtn.Text       = "Aimbot  OFF"
		aimbotBtn.TextColor3 = Color3.fromRGB(160, 160, 160)
		TweenService:Create(aimbotBtn,    TweenInfo.new(0.15), { BackgroundColor3 = Color3.fromRGB(35, 35, 35) }):Play()
		TweenService:Create(aimbotStroke, TweenInfo.new(0.15), { Color = Color3.fromRGB(70, 70, 70) }):Play()
		fovCircle.Visible = false
	end
end)

-- FOV slider drag
local draggingFov    = false
local draggingSmooth = false
local draggingDist   = false

fovKnob.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 then draggingFov = true end
end)
fovTrack.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 then
		draggingFov = true
	end
end)
smoothKnob.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 then draggingSmooth = true end
end)
smoothTrack.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 then draggingSmooth = true end
end)
distKnob.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 then draggingDist = true end
end)
distTrack.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 then draggingDist = true end
end)

UserInputService.InputEnded:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 then
		draggingFov    = false
		draggingSmooth = false
		draggingDist   = false
	end
end)

-- Helper to compute t from an X position over a track frame
local function trackT(trk, x)
	return math.clamp((x - trk.AbsolutePosition.X) / trk.AbsoluteSize.X, 0, 1)
end

UserInputService.InputChanged:Connect(function(i)
	if i.UserInputType ~= Enum.UserInputType.MouseMovement then return end
	if draggingFov then
		local t = trackT(fovTrack, i.Position.X)
		aimbotFov = math.floor(t * 400)  -- 0 - 400 px
		fovKnob.Position = UDim2.new(t, -10, 0.5, -10)
		fovFill.Size     = UDim2.new(t, 0, 1, 0)
		fovCircle.Size   = UDim2.new(0, aimbotFov * 2, 0, aimbotFov * 2)
		fovSectionLabel.Text = "FOV RADIUS  ( " .. aimbotFov .. " px )"
	elseif draggingSmooth then
		local t = trackT(smoothTrack, i.Position.X)
		aimbotSmooth = t
		smoothKnob.Position = UDim2.new(t, -10, 0.5, -10)
		smoothFill.Size     = UDim2.new(t, 0, 1, 0)
		smoothSectionLabel.Text = "SMOOTH  ( " .. math.floor(t * 100) .. "% )"
	elseif draggingDist then
		local t = trackT(distTrack, i.Position.X)
		aimbotMaxDist = math.floor(10 + t * 490)  -- 10 to 500 studs
		distKnob.Position = UDim2.new(t, -10, 0.5, -10)
		distFill.Size     = UDim2.new(t, 0, 1, 0)
		distSectionLabel.Text = "MAX DISTANCE  ( " .. aimbotMaxDist .. " studs )"
	end
end)

-- ── AIMBOT LOGIC ─────────────────────────────────────────
local Camera = workspace.CurrentCamera

local function getClosestTargetInFov()
	-- Use current mouse position as the FOV circle center
	local mousePos = UserInputService:GetMouseLocation()

	local bestPlayer = nil
	local bestDist   = math.huge

	for _, plr in ipairs(Players:GetPlayers()) do
		if plr == player then continue end
		local char = plr.Character
		if not char then continue end
		local head = char:FindFirstChild("Head")
		local hum  = char:FindFirstChildOfClass("Humanoid")
		if not head or not hum or hum.Health <= 0 then continue end

		local screenPos, onScreen = Camera:WorldToViewportPoint(head.Position)
		if not onScreen then continue end

		local screenVec = Vector2.new(screenPos.X, screenPos.Y)
		local dist2d    = (screenVec - mousePos).Magnitude

		-- Also check world-space distance against the max distance slider
		local char2 = plr.Character
		local hrp2  = char2 and char2:FindFirstChild("HumanoidRootPart")
		local localChar2 = player.Character
		local localHrp2  = localChar2 and localChar2:FindFirstChild("HumanoidRootPart")
		local worldDist = (hrp2 and localHrp2)
			and (hrp2.Position - localHrp2.Position).Magnitude or math.huge

		if dist2d < aimbotFov and dist2d < bestDist and worldDist <= aimbotMaxDist then
			bestDist   = dist2d
			bestPlayer = plr
		end
	end

	return bestPlayer
end

RunService.RenderStepped:Connect(function()
	-- FOV circle always follows the mouse cursor
	if aimbotEnabled then
		local mouse = UserInputService:GetMouseLocation()
		fovCircle.Position = UDim2.new(0, mouse.X, 0, mouse.Y)
	end

	-- Aimbot: only fires while RMB held
	if not aimbotEnabled then return end
	if not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then return end

	local target = getClosestTargetInFov()
	if not target then return end

	local char = target.Character
	if not char then return end
	local head = char:FindFirstChild("Head")
	if not head then return end

	local screenPos, onScreen = Camera:WorldToViewportPoint(head.Position)
	if not onScreen then return end

	-- Pull mouse straight to target. lerpAlpha close to 1 = near instant snap.
	local current   = UserInputService:GetMouseLocation()
	local goal      = Vector2.new(screenPos.X, screenPos.Y)
	-- Map smooth slider: 0 -> alpha 1.0 (instant), 1 -> alpha 0.1 (slow)
	local lerpAlpha = 1 - (math.clamp(aimbotSmooth, 0, 0.9) * 0.9)
	local delta     = (goal - current) * lerpAlpha

	mousemoverel(delta.X, delta.Y)
end)

-- ── ESP PANEL ────────────────────────────────────────────
local espPanel = Instance.new("Frame")
espPanel.Size = UDim2.new(1, 0, 1, -72)
espPanel.Position = UDim2.new(0, 0, 0, 72)
espPanel.BackgroundTransparency = 1
espPanel.ClipsDescendants = true
espPanel.ZIndex = 6
espPanel.Visible = false
espPanel.Parent = bgBox

local espScroll = Instance.new("ScrollingFrame")
espScroll.Size = UDim2.new(1, 0, 1, 0)
espScroll.Position = UDim2.new(0, 0, 0, 0)
espScroll.BackgroundTransparency = 1
espScroll.BorderSizePixel = 0
espScroll.ScrollBarThickness = 4
espScroll.ScrollBarImageColor3 = Color3.fromRGB(80, 80, 80)
espScroll.CanvasSize = UDim2.new(0, 0, 0, 480)
espScroll.ZIndex = 6
espScroll.Parent = espPanel

-- Toggle helper (original Con Ex; shared with the Combat tab)
local function makeToggle(parent, yPos, labelText, defaultState, callback)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -40, 0, 32)
	row.Position = UDim2.new(0, 20, 0, yPos)
	row.BackgroundTransparency = 1
	row.ZIndex = 7
	row.Parent = parent

	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(1, -56, 1, 0)
	lbl.BackgroundTransparency = 1
	lbl.Text = labelText
	lbl.TextColor3 = Color3.fromRGB(200, 200, 200)
	lbl.Font = Enum.Font.Gotham
	lbl.TextSize = 13
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.ZIndex = 7
	lbl.Parent = row

	local tBg = Instance.new("Frame")
	tBg.Size = UDim2.new(0, 44, 0, 22)
	tBg.Position = UDim2.new(1, -44, 0.5, -11)
	tBg.BackgroundColor3 = defaultState and Color3.fromRGB(80, 200, 80) or Color3.fromRGB(60, 60, 60)
	tBg.BorderSizePixel = 0
	tBg.ZIndex = 8
	tBg.Parent = row
	Instance.new("UICorner", tBg).CornerRadius = UDim.new(1, 0)

	local tKnob = Instance.new("Frame")
	tKnob.Size = UDim2.new(0, 16, 0, 16)
	tKnob.Position = defaultState and UDim2.new(1, -19, 0.5, -8) or UDim2.new(0, 3, 0.5, -8)
	tKnob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	tKnob.BorderSizePixel = 0
	tKnob.ZIndex = 9
	tKnob.Parent = tBg
	Instance.new("UICorner", tKnob).CornerRadius = UDim.new(1, 0)

	local state = defaultState
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, 0, 1, 0)
	btn.BackgroundTransparency = 1
	btn.Text = ""
	btn.ZIndex = 10
	btn.Parent = row

	btn.MouseButton1Click:Connect(function()
		state = not state
		TweenService:Create(tBg,   TweenInfo.new(0.15), { BackgroundColor3 = state and Color3.fromRGB(80,200,80) or Color3.fromRGB(60,60,60) }):Play()
		TweenService:Create(tKnob, TweenInfo.new(0.15), { Position = state and UDim2.new(1,-19,0.5,-8) or UDim2.new(0,3,0.5,-8) }):Play()
		callback(state)
	end)
end

local function makeSection(parent, yPos, text)
	local sep = Instance.new("TextLabel")
	sep.Size = UDim2.new(1, -40, 0, 18)
	sep.Position = UDim2.new(0, 20, 0, yPos)
	sep.BackgroundTransparency = 1
	sep.Text = text
	sep.TextColor3 = Color3.fromRGB(100, 100, 100)
	sep.Font = Enum.Font.GothamBold
	sep.TextSize = 11
	sep.TextXAlignment = Enum.TextXAlignment.Left
	sep.ZIndex = 7
	sep.Parent = parent
end

-- ESP master toggle button
local espToggleBtn = Instance.new("TextButton")
espToggleBtn.Size = UDim2.new(1, -40, 0, 40)
espToggleBtn.Position = UDim2.new(0, 20, 0, 10)
espToggleBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
espToggleBtn.BorderSizePixel = 0
espToggleBtn.Text = "ESP  OFF"
espToggleBtn.TextColor3 = Color3.fromRGB(160, 160, 160)
espToggleBtn.Font = Enum.Font.GothamBold
espToggleBtn.TextSize = 14
espToggleBtn.ZIndex = 7
espToggleBtn.Parent = espScroll
Instance.new("UICorner", espToggleBtn).CornerRadius = UDim.new(0, 8)

local espToggleStroke = Instance.new("UIStroke")
espToggleStroke.Color = Color3.fromRGB(70, 70, 70)
espToggleStroke.Thickness = 1
espToggleStroke.Parent = espToggleBtn

makeSection(espScroll, 62, "DISPLAY OPTIONS")
makeToggle(espScroll, 82,  "Show Names",    showNames,    function(v) showNames    = v end)
makeToggle(espScroll, 120, "Show Health",   showHealth,   function(v) showHealth   = v end)
makeToggle(espScroll, 158, "Show Distance", showDistance, function(v) showDistance = v end)
makeToggle(espScroll, 196, "Highlight",     showBox,      function(v)
	showBox = v
	for _, data in pairs(espObjects) do
		if data.highlight and data.highlight.Parent then
			data.highlight.Enabled = showBox and espEnabled
		end
	end
end)
makeToggle(espScroll, 234, "Box ESP",       showBoxESP,   function(v)
	showBoxESP = v
	for _, data in pairs(espObjects) do
		if data.selectionBox and data.selectionBox.Parent then
			data.selectionBox.Visible = showBoxESP and espEnabled
		end
	end
end)

makeSection(espScroll, 316, "ESP RANGE")

local espDistLabel = Instance.new("TextLabel")
espDistLabel.Size = UDim2.new(1, -40, 0, 14)
espDistLabel.Position = UDim2.new(0, 20, 0, 338)
espDistLabel.BackgroundTransparency = 1
espDistLabel.Text = "MAX DIST  ( " .. espMaxDist .. " studs )"
espDistLabel.TextColor3 = Color3.fromRGB(100, 100, 100)
espDistLabel.Font = Enum.Font.GothamBold
espDistLabel.TextSize = 11
espDistLabel.TextXAlignment = Enum.TextXAlignment.Left
espDistLabel.ZIndex = 7
espDistLabel.Parent = espScroll

local espDistTrack = Instance.new("Frame")
espDistTrack.Size = UDim2.new(0, 260, 0, 14)
espDistTrack.Position = UDim2.new(0.5, -130, 0, 356)
espDistTrack.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
espDistTrack.BorderSizePixel = 0
espDistTrack.ZIndex = 7
espDistTrack.Parent = espScroll
Instance.new("UICorner", espDistTrack).CornerRadius = UDim.new(1, 0)

local espDistFill = Instance.new("Frame")
espDistFill.Size = UDim2.new((espMaxDist - 10) / 990, 0, 1, 0)
espDistFill.BackgroundColor3 = Color3.fromRGB(80, 200, 80)
espDistFill.BorderSizePixel = 0
espDistFill.ZIndex = 8
espDistFill.Parent = espDistTrack
Instance.new("UICorner", espDistFill).CornerRadius = UDim.new(1, 0)

local espDistKnob = Instance.new("Frame")
espDistKnob.Size = UDim2.new(0, 20, 0, 20)
espDistKnob.Position = UDim2.new((espMaxDist - 10) / 990, -10, 0.5, -10)
espDistKnob.BackgroundColor3 = Color3.fromRGB(100, 220, 100)
espDistKnob.BorderSizePixel = 0
espDistKnob.ZIndex = 9
espDistKnob.Parent = espDistTrack
Instance.new("UICorner", espDistKnob).CornerRadius = UDim.new(1, 0)
local espDistKnobStroke = Instance.new("UIStroke")
espDistKnobStroke.Color = Color3.fromRGB(255,255,255)
espDistKnobStroke.Thickness = 2
espDistKnobStroke.Transparency = 0.5
espDistKnobStroke.Parent = espDistKnob

makeSection(espScroll, 382, "INFO")

local infoLabel = Instance.new("TextLabel")
infoLabel.Size = UDim2.new(1, -40, 0, 36)
infoLabel.Position = UDim2.new(0, 20, 0, 398)
infoLabel.BackgroundTransparency = 1
infoLabel.Text = "ESP color synced to Client tab slider.\nBox = colored model outline through walls."
infoLabel.TextColor3 = Color3.fromRGB(90, 90, 90)
infoLabel.Font = Enum.Font.Gotham
infoLabel.TextSize = 11
infoLabel.TextXAlignment = Enum.TextXAlignment.Left
infoLabel.TextWrapped = true
infoLabel.ZIndex = 7
infoLabel.Parent = espScroll

local playerCountLabel = Instance.new("TextLabel")
playerCountLabel.Size = UDim2.new(1, -40, 0, 20)
playerCountLabel.Position = UDim2.new(0, 20, 0, 440)
playerCountLabel.BackgroundTransparency = 1
playerCountLabel.Text = "Players tracked: 0"
playerCountLabel.TextColor3 = Color3.fromRGB(90, 90, 90)
playerCountLabel.Font = Enum.Font.Code
playerCountLabel.TextSize = 11
playerCountLabel.TextXAlignment = Enum.TextXAlignment.Left
playerCountLabel.ZIndex = 7
playerCountLabel.Parent = espScroll

-- ── COMBAT PANEL (new tab) ───────────────────────────────
local combatPanel = Instance.new("Frame")
combatPanel.Size = UDim2.new(1, 0, 1, -72)
combatPanel.Position = UDim2.new(0, 0, 0, 72)
combatPanel.BackgroundTransparency = 1
combatPanel.ClipsDescendants = true
combatPanel.ZIndex = 6
combatPanel.Visible = false
combatPanel.Parent = bgBox

local combatScroll = Instance.new("ScrollingFrame")
combatScroll.Size = UDim2.new(1, 0, 1, 0)
combatScroll.Position = UDim2.new(0, 0, 0, 0)
combatScroll.BackgroundTransparency = 1
combatScroll.BorderSizePixel = 0
combatScroll.ScrollBarThickness = 4
combatScroll.ScrollBarImageColor3 = Color3.fromRGB(80, 80, 80)
combatScroll.CanvasSize = UDim2.new(0, 0, 0, 560)
combatScroll.ZIndex = 6
combatScroll.Parent = combatPanel

-- engines get assigned further below; the buttons only touch them on click
local Backstab, Speed

-- ── COMBAT STATE ─────────────────────────────────────────
local capturingKey = false
local tbot = {
	enabled    = false,
	mode       = "Hold",        -- Always | Hold | Toggle  (Kicia keybind kinds)
	key        = Enum.KeyCode.T,
	armed      = false,         -- Toggle mode
	holdActive = false,         -- Hold mode
	reaction   = 0,             -- seconds (Kicia default: ReactionTime = 0)
	release    = 0,             -- seconds (Kicia default: ReleaseTime  = 0)
	teamCheck  = true,
	reactionElapsed  = nil,
	releaseRemaining = 0,
	pressing   = false,
}
local backstabState = { enabled = false }
local speedState    = { enabled = false, multiplier = 1.5 }

-- Con Ex-style value slider (label + track + fill + knob, self-managed drag)
local function makeValueSlider(parent, yPos, minV, maxV, default, decimals, formatFn, onChange)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -40, 0, 14)
	label.Position = UDim2.new(0, 20, 0, yPos)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(100, 100, 100)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 11
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.ZIndex = 7
	label.Parent = parent

	local track = Instance.new("Frame")
	track.Size = UDim2.new(0, 260, 0, 14)
	track.Position = UDim2.new(0.5, -130, 0, yPos + 16)
	track.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
	track.BorderSizePixel = 0
	track.ZIndex = 7
	track.Parent = parent
	Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)

	local fill = Instance.new("Frame")
	fill.Size = UDim2.new((default - minV) / (maxV - minV), 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
	fill.BorderSizePixel = 0
	fill.ZIndex = 8
	fill.Parent = track
	Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

	local knob = Instance.new("Frame")
	knob.Size = UDim2.new(0, 20, 0, 20)
	knob.Position = UDim2.new((default - minV) / (maxV - minV), -10, 0.5, -10)
	knob.BackgroundColor3 = Color3.fromRGB(220, 80, 80)
	knob.BorderSizePixel = 0
	knob.ZIndex = 9
	knob.Parent = track
	Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)
	local knobStroke = Instance.new("UIStroke")
	knobStroke.Color = Color3.fromRGB(255, 255, 255)
	knobStroke.Thickness = 2
	knobStroke.Transparency = 0.5
	knobStroke.Parent = knob

	local dragging = false
	local function setFromT(t)
		t = math.clamp(t, 0, 1)
		local v = minV + (maxV - minV) * t
		if decimals then v = math.floor(v * 10 ^ decimals + 0.5) / 10 ^ decimals end
		knob.Position = UDim2.new(t, -10, 0.5, -10)
		fill.Size = UDim2.new(t, 0, 1, 0)
		label.Text = formatFn(v)
		onChange(v)
	end
	local function trackT(x)
		return math.clamp((x - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
	end
	knob.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or
		   input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
		end
	end)
	track.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or
		   input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			setFromT(trackT(input.Position.X))
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or
		                 input.UserInputType == Enum.UserInputType.Touch) then
			setFromT(trackT(input.Position.X))
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or
		   input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	setFromT((default - minV) / (maxV - minV))
end

makeSection(combatScroll, 8, "TRIGGERBOT")

local tbotBtn = Instance.new("TextButton")
tbotBtn.Size = UDim2.new(1, -40, 0, 40)
tbotBtn.Position = UDim2.new(0, 20, 0, 28)
tbotBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
tbotBtn.BorderSizePixel = 0
tbotBtn.Text = "TBOT  OFF"
tbotBtn.TextColor3 = Color3.fromRGB(160, 160, 160)
tbotBtn.Font = Enum.Font.GothamBold
tbotBtn.TextSize = 14
tbotBtn.ZIndex = 7
tbotBtn.Parent = combatScroll
Instance.new("UICorner", tbotBtn).CornerRadius = UDim.new(0, 8)

local tbotStroke = Instance.new("UIStroke")
tbotStroke.Color = Color3.fromRGB(70, 70, 70)
tbotStroke.Thickness = 1
tbotStroke.Parent = tbotBtn

local modeAlways = Instance.new("TextButton")
modeAlways.Size = UDim2.new(0, 82, 0, 26)
modeAlways.Position = UDim2.new(0, 20, 0, 76)
modeAlways.BackgroundColor3 = Color3.fromRGB(22, 22, 22)
modeAlways.BorderSizePixel = 0
modeAlways.Text = "ALWAYS"
modeAlways.TextColor3 = Color3.fromRGB(120, 120, 120)
modeAlways.Font = Enum.Font.GothamBold
modeAlways.TextSize = 11
modeAlways.ZIndex = 7
modeAlways.Parent = combatScroll
Instance.new("UICorner", modeAlways).CornerRadius = UDim.new(0, 6)

local modeHold = modeAlways:Clone()
modeHold.Position = UDim2.new(0, 109, 0, 76)
modeHold.Text = "HOLD"
modeHold.Parent = combatScroll

local modeToggle = modeAlways:Clone()
modeToggle.Position = UDim2.new(0, 198, 0, 76)
modeToggle.Text = "TOGGLE"
modeToggle.Parent = combatScroll

local keyBtn = Instance.new("TextButton")
keyBtn.Size = UDim2.new(1, -40, 0, 30)
keyBtn.Position = UDim2.new(0, 20, 0, 110)
keyBtn.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
keyBtn.BorderSizePixel = 0
keyBtn.Text = "TRIGGER KEY  [ T ]"
keyBtn.TextColor3 = Color3.fromRGB(160, 160, 160)
keyBtn.Font = Enum.Font.GothamBold
keyBtn.TextSize = 13
keyBtn.ZIndex = 7
keyBtn.Parent = combatScroll
Instance.new("UICorner", keyBtn).CornerRadius = UDim.new(0, 8)

local keyStroke = Instance.new("UIStroke")
keyStroke.Color = Color3.fromRGB(70, 70, 70)
keyStroke.Thickness = 1
keyStroke.Parent = keyBtn

local updateKeyBtn -- forward declaration
local modeButtons = { Always = modeAlways, Hold = modeHold, Toggle = modeToggle }

local function refreshModeButtons()
	for name, btn in pairs(modeButtons) do
		local active = (tbot.mode == name)
		btn.BackgroundColor3 = active and Color3.fromRGB(35, 35, 35) or Color3.fromRGB(22, 22, 22)
		btn.TextColor3       = active and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(120, 120, 120)
	end
end

local function setMode(mode)
	tbot.mode = mode
	tbot.armed = false
	tbot.holdActive = false
	refreshModeButtons()
	updateKeyBtn()
end

modeAlways.MouseButton1Click:Connect(function() setMode("Always") end)
modeHold.MouseButton1Click:Connect(function()   setMode("Hold")   end)
modeToggle.MouseButton1Click:Connect(function() setMode("Toggle") end)

updateKeyBtn = function()
	if capturingKey then
		keyBtn.Text = "PRESS A KEY...  (ESC = CANCEL)"
		keyBtn.TextColor3 = Color3.fromRGB(255, 220, 80)
	elseif tbot.mode == "Toggle" and tbot.armed then
		keyBtn.Text = "TRIGGER KEY  [ " .. tbot.key.Name .. " ]  ARMED"
		keyBtn.TextColor3 = Color3.fromRGB(120, 255, 120)
	else
		keyBtn.Text = "TRIGGER KEY  [ " .. tbot.key.Name .. " ]"
		keyBtn.TextColor3 = Color3.fromRGB(160, 160, 160)
	end
end

keyBtn.MouseButton1Click:Connect(function()
	if capturingKey then return end
	capturingKey = true
	updateKeyBtn()
end)

makeSection(combatScroll, 148, "TIMING")
makeValueSlider(combatScroll, 166, 0, 400, 0, 0,
	function(v) return string.format("REACTION  ( %d ms )", v) end,
	function(v) tbot.reaction = v / 1000 end)
makeValueSlider(combatScroll, 206, 0, 500, 0, 0,
	function(v) return string.format("RELEASE  ( %d ms )", v) end,
	function(v) tbot.release = v / 1000 end)

makeToggle(combatScroll, 246, "Team Check (skip teammates)", true, function(v)
	tbot.teamCheck = v
end)

local tbotInfo = Instance.new("TextLabel")
tbotInfo.Size = UDim2.new(1, -40, 0, 28)
tbotInfo.Position = UDim2.new(0, 20, 0, 288)
tbotInfo.BackgroundTransparency = 1
tbotInfo.Text = "Fires while your crosshair rests on an enemy.\nAlways / Hold / Toggle use the key above."
tbotInfo.TextColor3 = Color3.fromRGB(90, 90, 90)
tbotInfo.Font = Enum.Font.Gotham
tbotInfo.TextSize = 11
tbotInfo.TextXAlignment = Enum.TextXAlignment.Left
tbotInfo.TextWrapped = true
tbotInfo.ZIndex = 7
tbotInfo.Parent = combatScroll

makeSection(combatScroll, 326, "ALWAYS BACKSTAB  ( KICIA )")

local bsBtn = Instance.new("TextButton")
bsBtn.Size = UDim2.new(1, -40, 0, 40)
bsBtn.Position = UDim2.new(0, 20, 0, 346)
bsBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
bsBtn.BorderSizePixel = 0
bsBtn.Text = "BACKSTAB  OFF"
bsBtn.TextColor3 = Color3.fromRGB(160, 160, 160)
bsBtn.Font = Enum.Font.GothamBold
bsBtn.TextSize = 14
bsBtn.ZIndex = 7
bsBtn.Parent = combatScroll
Instance.new("UICorner", bsBtn).CornerRadius = UDim.new(0, 8)

local bsStroke = Instance.new("UIStroke")
bsStroke.Color = Color3.fromRGB(70, 70, 70)
bsStroke.Thickness = 1
bsStroke.Parent = bsBtn

local bsInfo = Instance.new("TextLabel")
bsInfo.Size = UDim2.new(1, -40, 0, 42)
bsInfo.Position = UDim2.new(0, 20, 0, 394)
bsInfo.BackgroundTransparency = 1
bsInfo.Text = "Mirrors the nearest enemy's facing (<= 20 studs) into the\ncamera rotation the server receives while you have a Knife.\nPorted from Kicia's ViewAngleDriver."
bsInfo.TextColor3 = Color3.fromRGB(90, 90, 90)
bsInfo.Font = Enum.Font.Gotham
bsInfo.TextSize = 11
bsInfo.TextXAlignment = Enum.TextXAlignment.Left
bsInfo.TextWrapped = true
bsInfo.ZIndex = 7
bsInfo.Parent = combatScroll

makeSection(combatScroll, 444, "SPEED MULTIPLIER  ( KICIA )")

local speedBtn = Instance.new("TextButton")
speedBtn.Size = UDim2.new(1, -40, 0, 40)
speedBtn.Position = UDim2.new(0, 20, 0, 464)
speedBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
speedBtn.BorderSizePixel = 0
speedBtn.Text = "SPEED  OFF"
speedBtn.TextColor3 = Color3.fromRGB(160, 160, 160)
speedBtn.Font = Enum.Font.GothamBold
speedBtn.TextSize = 14
speedBtn.ZIndex = 7
speedBtn.Parent = combatScroll
Instance.new("UICorner", speedBtn).CornerRadius = UDim.new(0, 8)

local speedStroke = Instance.new("UIStroke")
speedStroke.Color = Color3.fromRGB(70, 70, 70)
speedStroke.Thickness = 1
speedStroke.Parent = speedBtn

makeValueSlider(combatScroll, 512, 1, 10, 1.5, 1,
	function(v) return string.format("SPEED  ( %.1fx )", v) end,
	function(v) speedState.multiplier = v end)

refreshModeButtons()
updateKeyBtn()

-- ── TBOT ENGINE (ported from Kicia, kicia.txt 54221-54344) ──
local mouse1press   = execfn("mouse1press")
local mouse1release = execfn("mouse1release")
local virtualUser   = cloneref(game:GetService("VirtualUser"))
local tbotWorkspace = cloneref(game:GetService("Workspace"))

local function tbotPress()
	tbot.pressing = true
	if mouse1press then
		pcall(mouse1press)
	else
		pcall(function()
			virtualUser:CaptureController()
			virtualUser:Button1Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
		end)
	end
end

local function tbotRelease()
	tbot.pressing = false
	if mouse1release then
		pcall(mouse1release)
	else
		pcall(function()
			virtualUser:Button1Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
		end)
	end
end

-- never let a stale press linger when the panel is interacted with
bgBox.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 and tbot.pressing then
		tbotRelease()
	end
end)

local function mouseOverPanel()
	if not guiVisible then return false end
	local m = UserInputService:GetMouseLocation()
	local ap, as = bgBox.AbsolutePosition, bgBox.AbsoluteSize
	return m.X >= ap.X and m.X <= ap.X + as.X and m.Y >= ap.Y and m.Y <= ap.Y + as.Y
end

-- crosshair check (Kicia _CheckCrosshair 54270-54305, simplified: any hit
-- on an alive enemy character model; Kicia additionally filters per-hitbox
-- Air/Ground tables and shield/deflect state through its fighter context)
local function enemyUnderCrosshair()
	local cam = tbotWorkspace.CurrentCamera
	if not cam then return false end
	local m = UserInputService:GetMouseLocation()
	local ok, ray = pcall(function() return cam:ViewportPointToRay(m.X, m.Y) end)
	if not ok or not ray then return false end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	if player.Character then
		params.FilterDescendantsInstances = { player.Character }
	end
	local hit = tbotWorkspace:Raycast(ray.Origin, ray.Direction * 2000, params)
	if not hit then return false end
	local model = hit.Instance and hit.Instance:FindFirstAncestorOfClass("Model")
	if not model then return false end
	local plr = Players:GetPlayerFromCharacter(model)
	if not plr or plr == player then return false end
	if tbot.teamCheck and plr.Team ~= nil and plr.Team == player.Team then return false end
	local hum = model:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.Health > 0
end

RunService.RenderStepped:Connect(function(dt)
	local active = false
	if tbot.enabled and not capturingKey then
		if tbot.mode == "Always" then
			active = true
		elseif tbot.mode == "Hold" then
			active = tbot.holdActive
		elseif tbot.mode == "Toggle" then
			active = tbot.armed
		end
	end
	if active and mouseOverPanel() then active = false end

	if not active then
		if tbot.pressing then tbotRelease() end
		tbot.reactionElapsed = nil
		tbot.releaseRemaining = 0
		return
	end

	local overEnemy = enemyUnderCrosshair()

	if overEnemy then
		if tbot.reactionElapsed == nil then
			tbot.reactionElapsed = 0
		else
			tbot.reactionElapsed += dt
		end
	else
		tbot.reactionElapsed = nil
	end

	local shouldHold = false
	if overEnemy and tbot.reactionElapsed ~= nil and tbot.reactionElapsed >= tbot.reaction then
		tbot.releaseRemaining = tbot.release
		shouldHold = true
	else
		tbot.releaseRemaining = math.max(0, tbot.releaseRemaining - dt)
		if tbot.releaseRemaining > 0 then shouldHold = true end
	end

	if shouldHold and not tbot.pressing then tbotPress() end
	if not shouldHold and tbot.pressing then tbotRelease() end
end)

-- trigger key + capture (Escape cancels even when gameProcessed, v2.3 lesson)
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if capturingKey then
		if input.UserInputType == Enum.UserInputType.Keyboard then
			if input.KeyCode ~= Enum.KeyCode.Escape then
				tbot.holdActive = false
				tbot.armed = false
				tbot.key = input.KeyCode
			end
			capturingKey = false
			updateKeyBtn()
		end
		return
	end
	if gameProcessed then return end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	if input.KeyCode ~= tbot.key then return end
	if tbot.mode == "Hold" then
		tbot.holdActive = true
	elseif tbot.mode == "Toggle" then
		tbot.armed = not tbot.armed
		updateKeyBtn()
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.Keyboard
	   and input.KeyCode == tbot.key
	   and tbot.mode == "Hold" then
		tbot.holdActive = false
	end
end)

tbotBtn.MouseButton1Click:Connect(function()
	tbot.enabled = not tbot.enabled
	if tbot.enabled then
		tbotBtn.Text = "TBOT  ON"
		tbotBtn.TextColor3 = Color3.fromRGB(120, 255, 120)
		TweenService:Create(tbotBtn,    TweenInfo.new(0.15), { BackgroundColor3 = Color3.fromRGB(20, 45, 20) }):Play()
		TweenService:Create(tbotStroke, TweenInfo.new(0.15), { Color = Color3.fromRGB(80, 220, 80) }):Play()
	else
		tbotBtn.Text = "TBOT  OFF"
		tbotBtn.TextColor3 = Color3.fromRGB(160, 160, 160)
		TweenService:Create(tbotBtn,    TweenInfo.new(0.15), { BackgroundColor3 = Color3.fromRGB(35, 35, 35) }):Play()
		TweenService:Create(tbotStroke, TweenInfo.new(0.15), { Color = Color3.fromRGB(70, 70, 70) }):Play()
		if tbot.pressing then tbotRelease() end
		tbot.armed = false
		tbot.holdActive = false
		updateKeyBtn()
	end
end)

-- ── ALWAYS BACKSTAB ENGINE ───────────────────────────────
-- Ported from Kicia: ViewAngleDriver (kicia.txt 26187-26524) +
-- always_backstab feature module (kicia.txt 29702-29777).
Backstab = (function()
	local rawget_, rawset_ = rawget, rawset
	local clonefunction = execfn("clonefunction")
	local function clonefn(f)
		if clonefunction and f then
			local ok, r = pcall(clonefunction, f)
			if ok and r then return r end
		end
		return f
	end
	-- Kicia fires the spoof through a cloned FireServer (373-382 pattern)
	local fireServer2 = clonefn(Instance.new("UnreliableRemoteEvent").FireServer)

	-- rotation codec (Kicia module cH, kicia.txt 26226-26258)
	local encodeLib = {}
	encodeLib.encodeCameraRotation = function(v)
		if v ~= v then return utf8.char(0) .. utf8.char(0) end
		local a = math.clamp(math.floor(v.X % math.tau / math.pi / 2 * 256 + 0.5), 0, 255)
		local b = math.clamp(math.floor(v.Y % math.tau / math.pi / 2 * 256 + 0.5), 0, 255)
		return utf8.char(a) .. utf8.char(b)
	end
	encodeLib.encodeSingle = function(a)
		if a ~= a then return utf8.char(0) end
		return utf8.char(math.clamp(math.floor(a % math.tau / math.pi / 2 * 256 + 0.5), 0, 255))
	end
	encodeLib.decodeSingle = function(s)
		return utf8.codepoint(s) * math.pi * 2 / 256
	end
	encodeLib.fromXYToCameraRotation = function(x, y)
		return Vector2.new(x, y) * math.pi * 2 / 256
	end

	-- payload -> wire string (Kicia fn36, 26289-26294)
	local function encodeRotation(p)
		if p.Kind == "Unnormalized" then
			return utf8.char(math.clamp(p.Pitch, 0, 255)) .. utf8.char(math.clamp(p.Yaw, 0, 255))
		end
		return encodeLib.encodeSingle(math.rad(p.Pitch)) .. encodeLib.encodeSingle(math.rad(p.Yaw))
	end

	-- payload -> CameraRotationRaw radians (Kicia fn37, 26296-26303)
	local function rotationRaw(p)
		if p.Kind == "Unnormalized" then
			return encodeLib.fromXYToCameraRotation(p.Pitch, p.Yaw)
		end
		return Vector2.new(
			encodeLib.decodeSingle(encodeLib.encodeSingle(math.rad(p.Pitch))),
			encodeLib.decodeSingle(encodeLib.encodeSingle(math.rad(p.Yaw)))
		)
	end

	-- real camera rotation (X = pitch, Y = yaw; codec encodes X first)
	local function currentCameraRotation()
		local cam = workspace.CurrentCamera
		local look = (cam and cam.CFrame.LookVector) or Vector3.zAxis
		local pitch = math.asin(math.clamp(look.Y, -1, 1))
		local yaw = math.atan2(-look.X, -look.Z)
		return Vector2.new(pitch, yaw)
	end

	local function waitForChain(root, names)
		local cur = root
		for _, n in ipairs(names) do
			if not cur then return nil end
			local ok, child = pcall(function() return cur:WaitForChild(n, 30) end)
			if not ok or not child then return nil end
			cur = child
		end
		return cur
	end

	local state = {
		loaded = false,
		loading = false,
		payloadBySlot = {},
		winning = nil,
		dirty = false,
		jointsRestore = nil,
		replicationRestore = nil,
		restoreTask = nil,
		jointsModule = nil,        -- ClientReplicatedClasses.ClientFighter.ClientFighterCharacter.Joints
		fighterController = nil,   -- PlayerScripts.Controllers.FighterController
		updateCamRemote = nil,     -- Remotes.Replication.Fighter.UpdateCameraRotation
	}

	local function findInstances()
		if state.jointsModule and state.fighterController and state.updateCamRemote then return end
		-- Kicia loader discovery paths (kicia.txt 19000-19051)
		state.jointsModule = waitForChain(player,
			{ "PlayerScripts", "Modules", "ClientReplicatedClasses", "ClientFighter", "ClientFighterCharacter", "Joints" })
		state.fighterController = waitForChain(player,
			{ "PlayerScripts", "Controllers", "FighterController" })
		local rs = cloneref(game:GetService("ReplicatedStorage"))
		state.updateCamRemote = waitForChain(rs,
			{ "Remotes", "Replication", "Fighter", "UpdateCameraRotation" })
		state.loaded = (state.jointsModule ~= nil and state.fighterController ~= nil and state.updateCamRemote ~= nil)
		if state.loaded then
			warn("[ConEx] Backstab engine loaded")
		else
			warn("[ConEx] Backstab: Rivals modules not found (game update?)")
		end
	end

	-- layer 1 (Kicia _LoadJointsHook 26316-26345): rawset Joints.Update so the
	-- local fighter's update params carry our spoofed CameraRotationRaw
	local function loadJointsHook()
		if state.jointsRestore ~= nil then return true end
		local update = rawget_(state.jointsModule, "Update")
		if type(update) ~= "function" then return false end
		rawset_(state.jointsModule, "Update", function(self, a, b)
			local cfc = rawget_(self, "ClientFighterCharacter")
			local cf = cfc and rawget_(cfc, "ClientFighter")
			if cf == nil then
				return update(self, a, b)
			end
			if rawget_(cf, "IsLocalPlayer") == true then
				local winning = state.winning
				if winning ~= nil and type(b) == "table" then
					rawset_(b, "CameraRotationRaw", rotationRaw(winning))
				end
			end
			return update(self, a, b)
		end)
		state.jointsRestore = update
		return true
	end

	-- layer 2 (Kicia _LoadReplicationHook 26347-26408): swap the
	-- EncodeCameraRotation utility upvalue inside _CameraReplicationLoop so
	-- the game's own camera replication replays the last encoded rotation
	-- while a spoof payload is active
	local function loadReplicationHook()
		if state.replicationRestore ~= nil then return true end
		if type(debug) ~= "table" or type(debug.getupvalues) ~= "function" then return false end
		local fc = state.fighterController
		local mt = getmetatable(fc)
		if type(mt) ~= "table" then return false end
		local proto = rawget_(mt, "__index")
		if type(proto) ~= "table" then return false end
		local loop = rawget_(proto, "_CameraReplicationLoop")
		if type(loop) ~= "function" then return false end
		local idx, util
		for k, v in debug.getupvalues(loop) do
			if type(v) == "table" then
				local vmt = getmetatable(v)
				if type(vmt) == "table" then
					local vidx = rawget_(vmt, "__index")
					if type(vidx) == "table" and type(rawget_(vidx, "EncodeCameraRotation")) == "function" then
						idx, util = k, v
						break
					end
				end
			end
		end
		if idx == nil then return false end
		debug.setupvalue(loop, idx, { EncodeCameraRotation = function(_, rot)
			if next(state.payloadBySlot) ~= nil then
				rawset_(fc, "_replication_stopped", false)
				return rawget_(fc, "_last_encoded_camera_rotation")
					or encodeLib.encodeCameraRotation(rot)
			end
			return encodeLib.encodeCameraRotation(rot)
		end })
		state.replicationRestore = { loop = loop, idx = idx, util = util }
		return true
	end

	local function cancelRestore()
		if state.restoreTask ~= nil then
			pcall(task.cancel, state.restoreTask)
			state.restoreTask = nil
		end
	end

	-- Kicia SendViewAngles 26433-26449 (slot table + winning resolve)
	local function sendViewAngles(slot, payload)
		if state.payloadBySlot[slot] == payload then return end
		state.payloadBySlot[slot] = payload
		local best, bestKey = -math.huge, nil
		for k, v in pairs(state.payloadBySlot) do
			if k > best then best, bestKey = k, v end
		end
		state.winning = bestKey
		state.dirty = true
		cancelRestore()
		if state.winning ~= nil then
			loadJointsHook()
			loadReplicationHook()
		end
	end

	-- Kicia Flush 26474-26499: spoof goes out through the cloned FireServer;
	-- cancel restores the real angle after 0.05s + ping
	local function flush()
		if not state.dirty then return end
		local winning = state.winning
		if winning == nil then
			state.dirty = false
			cancelRestore()
			if state.updateCamRemote then
				state.restoreTask = task.delay(0.05 + player:GetNetworkPing(), function()
					if state.winning ~= nil then return end
					pcall(fireServer2, state.updateCamRemote,
						encodeLib.encodeCameraRotation(currentCameraRotation()), nil)
				end)
			end
			return
		end
		state.dirty = false
		if state.updateCamRemote then
			pcall(fireServer2, state.updateCamRemote, encodeRotation(winning), nil)
		end
	end

	-- always_backstab Update (Kicia 29728-29749 + _FindClosestEnemy 29751-29770)
	local function update()
		if not backstabState.enabled or not state.loaded then return end
		local char = player.Character
		-- knife gate (Kicia: ItemBehaviors:FindMeleeByName("Knife"), 29734)
		local hasKnife = false
		if char and char:FindFirstChild("Knife") then
			hasKnife = true
		else
			local backpack = player:FindFirstChildOfClass("Backpack")
			if backpack and backpack:FindFirstChild("Knife") then hasKnife = true end
		end
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not hasKnife or not root then
			sendViewAngles(10, nil)
			flush()
			return
		end
		-- Kicia: CharacterController:GetServerHeadOrigin; approximated with
		-- Kicia's own standing server offset (cG 26195: root + 1.75)
		local headPos = root.Position + Vector3.new(0, 1.75, 0)
		local closest, closestDist = nil, 20
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= player and not (plr.Team ~= nil and plr.Team == player.Team) then
				local c2 = plr.Character
				local r2 = c2 and c2:FindFirstChild("HumanoidRootPart")
				local h2 = c2 and c2:FindFirstChildOfClass("Humanoid")
				if r2 and h2 and h2.Health > 0 then
					local d = (r2.Position - headPos).Magnitude
					if d < closestDist then
						closestDist, closest = d, r2
					end
				end
			end
		end
		if closest == nil then
			sendViewAngles(10, nil)
		else
			-- mirror the victim's root orientation (Kicia 29747-29748)
			local pitch, yaw = closest.CFrame:ToOrientation()
			sendViewAngles(10, { Kind = "Normalized", Pitch = math.deg(pitch), Yaw = math.deg(yaw) })
		end
		flush()
	end

	local function enable()
		if not state.loaded and not state.loading then
			state.loading = true
			task.spawn(function()
				findInstances()
				state.loading = false
			end)
		end
	end

	local function disable()
		if state.loaded then
			sendViewAngles(10, nil)
			flush()
		end
	end

	return { update = update, enable = enable, disable = disable }
end)()

RunService.Heartbeat:Connect(function()
	Backstab.update()
end)

-- ── SPEED MULTIPLIER ENGINE ──────────────────────────────
-- Ported from Kicia's movement.WalkSpeed module (kicia.txt 55575-55697).
Speed = (function()
	local state = {
		hookLoaded = false,
		hookTried = false,
		fallbackConn = nil,
		baseByHumanoid = setmetatable({}, { __mode = "k" }),
	}

	-- Kicia's hook: MechanicsController.__index._GetWalkSpeed -> scan its
	-- upvalues for the BASE_WALKSPEED table -> swap in a multiplying proxy
	local function attemptHook()
		if state.hookLoaded or state.hookTried then return end
		state.hookTried = true
		task.spawn(function()
			pcall(function()
				local ps = player:WaitForChild("PlayerScripts", 30)
				local controllers = ps and ps:WaitForChild("Controllers", 30)
				local mc = controllers and controllers:WaitForChild("MechanicsController", 30)
				if type(mc) ~= "Instance" then return end
				local mt = getmetatable(mc)
				if type(mt) ~= "table" then return end
				local proto = rawget(mt, "__index")
				if type(proto) ~= "table" then return end
				local getWS = rawget(proto, "_GetWalkSpeed")
				if type(getWS) ~= "function" then return end
				if type(debug) ~= "table" or type(debug.getupvalues) ~= "function" then return end
				local idx
				for k, v in debug.getupvalues(getWS) do
					if type(v) == "table" and rawget(v, "BASE_WALKSPEED") ~= nil then
						idx = k
						break
					end
				end
				if idx == nil then return end
				local old = debug.getupvalue(getWS, idx)
				debug.setupvalue(getWS, idx, setmetatable({}, {
					__index = function(_, key)
						if key == "BASE_WALKSPEED" then
							local base = rawget(old, "BASE_WALKSPEED")
							if speedState.enabled then
								return base * speedState.multiplier
							end
							return base
						end
						-- Kicia kicks here ("Unexpected behavior (client physics
						-- 1)", 55660); we serve the real value instead so a game
						-- update can't brick the session.
						return rawget(old, key)
					end,
				}))
				state.hookLoaded = true
				-- hook took over; retire the fallback
				if state.fallbackConn then
					state.fallbackConn:Disconnect()
					state.fallbackConn = nil
				end
				warn("[ConEx] WalkSpeed hook loaded (BASE_WALKSPEED proxy)")
			end)
			if not state.hookLoaded then
				warn("[ConEx] WalkSpeed hook unavailable - using Humanoid fallback")
			end
		end)
	end

	-- fallback (ours): enforce humanoid walk speed each heartbeat
	local function enableFallback()
		if state.fallbackConn then return end
		state.fallbackConn = RunService.Heartbeat:Connect(function()
			if not speedState.enabled then return end
			local char = player.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if not hum or hum.Health <= 0 then return end
			if state.baseByHumanoid[hum] == nil then
				state.baseByHumanoid[hum] = hum.WalkSpeed
			end
			hum.WalkSpeed = state.baseByHumanoid[hum] * speedState.multiplier
		end)
	end

	local function enable()
		attemptHook()
		enableFallback()
	end

	local function disable()
		if state.fallbackConn then
			local char = player.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if hum and state.baseByHumanoid[hum] then
				hum.WalkSpeed = state.baseByHumanoid[hum]
			end
		end
	end

	return { enable = enable, disable = disable }
end)()

-- ── COMBAT BUTTON WIRING ─────────────────────────────────
bsBtn.MouseButton1Click:Connect(function()
	backstabState.enabled = not backstabState.enabled
	if backstabState.enabled then
		bsBtn.Text = "BACKSTAB  ON"
		bsBtn.TextColor3 = Color3.fromRGB(120, 255, 120)
		TweenService:Create(bsBtn,    TweenInfo.new(0.15), { BackgroundColor3 = Color3.fromRGB(20, 45, 20) }):Play()
		TweenService:Create(bsStroke, TweenInfo.new(0.15), { Color = Color3.fromRGB(80, 220, 80) }):Play()
		Backstab.enable()
	else
		bsBtn.Text = "BACKSTAB  OFF"
		bsBtn.TextColor3 = Color3.fromRGB(160, 160, 160)
		TweenService:Create(bsBtn,    TweenInfo.new(0.15), { BackgroundColor3 = Color3.fromRGB(35, 35, 35) }):Play()
		TweenService:Create(bsStroke, TweenInfo.new(0.15), { Color = Color3.fromRGB(70, 70, 70) }):Play()
		Backstab.disable()
	end
end)

speedBtn.MouseButton1Click:Connect(function()
	speedState.enabled = not speedState.enabled
	if speedState.enabled then
		speedBtn.Text = "SPEED  ON"
		speedBtn.TextColor3 = Color3.fromRGB(120, 255, 120)
		TweenService:Create(speedBtn,    TweenInfo.new(0.15), { BackgroundColor3 = Color3.fromRGB(20, 45, 20) }):Play()
		TweenService:Create(speedStroke, TweenInfo.new(0.15), { Color = Color3.fromRGB(80, 220, 80) }):Play()
		Speed.enable()
	else
		speedBtn.Text = "SPEED  OFF"
		speedBtn.TextColor3 = Color3.fromRGB(160, 160, 160)
		TweenService:Create(speedBtn,    TweenInfo.new(0.15), { BackgroundColor3 = Color3.fromRGB(35, 35, 35) }):Play()
		TweenService:Create(speedStroke, TweenInfo.new(0.15), { Color = Color3.fromRGB(70, 70, 70) }):Play()
		Speed.disable()
	end
end)

-- ── ESP OBJECT HELPERS (original Con Ex) ─────────────────
local function getCharParts(char)
	return char:FindFirstChild("Head"),
	       char:FindFirstChild("HumanoidRootPart"),
	       char:FindFirstChildOfClass("Humanoid")
end

local function removeESP(plr)
	local d = espObjects[plr]
	if not d then return end
	if d.bill         and d.bill.Parent         then d.bill:Destroy()         end
	if d.highlight    and d.highlight.Parent    then d.highlight:Destroy()    end
	if d.selectionBox and d.selectionBox.Parent then d.selectionBox:Destroy() end
	espObjects[plr] = nil
end

local function createESP(plr)
	if plr == player then return end
	removeESP(plr)

	local char = plr.Character
	if not char then return end
	local head, hrp, hum = getCharParts(char)
	if not head or not hrp or not hum then return end

	local bill = Instance.new("BillboardGui")
	bill.Name = "ESP_Bill"
	bill.Adornee = hrp
	bill.AlwaysOnTop = true
	bill.Size = UDim2.new(0, 130, 0, 60)
	bill.StudsOffset = Vector3.new(0, 3.2, 0)
	bill.ResetOnSpawn = false
	bill.Parent = playerGui

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.new(1, 0, 0.5, 0)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = plr.DisplayName
	nameLabel.TextColor3 = espColor
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextSize = 13
	nameLabel.TextStrokeTransparency = 0.4
	nameLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	nameLabel.Parent = bill

	local healthBg = Instance.new("Frame")
	healthBg.Size = UDim2.new(0.8, 0, 0, 4)
	healthBg.Position = UDim2.new(0.1, 0, 0.55, 0)
	healthBg.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	healthBg.BorderSizePixel = 0
	Instance.new("UICorner", healthBg).CornerRadius = UDim.new(1, 0)
	healthBg.Parent = bill

	local healthBar = Instance.new("Frame")
	healthBar.Size = UDim2.new(hum.Health / math.max(hum.MaxHealth, 1), 0, 1, 0)
	healthBar.BackgroundColor3 = Color3.fromRGB(80, 220, 80)
	healthBar.BorderSizePixel = 0
	Instance.new("UICorner", healthBar).CornerRadius = UDim.new(1, 0)
	healthBar.Parent = healthBg

	local distLabel = Instance.new("TextLabel")
	distLabel.Size = UDim2.new(1, 0, 0.35, 0)
	distLabel.Position = UDim2.new(0, 0, 0.65, 0)
	distLabel.BackgroundTransparency = 1
	distLabel.Text = ""
	distLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
	distLabel.Font = Enum.Font.Code
	distLabel.TextSize = 10
	distLabel.TextStrokeTransparency = 0.5
	distLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	distLabel.Parent = bill

	local highlight = Instance.new("Highlight")
	highlight.Name = "ESP_Highlight"
	highlight.Adornee = char
	highlight.FillColor = espColor
	highlight.FillTransparency = 0.82
	highlight.OutlineColor = espColor
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Enabled = showBox and espEnabled
	highlight.Parent = char

	-- BoxHandleAdornment: wireframe box that renders through walls via AlwaysOnTop
	local selectionBox = Instance.new("BoxHandleAdornment")
	selectionBox.Name        = "ESP_SelectionBox"
	selectionBox.Adornee     = hrp
	selectionBox.AlwaysOnTop = true
	selectionBox.ZIndex      = 5
	selectionBox.Size        = Vector3.new(4.5, 6.5, 4.5)  -- rough full-body size
	selectionBox.Color3      = espColor
	selectionBox.Transparency = 0
	selectionBox.Visible     = showBoxESP and espEnabled
	selectionBox.Parent      = workspace

	espObjects[plr] = {
		bill         = bill,
		nameLabel    = nameLabel,
		healthBar    = healthBar,
		healthBg     = healthBg,
		distLabel    = distLabel,
		highlight    = highlight,
		selectionBox = selectionBox,
		hrp          = hrp,
		hum          = hum,
		char         = char,
	}
end

local function refreshAllESP()
	for plr in pairs(espObjects) do removeESP(plr) end
	if not espEnabled then return end
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= player then createESP(plr) end
	end
end

Players.PlayerAdded:Connect(function(plr)
	plr.CharacterAdded:Connect(function()
		task.wait(1)
		if espEnabled then createESP(plr) end
	end)
end)
for _, plr in ipairs(Players:GetPlayers()) do
	if plr ~= player then
		plr.CharacterAdded:Connect(function()
			task.wait(1)
			if espEnabled then createESP(plr) end
		end)
	end
end
Players.PlayerRemoving:Connect(function(plr) removeESP(plr) end)

-- ── RENDER LOOP (original Con Ex) ────────────────────────
RunService.RenderStepped:Connect(function()
	local localChar = player.Character
	local localHrp  = localChar and localChar:FindFirstChild("HumanoidRootPart")

	local count = 0
	for plr, data in pairs(espObjects) do
		if not plr.Character or not data.hrp or not data.hrp.Parent
		   or not data.char or not data.char.Parent then
			removeESP(plr)
			continue
		end

		count += 1

		-- Distance cull: hide everything if beyond espMaxDist
		local withinRange = true
		if localHrp and data.hrp then
			local d3 = (data.hrp.Position - localHrp.Position).Magnitude
			if d3 > espMaxDist then withinRange = false end
		end

		data.nameLabel.Visible = showNames    and espEnabled and withinRange
		data.healthBg.Visible  = showHealth   and espEnabled and withinRange
		data.distLabel.Visible = showDistance and espEnabled and withinRange

		if data.highlight and data.highlight.Parent then
			data.highlight.Enabled      = showBox and espEnabled and withinRange
			data.highlight.FillColor    = espColor
			data.highlight.OutlineColor = espColor
		end

		if data.selectionBox and data.selectionBox.Parent then
			data.selectionBox.Visible = showBoxESP and espEnabled
			data.selectionBox.Color3  = espColor
		end

		if not espEnabled then continue end

		data.nameLabel.Text       = plr.DisplayName
		data.nameLabel.TextColor3 = espColor

		local hum = data.hum
		if hum and hum.Parent then
			local pct = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
			data.healthBar.Size = UDim2.new(pct, 0, 1, 0)
			local r = math.clamp(2 * (1 - pct), 0, 1)
			local g = math.clamp(2 * pct,       0, 1)
			data.healthBar.BackgroundColor3 = Color3.new(r, g, 0.1)
		end

		if localHrp then
			local dist = math.floor((data.hrp.Position - localHrp.Position).Magnitude)
			data.distLabel.Text = dist .. " studs"
		end

	end

	playerCountLabel.Text = "Players tracked: " .. count
end)

-- ── ESP MASTER TOGGLE (original Con Ex) ──────────────────
espToggleBtn.MouseButton1Click:Connect(function()
	espEnabled = not espEnabled
	if espEnabled then
		espToggleBtn.Text       = "ESP  ON"
		espToggleBtn.TextColor3 = espColor
		TweenService:Create(espToggleBtn,    TweenInfo.new(0.15), { BackgroundColor3 = Color3.fromRGB(20,45,20) }):Play()
		TweenService:Create(espToggleStroke, TweenInfo.new(0.15), { Color = espColor }):Play()
	else
		espToggleBtn.Text       = "ESP  OFF"
		espToggleBtn.TextColor3 = Color3.fromRGB(160,160,160)
		TweenService:Create(espToggleBtn,    TweenInfo.new(0.15), { BackgroundColor3 = Color3.fromRGB(35,35,35) }):Play()
		TweenService:Create(espToggleStroke, TweenInfo.new(0.15), { Color = Color3.fromRGB(70,70,70) }):Play()
	end
	refreshAllESP()
end)

-- ── TAB SWITCHING (4 tabs) ───────────────────────────────
local tabPositions = { client = 0, esp = 0.25, combat = 0.5, aim = 0.75 }

local function switchTab(tab)
	-- hide all panels first
	clientPanel.Visible = false
	espPanel.Visible    = false
	combatPanel.Visible = false
	aimPanel.Visible    = false
	-- dim all tabs
	for _, t in ipairs({clientTab, espTab, combatTab, aimTab}) do
		t.BackgroundColor3 = Color3.fromRGB(22,22,22)
		t.TextColor3       = Color3.fromRGB(120,120,120)
	end
	local btn
	if tab == "client" then
		clientPanel.Visible = true
		btn = clientTab
	elseif tab == "esp" then
		espPanel.Visible = true
		btn = espTab
	elseif tab == "combat" then
		combatPanel.Visible = true
		btn = combatTab
	elseif tab == "aim" then
		aimPanel.Visible = true
		btn = aimTab
	end
	if btn then
		btn.BackgroundColor3 = Color3.fromRGB(35,35,35)
		btn.TextColor3       = Color3.fromRGB(255,255,255)
	end
	TweenService:Create(tabUnderline, TweenInfo.new(0.2, Enum.EasingStyle.Quad),
		{ Position = UDim2.new(tabPositions[tab] or 0, 0, 1, -2) }):Play()
end

clientTab.MouseButton1Click:Connect(function() switchTab("client") end)
espTab.MouseButton1Click:Connect(function()    switchTab("esp")    end)
combatTab.MouseButton1Click:Connect(function() switchTab("combat") end)
aimTab.MouseButton1Click:Connect(function()    switchTab("aim")    end)

-- ── COLOR HELPERS (original Con Ex) ──────────────────────
local function toHex(c)
	return string.format("#%02X%02X%02X",
		math.floor(c.R*255), math.floor(c.G*255), math.floor(c.B*255))
end

local function updateEspColor(hue)
	hue = math.clamp(hue, 0, 1)
	local col             = Color3.fromHSV(hue, 1, 0.9)
	knob.Position         = UDim2.new(hue, -10, 0.5, -10)
	knob.BackgroundColor3 = col
	hexLabel.Text         = toHex(col)
	espColor              = col
	if espEnabled then
		espToggleBtn.TextColor3 = col
		espToggleStroke.Color   = col
	end
	for _, data in pairs(espObjects) do
		data.nameLabel.TextColor3 = col
		if data.highlight and data.highlight.Parent then
			data.highlight.FillColor    = col
			data.highlight.OutlineColor = col
		end
	end
end

local function updateBgColor(hue)
	hue = math.clamp(hue, 0, 1)
	local col               = Color3.fromHSV(hue, 0.6, 0.15)
	bgKnob.Position         = UDim2.new(hue, -10, 0.5, -10)
	bgKnob.BackgroundColor3 = Color3.fromHSV(hue, 1, 0.9)
	bgHexLabel.Text         = toHex(col)
	bgBox.BackgroundColor3  = col
	bgStroke.Color          = Color3.fromHSV(hue, 0.5, 0.3)
end

local function updateAimColor(hue)
	hue = math.clamp(hue, 0, 1)
	local col               = Color3.fromHSV(hue, 1, 0.9)
	aimKnob.Position        = UDim2.new(hue, -10, 0.5, -10)
	aimKnob.BackgroundColor3 = col
	aimHexLabel.Text        = toHex(col)
	fovStroke.Color         = col
end

local function getHue(trk, inputX)
	return math.clamp((inputX - trk.AbsolutePosition.X) / trk.AbsoluteSize.X, 0, 1)
end

-- ── DRAG WINDOW (original Con Ex) ────────────────────────
local draggingWindow = false
local dragStartMouse, dragStartPos

dragBar.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or
	   input.UserInputType == Enum.UserInputType.Touch then
		draggingWindow = true
		dragStartMouse = Vector2.new(input.Position.X, input.Position.Y)
		dragStartPos   = bgBox.Position
	end
end)

-- ── DRAG SLIDERS (original Con Ex) ───────────────────────
local draggingSlider = false
local activeTrack    = nil

knob.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or
	   input.UserInputType == Enum.UserInputType.Touch then
		draggingSlider = true
		activeTrack    = "esp"
	end
end)

track.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or
	   input.UserInputType == Enum.UserInputType.Touch then
		draggingSlider = true
		activeTrack    = "esp"
		updateEspColor(getHue(track, input.Position.X))
	end
end)

bgKnob.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or
	   input.UserInputType == Enum.UserInputType.Touch then
		draggingSlider = true
		activeTrack    = "bg"
	end
end)

bgTrack.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or
	   input.UserInputType == Enum.UserInputType.Touch then
		draggingSlider = true
		activeTrack    = "bg"
		updateBgColor(getHue(bgTrack, input.Position.X))
	end
end)

-- ESP distance slider drag
local draggingEspDist = false
espDistKnob.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or
	   input.UserInputType == Enum.UserInputType.Touch then
		draggingEspDist = true
	end
end)
espDistTrack.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or
	   input.UserInputType == Enum.UserInputType.Touch then
		draggingEspDist = true
		local t = math.clamp((input.Position.X - espDistTrack.AbsolutePosition.X) / espDistTrack.AbsoluteSize.X, 0, 1)
		espMaxDist = math.floor(10 + t * 990)
		espDistKnob.Position = UDim2.new(t, -10, 0.5, -10)
		espDistFill.Size     = UDim2.new(t, 0, 1, 0)
		espDistLabel.Text    = "MAX DIST  ( " .. espMaxDist .. " studs )"
	end
end)

aimKnob.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or
	   input.UserInputType == Enum.UserInputType.Touch then
		draggingSlider = true
		activeTrack    = "aim"
	end
end)

aimTrack.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or
	   input.UserInputType == Enum.UserInputType.Touch then
		draggingSlider = true
		activeTrack    = "aim"
		updateAimColor(getHue(aimTrack, input.Position.X))
	end
end)

-- ── SHARED INPUT (original Con Ex) ───────────────────────
UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or
	   input.UserInputType == Enum.UserInputType.Touch then
		draggingWindow  = false
		draggingSlider  = false
		activeTrack     = nil
		draggingEspDist = false
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseMovement or
	   input.UserInputType == Enum.UserInputType.Touch then
		if draggingWindow then
			local delta = Vector2.new(input.Position.X, input.Position.Y) - dragStartMouse
			bgBox.Position = UDim2.new(
				dragStartPos.X.Scale, dragStartPos.X.Offset + delta.X,
				dragStartPos.Y.Scale, dragStartPos.Y.Offset + delta.Y
			)
		elseif draggingEspDist then
			local t = math.clamp((input.Position.X - espDistTrack.AbsolutePosition.X) / espDistTrack.AbsoluteSize.X, 0, 1)
			espMaxDist = math.floor(10 + t * 990)
			espDistKnob.Position = UDim2.new(t, -10, 0.5, -10)
			espDistFill.Size     = UDim2.new(t, 0, 1, 0)
			espDistLabel.Text    = "MAX DIST  ( " .. espMaxDist .. " studs )"
		elseif draggingSlider then
			if activeTrack == "esp" then
				updateEspColor(getHue(track, input.Position.X))
			elseif activeTrack == "bg" then
				updateBgColor(getHue(bgTrack, input.Position.X))
			elseif activeTrack == "aim" then
				updateAimColor(getHue(aimTrack, input.Position.X))
			end
		end
	end
end)

-- ── L KEY TOGGLE (original Con Ex) ───────────────────────
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.L then
		guiVisible    = not guiVisible
		bgBox.Visible = guiVisible
		bgBox.Active  = guiVisible
	end
end)
