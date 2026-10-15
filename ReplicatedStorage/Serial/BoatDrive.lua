-- ModuleScript dentro de carpeta Serial dentro de script Gerstner dentro de ReplicatedStorage

--!nonstrict

--[[
	Movimiento de la nave sin motor de fisica de Roblox: se simula aqui y se coloca directamente el VehicleSeat
	(el resto de la nave va soldado al asiento). Dinamica simplificada pero con inercia:

	- Altura: la ola empuja a la nave como un resorte amortiguado. Si la ola se aleja mas rapido de lo que
	  puede caer la nave, pierde contacto con el agua y cae por gravedad (salta en las crestas rapidas).
	- Inclinacion: pitch y roll siguen la pendiente real de la ola bajo el casco, con inercia (sin saltos).
	- Pendiente: subir una ola frena la nave y bajarla la acelera.

	Lo usan dos scripts:
	- Cliente del piloto (StarterPlayerScripts/BoatDriver): mueve la nave mientras hay alguien sentado.
	- Servidor (Handler): la mantiene flotando cuando esta vacia y valida el vuelo del piloto (BoatDrive.Validate).

	Modos (self.Mode). El servidor es quien los concede (atributo FlightMode del modelo); el cliente los copia con SetMode:
	- Water:   flotacion (descrito arriba).
	- Takeoff: sube sola hasta superar la altura de GATE_HEIGHT. Sin inclinacion ni aceleracion horizontal hasta pasarla.
	- Flight:  controles de helicoptero. Cabeceo / alabeo -> aceleracion horizontal, guinada -> rumbo, colectivo -> altura.
	- Landing: desciende sola, con menos inclinacion y velocidad horizontal, hasta TOUCHDOWN_CLEARANCE; luego pasa a Water.

	Seguridad en vuelo (Settings.FLIGHT):
	- Piso duro: altura de la ola bajo los 4 puntos de flotacion, con la inclinacion del casco. Nunca se cruza, ni con ordenes de bajar.
	- Piso blando: lo mismo pero mirando hacia adelante en la trayectoria (posicion + velocidad * t, ola a la hora del servidor + t).
	  Se suaviza y su cambio esta limitado. Si la subida necesaria supera lo que puede el controlador, baja el limite de
	  velocidad y de inclinacion horizontales.
	- Techo: MAX_ALTITUDE sobre el nivel del mar (absoluto). Si la ola sube mas que el techo, la nave es arrastrada (Swept = true
	  y vuelve a Water): la ola gigante no se puede sobrevolar.
	- La ola gigante es periodica en Spacing (w se reduce modulo Spacing en Gerstner.ComputeGiantWave), asi que el salto de
	  GetGiantWaveCenter cada Spacing / Speed segundos no se nota y el muestreo hacia adelante es continuo al cruzarlo.
]]

local BoatManager = require(script.Parent.BoatManager)
local ZoneManager = require(script.Parent.ZoneManager)
local Settings = require(script.Parent.Parent.Settings)

local FLIGHT = Settings.FLIGHT
local SEA_LEVEL = Settings.GRID_SETTINGS.PLANE_OFFSET.Y -- // Y del mar en calma (las alturas de HeightLookup ya lo incluyen)

-- // Control
local MAX_SPEED = 200 -- // studs/s
local MAX_REVERSE_SPEED = 60 -- // studs/s (solo por deslizarse hacia atras en una pendiente)
local ACCELERATION = 20 -- // studs/s^2
local DECELERATION = 15 -- // studs/s^2
local TURN_RATE = math.rad(30) -- // rad/s

-- // Altura (flotacion)
local HEAVE_FREQ = 8 -- // rad/s. Mas alto = sigue la ola mas pegada
local HEAVE_DAMPING = 0.9 -- // 1 = sin rebote
local MAX_BUOYANT_ACCEL = 4 -- // Aceleracion maxima del agua, en veces la gravedad
local AIR_MARGIN = 3 -- // Studs sobre su altura de flotacion a partir de los cuales la nave deja de tocar el agua
local AIR_DRAG = 0.1 -- // 1/s. Resistencia del aire al caer

-- // Inclinacion
local TILT_FREQ = 5 -- // rad/s. Mas alto = se inclina mas rapido
local TILT_DAMPING = 0.8
local TILT_FOLLOW = 0.8 -- // Que fraccion de la pendiente de la ola copia la nave
local MAX_TILT = 0.7 -- // Inclinacion maxima (radianes)
local AIR_TILT_DAMPING = 0.5 -- // 1/s. Frenado de la rotacion mientras esta en el aire

-- // Pendiente
local SLOPE_GRAVITY = 0.6 -- // Fraccion de la gravedad que frena / acelera la nave en las pendientes

local RATE_PROBE = 0.1 -- // Segundos hacia el futuro para medir la velocidad vertical de la ola
local ZONE_REFRESH = 3 -- // Segundos entre busquedas de zona

local POINT_NAMES = { 'TopLeft', 'TopRight', 'BottomLeft', 'BottomRight' }

local BoatDrive = {}
BoatDrive.MAX_SPEED = MAX_SPEED

local function Average(Values: { number }, Indices: { number }): number
	local Sum = 0
	for _, i in Indices do
		Sum += Values[i]
	end
	return Sum / #Indices
end

-- // Crea el estado de la nave a partir de su posicion y orientacion actuales.
function BoatDrive.new(Boat: Model, Seat: VehicleSeat)
	local Main = Boat.Main

	-- // Posicion de los 4 puntos de flotacion en el espacio del asiento (constante, porque todo va soldado).
	local SeatToMain = Main.CFrame:ToObjectSpace(Seat.CFrame)
	local Offsets = {}
	local MeanX, MeanZ = 0, 0
	for i, Name in POINT_NAMES do
		Offsets[i] = SeatToMain:PointToObjectSpace(Main[Name].Position)
		MeanX += Offsets[i].X / 4
		MeanZ += Offsets[i].Z / 4
	end

	-- // Frente / atras / izquierda / derecha segun la posicion real de los puntos, sin depender de sus nombres.
	-- // El frente de la nave es -Z del asiento (su LookVector).
	local Front, Back, Left, Right = {}, {}, {}, {}
	for i = 1, 4 do
		table.insert(Offsets[i].Z < MeanZ and Front or Back, i)
		table.insert(Offsets[i].X > MeanX and Right or Left, i)
	end
	local Length, Width = 1, 1
	if #Front > 0 and #Back > 0 then
		local FrontZ, BackZ = 0, 0
		for _, i in Front do FrontZ += Offsets[i].Z / #Front end
		for _, i in Back do BackZ += Offsets[i].Z / #Back end
		Length = math.max(BackZ - FrontZ, 1)
	end
	if #Left > 0 and #Right > 0 then
		local LeftX, RightX = 0, 0
		for _, i in Left do LeftX += Offsets[i].X / #Left end
		for _, i in Right do RightX += Offsets[i].X / #Right end
		Width = math.max(RightX - LeftX, 1)
	end

	-- // Altura del punto de flotacion medio sobre el agua cuando la nave flota (referencia de "altura" en vuelo)
	local MeanY = 0
	for i = 1, 4 do
		MeanY += Offsets[i].Y / 4
	end

	local Look = Seat.CFrame.LookVector
	local Yaw = math.atan2(-Look.X, -Look.Z)
	local YawCF = CFrame.fromEulerAnglesXYZ(0, Yaw, 0)
	local Pitch, _, Roll = (YawCF:Inverse() * Seat.CFrame):ToEulerAnglesXYZ()
	local FlatLook = Vector3.new(Look.X, 0, Look.Z)

	return {
		Seat = Seat,
		Offsets = Offsets,
		FrontIndices = Front,
		BackIndices = Back,
		LeftIndices = Left,
		RightIndices = Right,
		Length = Length,
		Width = Width,
		BaseHeight = Main.Size.Y / 2,
		RestOffset = Main.Size.Y / 2 + MeanY, -- // Altura del punto de flotacion medio sobre su ola cuando flota (claridad 0)

		-- // Vuelo
		Mode = 'Water', -- // 'Water' | 'Takeoff' | 'Flight' | 'Landing' (ver el encabezado)
		Vel = Vector3.zero, -- // Velocidad horizontal en vuelo (mundo)
		AltTarget = Seat.Position.Y,
		FloorTarget = nil, -- // Piso blando suavizado (Y)
		PrevFloorTarget = nil,
		HardFloor = nil,
		Height = 0, -- // Altura media sobre la altura de flotacion (ultimo frame)
		SpeedScale = 1,
		TiltScale = 1,
		Overload = 0,
		LookTimer = math.huge,
		LookFloor = -math.huge,
		YawRate = 0,
		Swept = false, -- // true cuando la ola alcanzo el techo y la nave volvio a Water. El cliente lo borra
		Collective = 0,

		Position = Seat.Position,
		Yaw = Yaw,
		Speed = 0, -- // Velocidad hacia adelante (studs/s)
		VerticalSpeed = 0,
		Pitch = Pitch,
		Roll = Roll,
		PitchRate = 0,
		RollRate = 0,
		SlopeForward = 0,
		Flat = FlatLook.Magnitude > 0.01 and FlatLook.Unit or -Vector3.zAxis,
		CFrame = Seat.CFrame,

		ZoneInfo = {
			SpeedMultiplier = 1,
			PhaseMultiplier = 1,
			AmplitudeMultiplier = 1,
			CURRENT_ZONE = nil,
		},
		ZoneTimer = ZONE_REFRESH,
	}
end

function BoatDrive.UpdateZone(self)
	self.ZoneInfo.CURRENT_ZONE = ZoneManager:GetZoneParameters(self.Position)
end

local function UpdateZoneMultipliers(self, Position: Vector3)
	local Info = self.ZoneInfo
	local Zone = Info.CURRENT_ZONE
	if Zone == nil then
		Info.SpeedMultiplier, Info.PhaseMultiplier, Info.AmplitudeMultiplier = 1, 1, 1
	elseif Zone.Type ~= 'Whirlpool' then
		if Zone.Link then
			Info.SpeedMultiplier, Info.PhaseMultiplier, Info.AmplitudeMultiplier = ZoneManager:GetZoneMultipliers(Position, Zone.Link.Position, Zone)
		else
			Info.SpeedMultiplier, Info.PhaseMultiplier, Info.AmplitudeMultiplier = ZoneManager:GetIslandMultipliers(Position, Zone.Island.Center.Position, Zone.Radius / 2)
		end
	end
end

-- // Zona y multiplicadores de la ola en Position (se busca la zona cada ZONE_REFRESH segundos)
local function RefreshZone(self, Position: Vector3, dt: number)
	self.ZoneTimer += dt
	if self.ZoneTimer >= ZONE_REFRESH then
		self.ZoneTimer = 0
		self.ZoneInfo.CURRENT_ZONE = ZoneManager:GetZoneParameters(Position)
	end
	UpdateZoneMultipliers(self, Position)
end

-- ============================================================
--  VUELO
-- ============================================================

local ALL = { 1, 2, 3, 4 }

local function Smoothstep01(x: number): number
	local u = math.clamp(x, 0, 1)
	return u * u * (3 - 2 * u)
end

-- // Sube rapido o lento segun el sentido (los limites bajan rapido y se recuperan despacio)
local function Approach(Current: number, Target: number, dt: number, Attack: number, Release: number): number
	local Tau = if Target < Current then Attack else Release
	return Current + (Target - Current) * (1 - math.exp(-dt / Tau))
end

-- // Techo absoluto de vuelo (Y). No depende de la ola: la ola gigante no se puede sobrevolar.
local function Ceiling(): number
	return SEA_LEVEL + FLIGHT.MAX_ALTITUDE
end
BoatDrive.GetCeiling = Ceiling

-- // Claridad minima de los puntos de flotacion segun el modo. Cerca del agua (Takeoff / Landing) el piso es el de
-- // despegue / aterrizaje; en Flight es MIN_CLEARANCE.
local function ClearanceFor(Mode: string): number
	if Mode == 'Takeoff' then
		return FLIGHT.LIFTOFF_CLEARANCE
	elseif Mode == 'Landing' then
		return FLIGHT.TOUCHDOWN_CLEARANCE
	end
	return FLIGHT.MIN_CLEARANCE
end
BoatDrive.ClearanceFor = ClearanceFor

-- // Altura de la ola bajo los 4 puntos del casco (con su inclinacion) y Y de cada punto respecto al centro.
-- // Rotation: CFrame con la orientacion de la nave (puede incluir posicion, se ignora).
local function SampleHull(self, Position: Vector3, Rotation: CFrame, TimeOffset: number, Shift: Vector3?)
	local Points, Dy = {}, {}
	for i = 1, 4 do
		local Relative = Rotation:VectorToWorldSpace(self.Offsets[i])
		Dy[i] = Relative.Y
		Points[i] = { WorldPosition = Position + Relative }
	end
	return BoatManager.SampleHeights(Points, self.ZoneInfo, TimeOffset, Shift), Dy
end

-- // Y minima del centro de la nave para que ningun punto de flotacion quede a menos de Clearance sobre su ola
local function FloorFrom(self, Heights: { number }, Dy: { number }, Clearance: number): number
	local Floor = -math.huge
	for i = 1, 4 do
		local Required = Heights[i] + Clearance + self.RestOffset - Dy[i]
		if Required > Floor then
			Floor = Required
		end
	end
	return Floor
end

-- // Cambia de modo conservando el movimiento. El servidor decide el modo; el cliente lo copia.
function BoatDrive.SetMode(self, Mode: string)
	local Previous = self.Mode
	if Previous == Mode then
		return
	end
	self.Mode = Mode
	if Previous == 'Water' then
		self.Vel = self.Flat * self.Speed
		self.AltTarget = self.Position.Y
		self.FloorTarget, self.PrevFloorTarget, self.HardFloor = nil, nil, nil
		self.LookFloor = -math.huge
		self.LookTimer = math.huge
		self.SpeedScale, self.TiltScale, self.Overload = 1, 1, 0
		self.YawRate = 0
		self.Swept = false
	elseif Mode == 'Water' then
		self.Speed = math.clamp(self.Vel:Dot(self.Flat), -MAX_REVERSE_SPEED, MAX_SPEED)
		self.Vel = Vector3.zero
		self.Contact = nil
	end
end

local function StepFlight(self, dt: number, Throttle: number, Steer: number, Input)
	local Mode = self.Mode
	local Landing = Mode == 'Landing'
	local Takeoff = Mode == 'Takeoff'
	local Strafe = if Input then Input.Strafe or 0 else 0
	local Collective = if Input then Input.Collective or 0 else 0
	self.Collective = Collective

	-- // 1. Guinada (rumbo)
	local YawRateTarget = -Steer * FLIGHT.TURN_RATE
	self.YawRate += (YawRateTarget - self.YawRate) * (1 - math.exp(-dt / FLIGHT.YAW_SMOOTH))
	self.Yaw += self.YawRate * dt
	local YawCF = CFrame.fromEulerAnglesXYZ(0, self.Yaw, 0)
	local Flat, Right = YawCF.LookVector, YawCF.RightVector
	self.Flat = Flat

	-- // 2. Autoridad horizontal: 0 por debajo de GATE_HEIGHT, 1 a GATE_HEIGHT + GATE_BLEND (con la altura del frame anterior).
	-- // Al aterrizar ademas baja la inclinacion y el limite de velocidad, mas cuanto mas cerca del agua.
	local Authority = Smoothstep01((self.Height - FLIGHT.GATE_HEIGHT) / FLIGHT.GATE_BLEND)
	local LandTilt, LandSpeed = 1, 1
	if Landing then
		LandTilt = FLIGHT.LAND_TILT_SCALE
		local Near = math.clamp(self.Height / FLIGHT.GATE_HEIGHT, 0, 1)
		LandSpeed = FLIGHT.LAND_MIN_SPEED_SCALE + (FLIGHT.LAND_SPEED_SCALE - FLIGHT.LAND_MIN_SPEED_SCALE) * Near
	end

	-- // 3. Muestreo hacia adelante a lo largo de la trayectoria (cada LOOK_INTERVAL).
	-- // Mira donde estara la nave (posicion + velocidad * t) y donde estara la ola (hora del servidor + t), asi tambien
	-- // ve venir olas que avanzan hacia la nave. Si la subida necesaria supera lo que puede el controlador, baja los limites.
	self.LookTimer += dt
	if self.LookTimer >= FLIGHT.LOOK_INTERVAL then
		self.LookTimer = 0
		local Direction = Flat * Throttle + Right * Strafe
		if Direction.Magnitude > 1 then
			Direction = Direction.Unit
		end
		local Projected = self.Vel + Direction * (FLIGHT.MAX_SPEED * 0.5 * Authority)
		if Projected.Magnitude > FLIGHT.MAX_SPEED * 1.1 then
			Projected = Projected.Unit * (FLIGHT.MAX_SPEED * 1.1)
		end

		local Clearance = ClearanceFor(Mode) + (if Mode == 'Flight' then FLIGHT.LOOK_MARGIN else 0)
		local Limit = FLIGHT.MAX_CLIMB_RATE * FLIGHT.LOOK_RATE_FRACTION
		local Rotation = YawCF * CFrame.fromEulerAnglesXYZ(self.Pitch, 0, self.Roll)
		local Overload, FloorMax = 0, -math.huge
		for _, Tau in FLIGHT.LOOKAHEAD_TIMES do
			local Heights, Dy = SampleHull(self, self.Position, Rotation, Tau, Projected * Tau)
			if Heights ~= nil then
				local Required = FloorFrom(self, Heights, Dy, Clearance)
				FloorMax = math.max(FloorMax, Required)
				Overload = math.max(Overload, (Required - self.Position.Y) / Tau / Limit)
			end
		end
		self.LookFloor, self.Overload = FloorMax, Overload
	end

	local ScaleBase = 1 / math.max(self.Overload, 1)
	self.SpeedScale = Approach(self.SpeedScale, math.clamp(ScaleBase, FLIGHT.MIN_SPEED_SCALE, 1), dt, FLIGHT.SCALE_ATTACK, FLIGHT.SCALE_RELEASE)
	self.TiltScale = Approach(self.TiltScale, math.clamp(ScaleBase, FLIGHT.MIN_TILT_SCALE, 1), dt, FLIGHT.SCALE_ATTACK, FLIGHT.SCALE_RELEASE)

	-- // 4. Piso blando: objetivo de altura minima. Suavizado y con tope a su velocidad de cambio, para que el controlador
	-- // pueda seguirlo (TARGET_RISE_RATE <= MAX_CLIMB_RATE). El piso duro (abajo) no se suaviza.
	local FloorGoal = math.max(self.LookFloor, self.HardFloor or -math.huge)
	if self.FloorTarget == nil then
		-- // Arranca desde la altura actual: el objetivo sube con su tope de velocidad y no tira de la nave de golpe
		self.FloorTarget = if FloorGoal > -math.huge then math.min(FloorGoal, self.Position.Y) else self.Position.Y - 100
	end
	if FloorGoal == -math.huge then
		FloorGoal = self.FloorTarget
	end
	local FloorCurrent = self.FloorTarget
	local FloorSmoothed = FloorCurrent + (FloorGoal - FloorCurrent) * (1 - math.exp(-dt / FLIGHT.TARGET_SMOOTH))
	local FloorStep = math.clamp(FloorSmoothed - FloorCurrent, -FLIGHT.TARGET_FALL_RATE * dt, FLIGHT.TARGET_RISE_RATE * dt)
	self.PrevFloorTarget = FloorCurrent
	self.FloorTarget = FloorCurrent + FloorStep

	-- // 5. Inclinacion y aceleracion horizontal. Cabeceo (W / S) y alabeo (Q / E) piden inclinacion; la aceleracion sale de la
	-- // inclinacion real del casco (con inercia). Nariz abajo (pitch < 0) = adelante; lado derecho abajo (roll < 0) = derecha.
	local TiltAuthority = Authority * self.TiltScale * LandTilt
	local SpeedCap = FLIGHT.MAX_SPEED * self.SpeedScale * LandSpeed * Authority
	local Soft = SpeedCap * 0.08 + 1 -- // Rango en el que el comando se apaga al acercarse al limite (alcanza MAX_SPEED casi entero)
	local Vf, Vr = self.Vel:Dot(Flat), self.Vel:Dot(Right)

	local function InputTilt(Command: number, Speed: number): number
		-- // El comando se apaga al acercarse al limite de velocidad en su misma direccion
		local Room = math.clamp((SpeedCap - Speed * math.sign(Command)) / Soft, 0, 1)
		return -Command * FLIGHT.MAX_TILT * TiltAuthority * Room
	end
	local function BrakeTilt(Speed: number): number
		-- // Sobre el limite (por ejemplo, la ola de adelante lo bajo de golpe) inclina al reves para frenar
		local Over = math.abs(Speed) - SpeedCap
		if Over <= 0 then
			return 0
		end
		return math.sign(Speed) * math.min(Over * FLIGHT.BRAKE_GAIN, FLIGHT.MAX_TILT * FLIGHT.BRAKE_TILT_FRACTION) * Authority * LandTilt
	end

	local PitchCommand = math.clamp(InputTilt(Throttle, Vf) + BrakeTilt(Vf), -FLIGHT.MAX_TILT, FLIGHT.MAX_TILT)
	local RollCommand = math.clamp(InputTilt(Strafe, Vr) + BrakeTilt(Vr), -FLIGHT.MAX_TILT, FLIGHT.MAX_TILT)

	local Freq, Damping = FLIGHT.TILT_FREQ, FLIGHT.TILT_DAMPING
	self.PitchRate += (Freq * Freq * (PitchCommand - self.Pitch) - 2 * Damping * Freq * self.PitchRate) * dt
	self.RollRate += (Freq * Freq * (RollCommand - self.Roll) - 2 * Damping * Freq * self.RollRate) * dt
	local TiltLimit = FLIGHT.MAX_TILT * 1.2
	self.Pitch = math.clamp(self.Pitch + self.PitchRate * dt, -TiltLimit, TiltLimit)
	self.Roll = math.clamp(self.Roll + self.RollRate * dt, -TiltLimit, TiltLimit)

	local AccelForward = -FLIGHT.HORIZ_ACCEL_MAX * (self.Pitch / FLIGHT.MAX_TILT) * Authority
	local AccelRight = -FLIGHT.HORIZ_ACCEL_MAX * (self.Roll / FLIGHT.MAX_TILT) * Authority
	local Drag = FLIGHT.HORIZ_ACCEL_MAX / FLIGHT.MAX_SPEED
	local Vel = self.Vel + (Flat * AccelForward + Right * AccelRight - self.Vel * Drag) * dt
	local HardSpeed = FLIGHT.MAX_SPEED * 1.05
	if Vel.Magnitude > HardSpeed then
		Vel = Vel.Unit * HardSpeed
	end
	self.Vel = Vel
	local Pos = self.Position + Vel * dt

	-- // 6. Ola bajo los 4 puntos con la inclinacion nueva, en la posicion nueva: piso duro
	local Rotation = YawCF * CFrame.fromEulerAnglesXYZ(self.Pitch, 0, self.Roll)
	RefreshZone(self, Pos, dt)
	local Now, Dy = SampleHull(self, Pos, Rotation, 0, nil)
	local HardFloor = self.HardFloor
	local Surface = nil
	if Now ~= nil then
		HardFloor = FloorFrom(self, Now, Dy, ClearanceFor(Mode))
		self.HardFloor = HardFloor
		Surface = Average(Now, ALL)
	end

	-- // 7. Altura (colectivo). La altitud objetivo la mueve la orden; se limita entre el piso blando y el techo, asi una
	-- // orden de bajar nunca cruza el limite de seguridad.
	local Ceil = Ceiling()
	local Rate = 0
	if Takeoff then
		Rate = if self.Height < FLIGHT.GATE_HEIGHT + FLIGHT.TAKEOFF_EXTRA then FLIGHT.TAKEOFF_CLIMB_RATE else 0
	elseif Landing then
		Rate = -math.clamp(self.Height * FLIGHT.LAND_RATE_PER_HEIGHT, FLIGHT.LAND_MIN_RATE, FLIGHT.LAND_MAX_RATE)
	elseif Collective > 0 then
		Rate = FLIGHT.MAX_CLIMB_RATE
	elseif Collective < 0 then
		Rate = -FLIGHT.MAX_DESCENT_RATE
	end
	local Alt = math.clamp(self.AltTarget + Rate * dt, Pos.Y - FLIGHT.ALT_LEAD, Pos.Y + FLIGHT.ALT_LEAD)
	local SoftFloor = self.FloorTarget
	Alt = math.min(math.max(Alt, math.min(SoftFloor, Ceil)), Ceil)
	self.AltTarget = Alt

	local FloorRate = (self.FloorTarget - self.PrevFloorTarget) / dt
	local DesiredRate = math.clamp(FLIGHT.ALT_GAIN * (Alt - Pos.Y), -FLIGHT.MAX_DESCENT_RATE, FLIGHT.MAX_CLIMB_RATE)
	if Alt <= SoftFloor + 0.5 and FloorRate > 0 then
		DesiredRate = math.min(DesiredRate + FloorRate, FLIGHT.MAX_CLIMB_RATE) -- // Pegado al piso blando: acompana su subida
	end
	local Accel = math.clamp(FLIGHT.VERT_GAIN * (DesiredRate - self.VerticalSpeed), -FLIGHT.MAX_DOWN_ACCEL, FLIGHT.MAX_UP_ACCEL)
	self.VerticalSpeed += Accel * dt
	local Y = Pos.Y + self.VerticalSpeed * dt

	-- // 8. Piso duro y techo. Si la ola sube por encima del techo, la nave es arrastrada (vuelve a Water).
	local Swept = false
	if HardFloor ~= nil then
		if HardFloor > Ceil + FLIGHT.SWEPT_TOLERANCE then
			Swept = true
		elseif Y < HardFloor then
			Y = HardFloor
			self.VerticalSpeed = math.max(self.VerticalSpeed, 0)
		end
	end
	if not Swept and Y > Ceil then
		Y = Ceil
		self.VerticalSpeed = math.min(self.VerticalSpeed, 0)
	end

	Pos = Vector3.new(Pos.X, Y, Pos.Z)
	self.Position = Pos
	if Surface ~= nil then
		self.Height = Y - Surface - self.BaseHeight
	end
	self.CFrame = CFrame.new(Pos) * Rotation

	if Swept then
		self.Swept = true
		BoatDrive.SetMode(self, 'Water')
	end
end

-- // Mide el casco en un CFrame del asiento: altura media sobre la altura de flotacion, claridad del punto mas bajo y si la
-- // ola ya supera el techo. Lo usa el servidor para validar el vuelo. nil si no se pudo leer la ola.
function BoatDrive.Measure(self, CF: CFrame, dt: number?)
	RefreshZone(self, CF.Position, dt or 0)
	local Heights, Dy = SampleHull(self, CF.Position, CF, 0, nil)
	if Heights == nil then
		return nil
	end
	local Y = CF.Position.Y
	local MinClearance = math.huge
	for i = 1, 4 do
		MinClearance = math.min(MinClearance, Y + Dy[i] - Heights[i] - self.RestOffset)
	end
	local Floor = FloorFrom(self, Heights, Dy, FLIGHT.MIN_CLEARANCE)
	return {
		Height = Y - Average(Heights, ALL) - self.BaseHeight,
		MinClearance = MinClearance,
		Floor = Floor,
		Swept = Floor > Ceiling() + FLIGHT.SWEPT_TOLERANCE,
	}
end

function BoatDrive.NewTrack()
	return { LastPos = nil, LastHorizontal = nil, Strikes = 0, Airborne = 0 }
end

-- // Olvida las muestras anteriores (al cambiar de modo la velocidad cambia de golpe)
function BoatDrive.ResetTrack(Track)
	Track.LastPos, Track.LastHorizontal = nil, nil
end

-- // Comprobacion del servidor cada FLIGHT.VALIDATE_INTERVAL segundos, con el CFrame que el piloto replica.
-- // Devuelve (motivo de infraccion o nil, medicion). Mide limites de estado y de fuerzas (velocidad, aceleracion horizontal,
-- // velocidad vertical, techo y claridad); el servidor decide que hacer con las infracciones.
function BoatDrive.Validate(self, Track, Interval: number, CF: CFrame, Mode: string): (string?, { [string]: any }?)
	local Measure = BoatDrive.Measure(self, CF, Interval)
	local Position = CF.Position
	local Velocity = if Track.LastPos then (Position - Track.LastPos) / Interval else nil
	Track.LastPos = Position
	if Measure == nil then
		return nil, nil
	end

	local Tolerance = FLIGHT.SERVER_TOLERANCE
	local Horizontal = if Velocity then Vector3.new(Velocity.X, 0, Velocity.Z) else nil
	local LastHorizontal = Track.LastHorizontal
	Track.LastHorizontal = Horizontal

	if Mode == 'Water' then
		-- // Sin vuelo concedido no deberia estar muy por encima de la ola (las crestas rapidas lo lanzan unos studs)
		Track.Airborne = if Measure.Height > FLIGHT.UNAUTHORIZED_HEIGHT then Track.Airborne + 1 else 0
		if Track.Airborne >= 2 then
			return 'unauthorized', Measure
		end
		return nil, Measure
	end
	Track.Airborne = 0

	if Position.Y > Ceiling() + FLIGHT.CEILING_TOLERANCE then
		return 'ceiling', Measure
	end
	if not Measure.Swept and Measure.MinClearance < ClearanceFor(Mode) - FLIGHT.CLEARANCE_TOLERANCE then
		return 'clearance', Measure
	end
	if Horizontal ~= nil then
		if Horizontal.Magnitude > FLIGHT.MAX_SPEED * Tolerance then
			return 'speed', Measure
		end
		if LastHorizontal ~= nil and (Horizontal - LastHorizontal).Magnitude / Interval > FLIGHT.HORIZ_ACCEL_MAX * Tolerance then
			return 'accel', Measure
		end
	end
	if Velocity ~= nil then
		-- // Subir mas rapido que el controlador solo es valido si la ola lo empuja (pegado al piso)
		local ForcedByWave = Measure.MinClearance < ClearanceFor(Mode) + 6
		if Velocity.Y > FLIGHT.MAX_CLIMB_RATE * Tolerance and not ForcedByWave then
			return 'climb', Measure
		end
		if Velocity.Y < -FLIGHT.MAX_DESCENT_RATE * Tolerance then
			return 'descent', Measure
		end
	end
	return nil, Measure
end

-- // Avanza la nave dt segundos. Throttle y Steer son los del VehicleSeat (-1, 0 o 1).
-- // Idle = true para la nave vacia: no se desliza por las pendientes.
-- // Input (opcional, solo vuelo): { Strafe = -1..1 (alabeo), Collective = -1..1 (subir / bajar) }.
function BoatDrive.Step(self, dt: number, Throttle: number, Steer: number, Idle: boolean?, Input: { Strafe: number?, Collective: number? }?)
	dt = math.min(dt, 0.05)
	if self.Mode ~= 'Water' then
		StepFlight(self, dt, Throttle, Steer, Input)
		return
	end
	local Gravity = workspace.Gravity

	-- // Giro
	if Steer == 1 then
		self.Yaw -= TURN_RATE * dt
	elseif Steer == -1 then
		self.Yaw += TURN_RATE * dt
	end
	local YawCF = CFrame.fromEulerAnglesXYZ(0, self.Yaw, 0)
	local Flat = YawCF.LookVector
	self.Flat = Flat

	-- // Velocidad: motor, rozamiento y pendiente (la pendiente se mide el frame anterior)
	local Speed = self.Speed
	if Throttle == 1 then
		Speed = math.min(Speed + ACCELERATION * dt, math.max(Speed, MAX_SPEED))
	else
		local Drag = DECELERATION * dt
		if Speed > Drag then
			Speed -= Drag
		elseif Speed < -Drag then
			Speed += Drag
		else
			Speed = 0
		end
	end
	if Idle then
		Speed = 0
	else
		-- // En pendiente sube = -; la nave pierde velocidad subiendo y la gana bajando (solo si toca el agua)
		local SlopeSin = self.SlopeForward / math.sqrt(1 + self.SlopeForward * self.SlopeForward)
		Speed -= SLOPE_GRAVITY * Gravity * SlopeSin * (self.Contact or 1) * dt
	end
	Speed = math.clamp(Speed, -MAX_REVERSE_SPEED, MAX_SPEED)
	self.Speed = Speed

	-- // Avance horizontal
	local Pos = self.Position + Flat * (Speed * dt)
	self.Position = Pos

	RefreshZone(self, Pos, dt)

	-- // Altura de la ola bajo los 4 puntos del casco, en la posicion nueva
	local Rotation = YawCF * CFrame.fromEulerAnglesXYZ(self.Pitch, 0, self.Roll)
	local Points = {}
	for i = 1, 4 do
		Points[i] = { WorldPosition = Pos + Rotation:VectorToWorldSpace(self.Offsets[i]) }
	end

	local Now = BoatManager.SampleHeights(Points, self.ZoneInfo, 0)
	if Now ~= nil then
		-- // Velocidad vertical de la ola en el punto al que va la nave (movimiento de la ola + pendiente que cruza)
		local Probe = BoatManager.SampleHeights(Points, self.ZoneInfo, RATE_PROBE, Flat * (Speed * RATE_PROBE)) or Now
		local All = { 1, 2, 3, 4 }
		local SurfaceHeight = Average(Now, All)
		local SurfaceRate = (Average(Probe, All) - SurfaceHeight) / RATE_PROBE

		local SlopeForward = (Average(Now, self.FrontIndices) - Average(Now, self.BackIndices)) / self.Length
		local SlopeSide = (Average(Now, self.RightIndices) - Average(Now, self.LeftIndices)) / self.Width
		self.SlopeForward = SlopeForward

		-- // Altura: resorte amortiguado hacia la superficie mientras toca el agua; caida libre si la pierde
		local Offset = SurfaceHeight + self.BaseHeight - Pos.Y -- // > 0: la nave esta por debajo de su altura de flotacion
		local Contact = math.clamp(1 + Offset / AIR_MARGIN, 0, 1)
		self.Contact = Contact

		local Spring = HEAVE_FREQ * HEAVE_FREQ * Offset + 2 * HEAVE_DAMPING * HEAVE_FREQ * (SurfaceRate - self.VerticalSpeed)
		local MaxAccel = MAX_BUOYANT_ACCEL * Gravity
		Spring = math.clamp(Spring, -MaxAccel, MaxAccel)
		local Fall = -Gravity - AIR_DRAG * self.VerticalSpeed
		local VerticalAccel = Spring * Contact + Fall * (1 - Contact)

		self.VerticalSpeed += VerticalAccel * dt
		Pos = Vector3.new(Pos.X, Pos.Y + self.VerticalSpeed * dt, Pos.Z)
		self.Position = Pos

		-- // Inclinacion: sigue la pendiente de la ola con inercia; en el aire conserva la rotacion
		local PitchTarget = math.clamp(math.atan(SlopeForward) * TILT_FOLLOW, -MAX_TILT, MAX_TILT)
		local RollTarget = math.clamp(math.atan(SlopeSide) * TILT_FOLLOW, -MAX_TILT, MAX_TILT)
		local Air = 1 - Contact

		local PitchAccel = TILT_FREQ * TILT_FREQ * (PitchTarget - self.Pitch) - 2 * TILT_DAMPING * TILT_FREQ * self.PitchRate
		local RollAccel = TILT_FREQ * TILT_FREQ * (RollTarget - self.Roll) - 2 * TILT_DAMPING * TILT_FREQ * self.RollRate
		PitchAccel = PitchAccel * Contact - AIR_TILT_DAMPING * self.PitchRate * Air
		RollAccel = RollAccel * Contact - AIR_TILT_DAMPING * self.RollRate * Air

		self.PitchRate += PitchAccel * dt
		self.RollRate += RollAccel * dt
		self.Pitch = math.clamp(self.Pitch + self.PitchRate * dt, -MAX_TILT * 1.3, MAX_TILT * 1.3)
		self.Roll = math.clamp(self.Roll + self.RollRate * dt, -MAX_TILT * 1.3, MAX_TILT * 1.3)
	end

	self.CFrame = CFrame.new(Pos) * YawCF * CFrame.fromEulerAnglesXYZ(self.Pitch, 0, self.Roll)
end

-- // Coloca la nave (a traves del VehicleSeat, todo lo soldado se mueve con el).
function BoatDrive.Apply(self)
	local Seat = self.Seat
	Seat.CFrame = self.CFrame
	-- // La velocidad se indica para que los demas jugadores vean la nave extrapolada con suavidad.
	local Horizontal = if self.Mode == 'Water' then self.Flat * self.Speed else self.Vel
	Seat.AssemblyLinearVelocity = Horizontal + Vector3.new(0, self.VerticalSpeed, 0)
	Seat.AssemblyAngularVelocity = Vector3.zero
end

return BoatDrive
