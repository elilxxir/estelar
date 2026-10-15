-- LocalScript en StarterPlayer > StarterPlayerScripts
-- Efectos de la nave en vuelo (v14). Todo se calcula en cada cliente a partir del movimiento real de la nave, asi que
-- los demas jugadores tambien lo ven y lo oyen:
--   * Propulsores verticales pequenos (eyeccion de gas): al subir sale gas por abajo, al bajar por arriba
--   * Sonido de propulsores principales en vuelo (loop), sonido de los propulsores verticales (loop) y soplido al arrancar
--   * Vibracion de camara del piloto
-- Los IDs de sonido y los valores se editan en Settings.FLIGHT (GAS, SOUNDS, SHAKE).
-- Barcos: modelos con tag "Boat" o workspace.ServerBoat. Necesita en el barco: Main (TopLeft, TopRight, BottomLeft,
-- BottomRight como attachments), VehicleSeat.

--!nonstrict

local Players = game:GetService('Players')
local RunService = game:GetService('RunService')
local CS = game:GetService('CollectionService')
local RS = game:GetService('ReplicatedStorage')

local FLIGHT = require(RS:WaitForChild('Gerstner'):WaitForChild('Settings')).FLIGHT
local GAS, SOUNDS, SHAKE = FLIGHT.GAS, FLIGHT.SOUNDS, FLIGHT.SHAKE

local STARTUP_DELAY = 6
local SMOKE = 'rbxasset://textures/particles/smoke_main.dds'
local POINT_NAMES = { 'TopLeft', 'TopRight', 'BottomLeft', 'BottomRight' }

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local function seq(a, b)
	return NumberSequence.new({ NumberSequenceKeypoint.new(0, a), NumberSequenceKeypoint.new(1, b) })
end

-- // Attachment cuyo eje +Y (direccion por defecto de un emisor) apunta en worldDir
local function makeAtt(main, worldPos, worldDir, name)
	local pos = main.CFrame:PointToObjectSpace(worldPos)
	local dir = main.CFrame:VectorToObjectSpace(worldDir.Unit)
	local att = Instance.new('Attachment')
	att.Name = name
	att.CFrame = CFrame.lookAt(pos, pos + dir) * CFrame.Angles(-math.pi / 2, 0, 0)
	att.Parent = main
	return att
end

-- // Boquilla de gas: una nube que se abre y un nucleo brillante y corto
local function makeNozzle(att)
	local puff = Instance.new('ParticleEmitter')
	puff.Texture = SMOKE
	puff.Color = ColorSequence.new(Color3.fromRGB(235, 245, 255), Color3.fromRGB(150, 170, 190))
	puff.LightEmission = 0.5
	puff.Lifetime = NumberRange.new(0.25, 0.55)
	puff.Speed = NumberRange.new(28, 45)
	puff.SpreadAngle = Vector2.new(7, 7)
	puff.Drag = 2
	puff.Rotation = NumberRange.new(0, 360)
	puff.RotSpeed = NumberRange.new(-90, 90)
	puff.Size = seq(0.8, 2.8)
	puff.Transparency = seq(0.15, 1)
	puff.Rate = 0
	puff.Enabled = true
	puff.Parent = att

	local core = Instance.new('ParticleEmitter')
	core.Texture = SMOKE
	core.Color = ColorSequence.new(Color3.fromRGB(190, 225, 255))
	core.LightEmission = 1
	core.Lifetime = NumberRange.new(0.08, 0.16)
	core.Speed = NumberRange.new(45, 65)
	core.SpreadAngle = Vector2.new(3, 3)
	core.Size = seq(0.9, 0.2)
	core.Transparency = seq(0, 1)
	core.Rate = 0
	core.Enabled = true
	core.Parent = att

	return { puff = puff, core = core }
end

local function makeSound(Id: string, Parent: Instance, Name: string, Looped: boolean)
	if Id == nil or Id == '' then
		return nil
	end
	local Sound = Instance.new('Sound')
	Sound.Name = Name
	Sound.SoundId = Id
	Sound.Volume = 0
	Sound.Looped = Looped
	Sound.RollOffMaxDistance = SOUNDS.ROLLOFF
	Sound.Parent = Parent
	if Looped then
		Sound:Play()
	end
	return Sound
end

local states = {}

local function setupBoat(boat)
	if states[boat] then
		return
	end
	local main = boat:WaitForChild('Main', 10)
	local seat = boat:WaitForChild('VehicleSeat', 10)
	if not main or not seat then
		return
	end
	local points = {}
	for _, name in POINT_NAMES do
		local a = main:WaitForChild(name, 10)
		if not a then
			return
		end
		table.insert(points, a)
	end

	local up = seat.CFrame.UpVector
	local downNozzles, upNozzles = {}, {} -- // downNozzles: gas hacia abajo (la nave sube); upNozzles: gas hacia arriba (baja)
	for i, point in points do
		table.insert(downNozzles, makeNozzle(makeAtt(main, point.WorldPosition, -up, 'GasDown' .. i)))
		table.insert(upNozzles, makeNozzle(makeAtt(main, point.WorldPosition, up, 'GasUp' .. i)))
	end

	local propulsor = boat:FindFirstChild('Propulsor')
	local engineParent = if propulsor and propulsor:IsA('BasePart') then propulsor else main

	states[boat] = {
		boat = boat, main = main, seat = seat,
		downNozzles = downNozzles, upNozzles = upNozzles,
		ThrusterLoop = makeSound(SOUNDS.ThrusterLoop, engineParent, 'FlightThruster', true),
		GasLoop = makeSound(SOUNDS.GasLoop, main, 'GasThrusters', true),
		GasBurst = makeSound(SOUNDS.GasBurst, main, 'GasBurst', false),
		prevPos = nil, prevClock = 0,
		vel = Vector3.zero, accelY = 0,
		demand = 0, intensity = 0, flightGain = 0,
		lastBurst = 0,
	}

	boat.Destroying:Once(function()
		states[boat] = nil
	end)
end

-- // Vibracion de la camara: la fija update() del barco que ocupa el jugador local
local ShakeTarget = 0
local ShakeValue = 0
local OffsetActive = false

local function IsLocalPilot(s): boolean
	local Character = LocalPlayer.Character
	local Humanoid = Character and Character:FindFirstChildOfClass('Humanoid')
	return Humanoid ~= nil and Humanoid.SeatPart == s.seat
end

local function update(s, dt: number)
	local boat = s.boat
	local pos = s.main.Position
	local clock = os.clock()
	if s.prevPos then
		local dtv = clock - s.prevClock
		if dtv > 1e-3 then
			local Raw = (pos - s.prevPos) / dtv
			s.vel = s.vel:Lerp(Raw, 1 - math.exp(-dtv / 0.08))
			local RawAccel = (s.vel.Y - (s.prevVy or 0)) / dtv
			s.accelY += (RawAccel - s.accelY) * (1 - math.exp(-dtv / 0.12))
		end
	end
	s.prevPos, s.prevClock, s.prevVy = pos, clock, s.vel.Y

	local Flying = (boat:GetAttribute('FlightMode') or 'Water') ~= 'Water'
	s.flightGain += ((if Flying then 1 else 0) - s.flightGain) * (1 - math.exp(-dt / 0.4))

	-- // Empuje vertical: velocidad vertical + aceleracion (pulso al arrancar y al frenar). Suavizado con ataque rapido.
	local Target = 0
	if Flying then
		Target = math.clamp(s.vel.Y / GAS.CLIMB_REF + s.accelY / GAS.ACCEL_REF, -1, 1)
		if math.abs(Target) < GAS.DEADZONE then
			Target = 0
		end
	end
	local PreviousAbs = math.abs(s.demand)
	s.demand += (Target - s.demand) * (1 - math.exp(-dt / 0.12))
	local Demand = s.demand
	local Climb, Descend = math.max(Demand, 0), math.max(-Demand, 0)

	-- // Gas: sube = boquillas de abajo, baja = boquillas de arriba
	for _, n in s.downNozzles do
		n.puff.Rate = GAS.RATE * Climb
		n.core.Rate = GAS.RATE * 0.6 * Climb
	end
	for _, n in s.upNozzles do
		n.puff.Rate = GAS.RATE * Descend
		n.core.Rate = GAS.RATE * 0.6 * Descend
	end

	-- // Propulsores principales: empuje segun velocidad horizontal y orden de avance
	local Horizontal = Vector3.new(s.vel.X, 0, s.vel.Z).Magnitude
	local SpeedRatio = math.clamp(Horizontal / FLIGHT.MAX_SPEED, 0, 1)
	local IntensityTarget = 0
	if Flying then
		IntensityTarget = math.clamp(0.25 + SpeedRatio * 0.55 + math.abs(s.seat.Throttle) * 0.35, 0, 1)
	end
	s.intensity += (IntensityTarget - s.intensity) * (1 - math.exp(-dt / 0.25))

	if s.ThrusterLoop then
		s.ThrusterLoop.Volume = SOUNDS.THRUSTER_VOLUME * s.intensity * s.flightGain
		s.ThrusterLoop.PlaybackSpeed = 0.8 + 0.6 * s.intensity
	end
	if s.GasLoop then
		local Amount = math.abs(Demand)
		s.GasLoop.Volume = SOUNDS.GAS_VOLUME * Amount
		s.GasLoop.PlaybackSpeed = 0.9 + 0.3 * Amount
	end
	if s.GasBurst and PreviousAbs < 0.3 and math.abs(Demand) >= 0.3 and clock - s.lastBurst > 0.7 then
		s.lastBurst = clock
		s.GasBurst.Volume = SOUNDS.BURST_VOLUME
		s.GasBurst.PlaybackSpeed = 0.95 + math.random() * 0.1
		s.GasBurst:Play()
	end

	-- // Vibracion (solo del piloto local)
	if SHAKE.ENABLED and IsLocalPilot(s) then
		local Amount = s.flightGain * (SHAKE.BASE * s.intensity + SHAKE.SPEED * SpeedRatio + SHAKE.GAS * math.abs(Demand))
		ShakeTarget = math.max(ShakeTarget, math.clamp(Amount, 0, 1))
	end
end

RunService.Heartbeat:Connect(function(dt)
	ShakeTarget = 0
	for _, s in states do
		update(s, dt)
	end
end)

RunService:BindToRenderStep('FlightShake', Enum.RenderPriority.Camera.Value + 1, function(dt)
	ShakeValue += (ShakeTarget - ShakeValue) * (1 - math.exp(-dt / 0.15))
	local Character = LocalPlayer.Character
	local Humanoid = Character and Character:FindFirstChildOfClass('Humanoid')
	if ShakeValue < 0.003 then
		if OffsetActive and Humanoid then
			Humanoid.CameraOffset = Vector3.zero
		end
		OffsetActive = false
		return
	end

	local t = os.clock() * SHAKE.FREQ
	local nx = math.noise(t, 12.3, 4.7) * 2
	local ny = math.noise(7.9, t, 1.3) * 2
	local nz = math.noise(3.1, 9.4, t) * 2
	if Humanoid then
		Humanoid.CameraOffset = Vector3.new(nx, ny, 0) * SHAKE.POS * ShakeValue
		OffsetActive = true
	end
	Camera = workspace.CurrentCamera
	-- // La rotacion solo se aplica si Roblox recalcula la camara cada frame (con Scriptable se acumularia)
	if Camera and Camera.CameraType ~= Enum.CameraType.Scriptable then
		Camera.CFrame = Camera.CFrame * CFrame.Angles(nx * SHAKE.ROT * ShakeValue, ny * SHAKE.ROT * ShakeValue, nz * SHAKE.ROT * 0.6 * ShakeValue)
	end
end)

-- // Descubrimiento de barcos (igual que BoatWake)
task.spawn(function()
	task.wait(STARTUP_DELAY)
	for _, boat in CS:GetTagged('Boat') do
		if boat:IsA('Model') then
			task.spawn(setupBoat, boat)
		end
	end
	CS:GetInstanceAddedSignal('Boat'):Connect(function(boat)
		if boat:IsA('Model') then
			task.spawn(setupBoat, boat)
		end
	end)
	local sb = workspace:FindFirstChild('ServerBoat')
	if sb and sb:IsA('Model') then
		task.spawn(setupBoat, sb)
	end
end)
