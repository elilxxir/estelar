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
local Propulsor = Boat:WaitForChild('Propulsor') -- // Primera parte: aqui van los sonidos (una sola vez)
-- // Todas las partes Propulsor (tag "propulsor" o llamadas "Propulsor"): los efectos se activan en todas
local Propulsors = {}
for _, inst in ipairs(game:GetService('CollectionService'):GetTagged('propulsor')) do
	if inst:IsA('BasePart') and inst:IsDescendantOf(Boat) then
		table.insert(Propulsors, inst)
	end
end
for _, inst in ipairs(Boat:GetChildren()) do
	if inst.Name == 'Propulsor' and inst:IsA('BasePart') and not table.find(Propulsors, inst) then
		table.insert(Propulsors, inst)
	end
end
if #Propulsors == 0 then
	Propulsors[1] = Propulsor
end
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

-- ============================================================
--  VUELO. El servidor concede los modos (atributo FlightMode, que el cliente copia), valida lo que el piloto
--  replica y, si hay infracciones, toma el control de la nave y la aterriza (ver Serial/BoatDrive y Settings.FLIGHT).
-- ============================================================

local FLIGHT = require(game.ReplicatedStorage.Gerstner.Settings).FLIGHT

local FlightEvent = Instance.new('RemoteEvent')
FlightEvent.Name = 'FlightEvent'
FlightEvent.Parent = Boat
Boat:SetAttribute('FlightMode', 'Water') -- // 'Water' | 'Takeoff' | 'Flight' | 'Landing'

local FlightLockUntil = 0 -- // os.clock() hasta el que no se puede despegar
local ServerControl = false -- // true: el cliente del piloto esta suspendido y el servidor aterriza la nave
local LastRequest = {}
local Track = BoatDrive.NewTrack()
local ValidateTimer = 0
local LastVelocity = Vector3.zero

local function GetDriver(): Player?
	local Occupant = VehicleSeat.Occupant
	if Occupant == nil then
		return nil
	end
	return Players:GetPlayerFromCharacter(Occupant.Parent)
end

local function SetFlightMode(Mode: string)
	if Boat:GetAttribute('FlightMode') == Mode then
		return
	end
	Boat:SetAttribute('FlightMode', Mode)
	BoatDrive.SetMode(Drive, Mode)
	BoatDrive.ResetTrack(Track)
	Track.Strikes = 0
end

-- // Devuelve el control al piloto despues de un aterrizaje forzado
local function ReleaseControl()
	if not ServerControl then
		return
	end
	ServerControl = false
	local Driver = GetDriver()
	if Driver then
		pcall(function()
			VehicleSeat:SetNetworkOwner(Driver)
		end)
		FlightEvent:FireClient(Driver, 'Resume')
	end
end

-- // Infraccion confirmada: se suspende al cliente, el servidor toma la nave desde su posicion replicada (con el techo
-- // aplicado) y la aterriza solo. No se puede volver a despegar durante LOCKOUT_SECONDS.
local function Enforce(Reason: string)
	warn(`[Vuelo] {Boat.Name}: {Reason}. Aterrizaje forzado.`)
	FlightLockUntil = os.clock() + FLIGHT.LOCKOUT_SECONDS
	Drive = BoatDrive.new(Boat, VehicleSeat)
	local Position = Drive.Position
	Drive.Position = Vector3.new(Position.X, math.min(Position.Y, BoatDrive.GetCeiling()), Position.Z)
	BoatDrive.SetMode(Drive, 'Landing')
	local Horizontal = Vector3.new(LastVelocity.X, 0, LastVelocity.Z)
	if Horizontal.Magnitude > FLIGHT.MAX_SPEED then
		Horizontal = Horizontal.Unit * FLIGHT.MAX_SPEED
	end
	Drive.Vel = Horizontal
	Drive.VerticalSpeed = math.clamp(LastVelocity.Y, -FLIGHT.MAX_DESCENT_RATE, FLIGHT.MAX_CLIMB_RATE)
	Boat:SetAttribute('FlightMode', 'Landing')
	BoatDrive.ResetTrack(Track)
	Track.Strikes = 0

	ServerControl = true
	pcall(function()
		VehicleSeat:SetNetworkOwner(nil)
	end)
	local Driver = GetDriver()
	if Driver then
		FlightEvent:FireClient(Driver, 'ServerControl', Reason)
	end
end

-- // Peticiones del piloto. El servidor decide si las concede.
FlightEvent.OnServerEvent:Connect(function(Player: Player, Action: any)
	if typeof(Action) ~= 'string' or not FLIGHT.ENABLED or ServerControl or Player ~= GetDriver() then
		return
	end
	local Now = os.clock()
	if Now - (LastRequest[Player] or 0) < FLIGHT.REQUEST_COOLDOWN then
		return
	end
	LastRequest[Player] = Now

	local Mode = Boat:GetAttribute('FlightMode')
	if Action == 'Takeoff' then
		if Mode == 'Water' then
			if Now < FlightLockUntil then
				return
			end
			local Zone = ZoneManager:GetZoneParameters(VehicleSeat.Position)
			if Zone ~= nil and Zone.Type == 'Whirlpool' and not FLIGHT.ALLOW_IN_WHIRLPOOL then
				return
			end
			SetFlightMode('Takeoff')
		elseif Mode == 'Landing' then
			-- // Cancelar el aterrizaje: vuelve a Flight si ya esta sobre la altura de GATE_HEIGHT, si no re-despega
			local Measure = BoatDrive.Measure(Drive, VehicleSeat.CFrame)
			SetFlightMode(if Measure ~= nil and Measure.Height >= FLIGHT.GATE_HEIGHT then 'Flight' else 'Takeoff')
		end
	elseif Action == 'Land' then
		if Mode == 'Flight' or Mode == 'Takeoff' then
			SetFlightMode('Landing')
		end
	end
end)
Players.PlayerRemoving:Connect(function(Player)
	LastRequest[Player] = nil
end)

-- // Validacion y transiciones automaticas, cada VALIDATE_INTERVAL
RunService.PostSimulation:Connect(function(dt)
	ValidateTimer += dt
	if ValidateTimer < FLIGHT.VALIDATE_INTERVAL then
		return
	end
	local Interval = ValidateTimer
	ValidateTimer = 0
	LastVelocity = VehicleSeat.AssemblyLinearVelocity

	local Mode = Boat:GetAttribute('FlightMode')
	local Reason, Measure
	if GetDriver() ~= nil and not ServerControl then
		Reason, Measure = BoatDrive.Validate(Drive, Track, Interval, VehicleSeat.CFrame, Mode)
	elseif Mode ~= 'Water' then
		Measure = BoatDrive.Measure(Drive, VehicleSeat.CFrame, Interval)
	end
	if Measure == nil then
		return
	end

	if Reason ~= nil then
		Track.Strikes += 1
		if Track.Strikes >= FLIGHT.STRIKES_TO_ENFORCE then
			Enforce(Reason)
			return
		end
	else
		Track.Strikes = math.max(Track.Strikes - 1, 0)
	end

	if Mode ~= 'Water' and Measure.Swept then
		-- // La ola gigante supero el techo: la nave es arrastrada (no es una infraccion)
		FlightLockUntil = os.clock() + FLIGHT.SWEPT_LOCKOUT_SECONDS
		SetFlightMode('Water')
		ReleaseControl()
	elseif Mode == 'Takeoff' and Measure.Height >= FLIGHT.GATE_HEIGHT + FLIGHT.GATE_BLEND then
		SetFlightMode('Flight')
	elseif Mode == 'Landing' and Measure.Height <= FLIGHT.TOUCHDOWN_HEIGHT then
		SetFlightMode('Water')
		ReleaseControl()
	end
end)

-- // Retoma la nave desde su posicion actual (al bajarse el piloto). Si estaba en vuelo, aterriza sola.
local function RebuildDrive()
	Drive = BoatDrive.new(Boat, VehicleSeat)
	if Boat:GetAttribute('FlightMode') ~= 'Water' then
		BoatDrive.SetMode(Drive, 'Landing')
		Drive.Vel = Vector3.new(LastVelocity.X, 0, LastVelocity.Z)
		Drive.VerticalSpeed = LastVelocity.Y
		Boat:SetAttribute('FlightMode', 'Landing')
		BoatDrive.ResetTrack(Track)
	end
end

-- // El piloto es el dueno de la fisica de la nave: asi la ve sincronizada con la ola.
VehicleSeat:GetPropertyChangedSignal('Occupant'):Connect(function()
	local Occupant = VehicleSeat.Occupant
	if Occupant ~= nil then
		local Driver = Players:GetPlayerFromCharacter(Occupant.Parent)
		if Driver and not ServerControl then
			pcall(function()
				VehicleSeat:SetNetworkOwner(Driver)
			end)
		end
	else
		pcall(function()
			VehicleSeat:SetNetworkOwner(nil)
		end)
		ServerControl = false
		RebuildDrive() -- // Retoma desde donde quedo la nave
	end
end)

ZoneManager.ZoneUpdated:Connect(function()
	BoatDrive.UpdateZone(Drive)
end)

-- // Sin piloto (o con el servidor al mando tras una infraccion), el servidor mueve la nave:
-- // flota sobre la ola, o aterriza si estaba en vuelo
RunService.PreSimulation:Connect(function(dt)
	if VehicleSeat.Occupant == nil or ServerControl then
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
	for _, part in ipairs(Propulsors) do
		for _, effect in ipairs(part:GetChildren()) do
			if effect:IsA("ParticleEmitter") or effect:IsA("Trail") or effect:IsA("Smoke") or effect:IsA("Fire") or effect:IsA("Sparkles") then
				effect.Enabled = enabled
			end
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
