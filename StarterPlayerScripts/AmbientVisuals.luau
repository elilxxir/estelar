-- LocalScript dentro de StarterPlayer >> StarterPlayerScripts
-- Ambiente visual: cielo gris, neblina y oscurecimiento cuando se acerca la ola gigante.

--!nocheck

local Lighting = game:GetService('Lighting')
local RS = game:GetService('ReplicatedStorage')
local RunService = game:GetService('RunService')

local Gerstner = require(RS:WaitForChild('Gerstner'))
local Camera = workspace.CurrentCamera

local function GetOrCreate(className: string, parent: Instance): any
	local obj = parent:FindFirstChildOfClass(className)
	if not obj then
		obj = Instance.new(className)
		obj.Parent = parent
	end
	return obj
end

-- // Valores base (mar tranquilo, cielo cubierto)
local BASE = {
	Density = 0.42,
	Haze = 2,
	Brightness = 1.2,
	CCBrightness = 0,
}
-- // Valores con la ola cerca
local DANGER = {
	Density = 0.7,
	Haze = 5,
	Brightness = 0.35,
	CCBrightness = -0.08,
}

Lighting.ClockTime = 14
Lighting.GlobalShadows = true
Lighting.Ambient = Color3.fromRGB(70, 78, 86)
Lighting.OutdoorAmbient = Color3.fromRGB(95, 105, 115)
Lighting.ColorShift_Top = Color3.fromRGB(0, 0, 0)
Lighting.EnvironmentDiffuseScale = 0.6
Lighting.EnvironmentSpecularScale = 0.4

-- // Si ya existe un Atmosphere en Lighting, su Density y Haze son la config inicial
local ExistingAtmosphere = Lighting:FindFirstChildOfClass('Atmosphere')
if ExistingAtmosphere then
	BASE.Density = ExistingAtmosphere.Density
	BASE.Haze = ExistingAtmosphere.Haze
end

local Atmosphere = GetOrCreate('Atmosphere', Lighting)
Atmosphere.Color = Color3.fromRGB(198, 180, 154) -- // v02 (antes 150,160,170): cielo beige calido
Atmosphere.Decay = Color3.fromRGB(150, 128, 100) -- // v02 (antes 110,120,130)
Atmosphere.Offset = 0.25
Atmosphere.Glare = 0
Atmosphere.Density = BASE.Density
Atmosphere.Haze = BASE.Haze

local ColorCorrection = GetOrCreate('ColorCorrectionEffect', Lighting)
ColorCorrection.Saturation = -0.25 -- // v02 (antes -0.35)
ColorCorrection.Contrast = 0.1
ColorCorrection.TintColor = Color3.fromRGB(232, 224, 212) -- // v02 (antes 215,225,235): tinte calido
ColorCorrection.Brightness = BASE.CCBrightness

local Bloom = GetOrCreate('BloomEffect', Lighting)
Bloom.Intensity = 0.2
Bloom.Size = 24
Bloom.Threshold = 1.5

-- // Cuanto se acerca la ola (0 = lejos, 1 = encima)
local Danger = 0
local SAMPLE_OFFSETS = { 0, 800, 1600, 2400 } -- // v07 (antes 0,300,600,900): la ola ahora es ~2.9 veces mas ancha

RunService.RenderStepped:Connect(function(dt)
	local cfg = Gerstner.GIANT_CONFIG
	local t = workspace:GetServerTimeNow()
	local cam = Camera.CFrame.Position * Vector3.new(1, 0, 1)

	-- // La ola avanza en cfg.Direction, asi que llega desde atras de la camara
	local near = 0
	for _, offset in SAMPLE_OFFSETS do
		local sample = cam - cfg.Direction * offset
		near = math.max(near, Gerstner.ComputeGiantWave(sample, t).Y / cfg.Height)
	end

	Danger += (near - Danger) * math.min(dt * 2, 1)

	Atmosphere.Density = BASE.Density + (DANGER.Density - BASE.Density) * Danger
	Atmosphere.Haze = BASE.Haze + (DANGER.Haze - BASE.Haze) * Danger
	Lighting.Brightness = BASE.Brightness + (DANGER.Brightness - BASE.Brightness) * Danger
	ColorCorrection.Brightness = BASE.CCBrightness + (DANGER.CCBrightness - BASE.CCBrightness) * Danger
end)
