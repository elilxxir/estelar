-- script hijo del modelo ServerBoat
-- La nave se mueve con BoatDrive (sin fisica). Con piloto la mueve su cliente (StarterPlayerScripts/BoatDriver);
-- este script solo la mantiene flotando cuando esta vacia y maneja sonidos y efectos.

--!native
--!optimize 2
local Players = game:GetService('Players')
local RunService = game:GetService('RunService')
local Boat = script.Parent
local BoatDrive = require(game.ReplicatedStorage.Gerstner.Serial.BoatDrive)
local ZoneManager = require(game.ReplicatedStorage.Gerstner.Serial.ZoneManager)
Boat:WaitForChild('Main')
workspace.Camera.CameraType = Enum.CameraType.Track
local VehicleSeat = Boat:WaitForChild('VehicleSeat')
local Propulsor = Boat:WaitForChild('Propulsor')
local MAX_SPEED = BoatDrive.MAX_SPEED

-- // Los controladores fisicos antiguos ya no se usan: BoatDrive coloca la nave directamente.
for _, Name in { 'BodyPosition', 'BodyVelocity', 'BodyGyro' } do
	local Controller = VehicleSeat:FindFirstChild(Name)
	if Controller then
		Controller:Destroy()
	end
end

-- // Fuerza que cancela la gravedad, para que la nave no caiga mientras cambia de dueno de fisica.
do
	local Attachment = Instance.new('Attachment')
	Attachment.Name = 'AntiGravityAttachment'
	Attachment.Parent = Boat.Main
	Attachment.WorldPosition = Boat.Main.CenterOfMass

	local Force = Instance.new('VectorForce')
	Force.Name = 'AntiGravity'
	Force.Attachment0 = Attachment
	Force.RelativeTo = Enum.ActuatorRelativeTo.World
	Force.ApplyAtCenterOfMass = true
	Force.Force = Vector3.new(0, Boat.Main.AssemblyMass * workspace.Gravity, 0)
	Force.Parent = Boat.Main
end

local Drive = BoatDrive.new(Boat, VehicleSeat)
pcall(function()
	VehicleSeat:SetNetworkOwner(nil)
end)

-- // El piloto es el dueno de la fisica de la nave: asi la ve sincronizada con la ola.
VehicleSeat:GetPropertyChangedSignal('Occupant'):Connect(function()
	local Occupant = VehicleSeat.Occupant
	if Occupant ~= nil then
		local Driver = Players:GetPlayerFromCharacter(Occupant.Parent)
		if Driver then
			pcall(function()
				VehicleSeat:SetNetworkOwner(Driver)
			end)
		end
	else
		pcall(function()
			VehicleSeat:SetNetworkOwner(nil)
		end)
		Drive = BoatDrive.new(Boat, VehicleSeat) -- // Retoma desde donde quedo la nave
	end
end)

ZoneManager.ZoneUpdated:Connect(function()
	BoatDrive.UpdateZone(Drive)
end)

-- // Sin piloto, el servidor mueve la nave (queda flotando sobre la ola)
RunService.PreSimulation:Connect(function(dt)
	if VehicleSeat.Occupant == nil then
		BoatDrive.Step(Drive, dt, 0, 0, true)
		BoatDrive.Apply(Drive)
	end
end)

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

-- ============================================================
--  EFECTOS Y SONIDO
-- ============================================================

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

-- // La velocidad se mide con el movimiento real de la nave (el piloto la mueve en su cliente)
local MeasuredSpeed = 0
local LastPosition = VehicleSeat.Position

RunService.PostSimulation:Connect(function(dt)
	local Position = VehicleSeat.Position
	local Moved = Vector3.new(Position.X - LastPosition.X, 0, Position.Z - LastPosition.Z).Magnitude
	LastPosition = Position
	MeasuredSpeed += (Moved / dt - MeasuredSpeed) * (1 - math.exp(-dt / 0.3))

	local throttle = VehicleSeat.Throttle

	if throttle == 1 then
		SetPropulsorEffects(true)

		-- Sonido unico al empezar a acelerar
		if lastThrottle ~= 1 then
			accelCooldown = TryPlayOneShot(AccelSound, accelCooldown, dt)
		else
			accelCooldown = math.max(accelCooldown - dt, 0)
		end
	else
		SetPropulsorEffects(false)

		-- Sonido unico al soltar el acelerador
		if lastThrottle == 1 then
			brakeCooldown = TryPlayOneShot(BrakeSound, brakeCooldown, dt)
		else
			brakeCooldown = math.max(brakeCooldown - dt, 0)
		end
	end

	lastThrottle = throttle
	UpdateSoundLayers(math.clamp(MeasuredSpeed / MAX_SPEED, 0, 1))
end)
