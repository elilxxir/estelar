-- script hijo del modelo ServerBoat 

--!native
--!optimize 2
local Boat = script.Parent
local HeightLookup = require(game.ReplicatedStorage.HeightLookup)
local ZoneManager = require(game.ReplicatedStorage.Serial.ZoneManager)
local BoatManager = require(game.ReplicatedStorage.Serial.BoatManager)
Boat:WaitForChild('Main')
workspace.Camera.CameraType = Enum.CameraType.Track
local BuoyancyPoints = {
	[1] = Boat.Main.TopLeft,
	[2] = Boat.Main.TopRight,
	[3] = Boat.Main.BottomLeft,
	[4] = Boat.Main.BottomRight,
}
local boatWidth = Boat.Main.Size.X
local boatLength = Boat.Main.Size.Z
local baseHeight = Boat.Main.Size.Y / 2
local MAX_FORCE = Boat.Main.AssemblyMass * workspace.Gravity * 4
local DRAG_COEFFICIENT = 0.15
local VehicleSeat = Boat:WaitForChild('VehicleSeat')
local Propulsor = Boat:WaitForChild('Propulsor')
VehicleSeat.BodyPosition.MaxForce = Vector3.new(0, MAX_FORCE, 0)
VehicleSeat:SetNetworkOwner(nil)

-- ============================================================
--  CAPAS DE SONIDO (loops, escalan con velocidad)
-- ============================================================

local SOUND_LAYERS = {
	{
		name      = "Motor",
		id        = "rbxassetid://",
		parent    = Propulsor,
		maxVolume = 5,
		minVolume = 0,
		pitchMin  = 0.8,
		pitchMax  = 1.4,
		rollOff   = 1000,		
	},
	{
		name      = "Agua",
		id        = "rbxassetid://9120589560",
		parent    = Boat.Main,
		maxVolume = 5,
		minVolume = 0,
		pitchMin  = 0.9,
		pitchMax  = 1.1,
		rollOff   = 1000,
	},
	{
		name      = "Motor2",
		id        = "rbxassetid://133950398445570",
		parent    = Boat.Main,
		maxVolume = 5,
		minVolume = 0,
		pitchMin  = 0.7,
		pitchMax  = 1.0,
		rollOff   = 1000,
		
		
	},
	
	{
		name      = "Motor3",
		id        = "rbxassetid://135314203986462",
		parent    = Boat.Main,
		maxVolume = 5,
		minVolume = 0,
		pitchMin  = 0.7,
		pitchMax  = 1.0,
		rollOff   = 1000,


	},
	
	{
		name      = "Motor4",
		id        = "rbxassetid://133146309298451",
		parent    = Boat.Main,
		maxVolume = 5,
		minVolume = 0,
		pitchMin  = 0.7,
		pitchMax  = 1.0,
		rollOff   = 1000,


	},
	{
		name      = "Viento",
		id        = "rbxassetid://9119414082",
		parent    = Propulsor,
		maxVolume = 5,
		minVolume = 0,
		pitchMin  = 1.0,
		pitchMax  = 1.0,
		rollOff   = 1000,
	},
}

local SoundInstances = {}
for _, layer in ipairs(SOUND_LAYERS) do
	local sound = Instance.new("Sound")
	sound.Name = layer.name
	sound.SoundId = layer.id
	sound.Volume = layer.minVolume
	sound.Looped = true
	sound.RollOffMaxDistance = layer.rollOff
	sound.PlaybackSpeed = layer.pitchMin
	sound.Parent = layer.parent
	sound:Play()
	table.insert(SoundInstances, { sound = sound, layer = layer })
end

-- ============================================================
--  SONIDOS ÚNICOS — aceleración y freno (one-shot con cooldown)
-- ============================================================

local ACCEL_SOUND_ID = "rbxassetid://97389710665143"  -- cambia por tu ID de aceleración
local BRAKE_SOUND_ID = "rbxassetid://5272402910"  -- cambia por tu ID de freno
local ONESHOT_COOLDOWN = 1.5  -- segundos mínimos entre disparos

local AccelSound = Instance.new("Sound")
AccelSound.Name = "Aceleracion"
AccelSound.SoundId = ACCEL_SOUND_ID
AccelSound.Volume = 3
AccelSound.Looped = false
AccelSound.RollOffMaxDistance = 1000
AccelSound.Parent = Propulsor

local BrakeSound = Instance.new("Sound")
BrakeSound.Name = "Freno"
BrakeSound.SoundId = BRAKE_SOUND_ID
BrakeSound.Volume = 3
BrakeSound.Looped = false
BrakeSound.RollOffMaxDistance = 1000
BrakeSound.Parent = Propulsor

local lastThrottle    = 0
local accelCooldown   = 0
local brakeCooldown   = 0

local function TryPlayOneShot(sound, cooldownRef, dt)
	-- Devuelve el nuevo valor del cooldown
	cooldownRef = math.max(cooldownRef - dt, 0)
	if cooldownRef <= 0 and not sound.IsPlaying then
		sound:Play()
		cooldownRef = ONESHOT_COOLDOWN
	end
	return cooldownRef
end

-- ── ZONAS ────────────────────────────────────────────────────
local CurrentZoneInfo = {
	SpeedMultiplier = 1;
	PhaseMultiplier = 1;
	AmplitudeMultiplier = 1;
	CURRENT_ZONE = nil;
}
local function UpdateZoneMultipliers()
	CurrentZoneInfo.CURRENT_ZONE = ZoneManager:GetZoneParameters(Boat.Main.Position)
end

local Accumulated = 0
local ZoneAccumulated = 0
local CurrentRotation = 0
local CurrentSpeed = 0
local MAX_SPEED = 200
local ACCELERATION = 10
local DECELERATION = 15

local function SetPropulsorEffects(enabled)
	for _, effect in ipairs(Propulsor:GetChildren()) do
		if effect:IsA("ParticleEmitter") or effect:IsA("Trail") or effect:IsA("Smoke") or effect:IsA("Fire") or effect:IsA("Sparkles") then
			effect.Enabled = enabled

		end
	end
end


local function UpdateSoundLayers(speedRatio)
	for _, entry in ipairs(SoundInstances) do
		local s = entry.sound
		local l = entry.layer
		s.Volume = l.minVolume + (l.maxVolume - l.minVolume) * speedRatio
		s.PlaybackSpeed = l.pitchMin + (l.pitchMax - l.pitchMin) * speedRatio
	end
end

game:GetService('RunService').PostSimulation:Connect(function(dt)
	Accumulated += dt
	ZoneAccumulated += dt
	local CURRENT_ZONE = CurrentZoneInfo.CURRENT_ZONE
	if CURRENT_ZONE ~= nil then
		local Link: BasePart? = CURRENT_ZONE.Link
		if CURRENT_ZONE.Type ~= 'Whirlpool' then
			if (CURRENT_ZONE.Link) then
				local Position = CURRENT_ZONE.Link.Position
				CurrentZoneInfo.PhaseMultiplier, CurrentZoneInfo.SpeedMultiplier, CurrentZoneInfo.AmplitudeMultiplier = ZoneManager:GetZoneMultipliers(Boat.Main.Position, Position, CURRENT_ZONE)
			else
				local IslandPosition, Radius = CURRENT_ZONE.Island.Center.Position, CURRENT_ZONE.Radius / 2
				CurrentZoneInfo.PhaseMultiplier, CurrentZoneInfo.SpeedMultiplier, CurrentZoneInfo.AmplitudeMultiplier = ZoneManager:GetIslandMultipliers(Boat.Main.Position, IslandPosition, Radius)
			end
		end
	end
	if VehicleSeat.Steer == 1 then
		CurrentRotation -= math.rad(0.5)
	elseif VehicleSeat.Steer == -1 then
		CurrentRotation += math.rad(0.5)
	end

	local throttle = VehicleSeat.Throttle

	if throttle == 1 then
		CurrentSpeed = math.min(CurrentSpeed + ACCELERATION * dt, MAX_SPEED)
		SetPropulsorEffects(true)

		-- Sonido único al empezar a acelerar
		if lastThrottle ~= 1 then
			accelCooldown = TryPlayOneShot(AccelSound, accelCooldown, dt)
		else
			accelCooldown = math.max(accelCooldown - dt, 0)
		end
	else
		CurrentSpeed = math.max(CurrentSpeed - DECELERATION * dt, 0)
		SetPropulsorEffects(false)

		-- Sonido único al soltar el acelerador
		if lastThrottle == 1 then
			brakeCooldown = TryPlayOneShot(BrakeSound, brakeCooldown, dt)
		else
			brakeCooldown = math.max(brakeCooldown - dt, 0)
		end
	end

	lastThrottle = throttle

	VehicleSeat.BodyVelocity.Velocity = VehicleSeat.CFrame.LookVector * CurrentSpeed
	UpdateSoundLayers(CurrentSpeed / MAX_SPEED)

	local Height, Orientation, Depth = BoatManager.CalculateBuoyancy(Boat.Main.CenterOfMass, Boat.Main.Center.WorldPosition, BuoyancyPoints, boatLength, boatWidth, baseHeight, CurrentZoneInfo)
	if Height ~= Vector3.zero then
		VehicleSeat.BodyPosition.MaxForce = Vector3.new(0, MAX_FORCE * (1 + (Depth / 10)), 0)
		VehicleSeat.BodyPosition.Position = Height
	else
		VehicleSeat.BodyPosition.MaxForce = Vector3.zero
	end
	VehicleSeat.BodyGyro.CFrame = CFrame.fromEulerAnglesXYZ(0, CurrentRotation, 0) * Orientation
	if ZoneAccumulated >= 3 then
		ZoneAccumulated = 0
		UpdateZoneMultipliers()
	end
end)
ZoneManager.ZoneUpdated:Connect(function()
	UpdateZoneMultipliers()
end)