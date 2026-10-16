-- LocalScript en StarterPlayer > StarterPlayerScripts
-- Efectos de la nave en vuelo (v14). Todo se calcula en cada cliente a partir del movimiento real de la nave, asi que
-- los demas jugadores tambien lo ven y lo oyen:
--   * Propulsores verticales pequenos (eyeccion de gas): en el aire siempre sale gas por abajo (mas al subir); al bajar sale tambien por arriba
--   * v17: propulsores laterales: con A / D sale gas por el lado contrario al del giro
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
local SPARK = 'rbxasset://textures/particles/sparkles_main.dds'
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
-- // v18: efectos de las boquillas. Cada boquilla es una lista de { e = emisor, base = Rate a empuje completo }.
-- // PERSONALIZAR: crea una carpeta ReplicatedStorage > Gerstner > GasEffects con ParticleEmitters hechos en Studio.
-- // Se clonan en cada boquilla (el Rate que les pongas es el de empuje completo; el script lo escala con el empuje).
-- // Opcional: subcarpetas GasEffects > Vertical (boquillas de arriba / abajo) y GasEffects > Lateral (A / D).
-- // Sin carpeta se usan los efectos por defecto de abajo.
local EffectsRoot = RS:WaitForChild('Gerstner'):FindFirstChild('GasEffects')

local function makeNozzle(att, kind: string)
	local items = {}

	if EffectsRoot then
		local Source = EffectsRoot:FindFirstChild(kind) or EffectsRoot
		for _, inst in Source:GetChildren() do
			if inst:IsA('ParticleEmitter') then
				local e = inst:Clone()
				local base = e.Rate
				e.Rate = 0
				e.Enabled = true
				e.Parent = att
				table.insert(items, { e = e, base = base })
			end
		end
		if #items > 0 then
			return items
		end
	end

	-- // Por defecto. LockedToPart = true: las particulas se mueven CON la nave, asi que salen disparadas desde la boquilla
	-- // (antes nacian en el mundo, quedaban atras al avanzar como humo y atravesaban el casco). Chorro corto y direccional.
	local jet = Instance.new('ParticleEmitter')
	jet.Texture = SMOKE
	jet.LockedToPart = true
	jet.Color = ColorSequence.new(Color3.fromRGB(235, 245, 255), Color3.fromRGB(150, 170, 190))
	jet.LightEmission = 0.5
	jet.Lifetime = NumberRange.new(0.18, 0.32)
	jet.Speed = NumberRange.new(55, 80)
	jet.SpreadAngle = Vector2.new(4, 4)
	jet.Drag = 0
	jet.Rotation = NumberRange.new(0, 360)
	jet.RotSpeed = NumberRange.new(-90, 90)
	jet.Size = seq(0.6, 2.2)
	jet.Transparency = seq(0.2, 1)
	jet.Rate = 0
	jet.Enabled = true
	jet.Parent = att
	table.insert(items, { e = jet, base = GAS.RATE })

	local core = Instance.new('ParticleEmitter')
	core.Texture = SPARK
	core.LockedToPart = true
	core.Color = ColorSequence.new(Color3.fromRGB(190, 225, 255))
	core.LightEmission = 1
	core.Lifetime = NumberRange.new(0.08, 0.14)
	core.Speed = NumberRange.new(80, 110)
	core.SpreadAngle = Vector2.new(2, 2)
	core.Drag = 0
	core.Size = seq(0.9, 0.2)
	core.Transparency = seq(0, 1)
	core.Rate = 0
	core.Enabled = true
	core.Parent = att
	table.insert(items, { e = core, base = GAS.RATE * 0.6 })

	return items
end

-- // Escala el Rate de todos los emisores de una boquilla (amount: 0 a 1 = empuje)
local function setNozzle(items, amount: number)
	for _, item in items do
		item.e.Rate = item.base * amount
	end
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
		table.insert(downNozzles, makeNozzle(makeAtt(main, point.WorldPosition, -up, 'GasDown' .. i), 'Vertical'))
		table.insert(upNozzles, makeNozzle(makeAtt(main, point.WorldPosition, up, 'GasUp' .. i), 'Vertical'))
	end

	-- // v17: boquillas laterales. Al virar a la derecha (D) sale gas por la izquierda, y al reves (A)
	local right = seat.CFrame.RightVector
	local leftNozzles, rightNozzles = {}, {}
	for i, point in points do
		if (point.WorldPosition - main.Position):Dot(right) < 0 then
			table.insert(leftNozzles, makeNozzle(makeAtt(main, point.WorldPosition, -right, 'GasLeft' .. i), 'Lateral'))
		else
			table.insert(rightNozzles, makeNozzle(makeAtt(main, point.WorldPosition, right, 'GasRight' .. i), 'Lateral'))
		end
	end

	local propulsor = boat:FindFirstChild('Propulsor')
	local engineParent = if propulsor and propulsor:IsA('BasePart') then propulsor else main

	states[boat] = {
		boat = boat, main = main, seat = seat,
		downNozzles = downNozzles, upNozzles = upNozzles,
		leftNozzles = leftNozzles, rightNozzles = rightNozzles, lateral = 0,
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
	-- // v17: en el aire las boquillas de abajo siempre tiran gas (GAS.HOVER), y mas al subir
	local Hover = GAS.HOVER * s.flightGain
	local Climb, Descend = math.max(Demand, Hover), math.max(-Demand, 0)

	-- // v17: gas lateral segun el alabeo del casco (A / D). Bank > 0 = alabeo a la derecha (D)
	local Bank = -s.seat.CFrame.RightVector.Y / math.sin(FLIGHT.MAX_TILT)
	local LateralTarget = if Flying and math.abs(Bank) > GAS.DEADZONE * 2 then math.clamp(Bank, -1, 1) else 0
	s.lateral += (LateralTarget - s.lateral) * (1 - math.exp(-dt / 0.12))
	local Lateral = s.lateral
	for _, n in s.leftNozzles do
		setNozzle(n, GAS.LATERAL_SCALE * math.max(Lateral, 0))
	end
	for _, n in s.rightNozzles do
		setNozzle(n, GAS.LATERAL_SCALE * math.max(-Lateral, 0))
	end

	-- // Gas: sube = boquillas de abajo, baja = boquillas de arriba
	for _, n in s.downNozzles do
		setNozzle(n, Climb)
	end
	for _, n in s.upNozzles do
		setNozzle(n, Descend)
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
		local Amount = math.max(math.abs(Demand), Hover, math.abs(Lateral))
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
