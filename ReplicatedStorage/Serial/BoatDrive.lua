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
local Gerstner = require(script.Parent.Parent)

local FLIGHT = Settings.FLIGHT
local BM = Settings.BOAT_MOTION -- // v21: peso, balanceo, marea y bloqueo en la ola gigante
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
local TILT_FREQ = 10 -- // rad/s. Mas alto = se inclina mas rapido (v16: antes 5, se quedaba atras en la ola gigante)
local TILT_DAMPING = 0.85
local TILT_FOLLOW = 1 -- // Que fraccion de la pendiente de la ola copia la nave (v16: 1 = la misma inclinacion)
local MAX_TILT = 1.1 -- // Inclinacion maxima (radianes). v16: la ola gigante llega a ~1.05 rad de pendiente (antes 0.7)
local AIR_TILT_DAMPING = 0.5 -- // 1/s. Frenado de la rotacion mientras esta en el aire

-- // Pendiente
local SLOPE_GRAVITY = 0.6 -- // Fraccion de la gravedad que frena / acelera la nave en las pendientes
local SLOPE_DOWNHILL_SCALE = 0 -- // v16: fraccion de esa fuerza que SUMA velocidad al bajar una ola (0 = la ola solo frena, nunca acelera)
local HULL_CLEARANCE = -1.5 -- // v16: studs que un punto de flotacion puede hundirse bajo su nivel de flotacion (colision con la ola)

-- // v17: aterrizaje suave. Al pasar de vuelo a agua, la nave baja con velocidad proporcional a su altura (sin caida libre)
local SOFT_LAND_GAIN = 1.2 -- // 1/s: velocidad de descenso = altura sobre el agua * esto
local SOFT_LAND_MIN_FALL = 2 -- // studs/s: velocidad minima de descenso (para que llegue a tocar)
local SOFT_LAND_MAX_FALL = 12 -- // studs/s: velocidad maxima de descenso
local SOFT_LAND_TIMEOUT = 4 -- // s: tope del aterrizaje suave

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

-- // Promedio de la posicion de los puntos indicados proyectada sobre un eje (para medir la separacion horizontal real)
local function AverageAlong(Points, Indices: { number }, Axis: Vector3): number
	local Sum = 0
	for _, i in Indices do
		Sum += Points[i].WorldPosition:Dot(Axis)
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
	local MaxDrop = 0 -- // Cuanto mas bajo que el promedio esta el punto mas bajo (para no elevar la nave en reposo)
	for i = 1, 4 do
		MaxDrop = math.max(MaxDrop, MeanY - Offsets[i].Y)
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
		FloorSlack = HULL_CLEARANCE - MaxDrop, -- // v16: claridad minima del piso duro en agua
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
		-- // v14: palanca virtual (-1..1). Las teclas son digitales; la nave responde a la palanca, no a la tecla
		StickBrake = 0, -- // v17: S (freno; en vuelo no hay marcha atras)
		SoftLand = false, -- // v17: aterrizaje suave activo (Water recien llegado de vuelo)
		SoftLandTime = 0,
		HoverGain = 0, -- // v19: suspension visual en el aire (0 a 1)
		Rough = 0, -- // v19: sacudidas visuales en la ola gigante (0 a 1)
		StickRoll = 0, -- // A / D (alabeo)
		StickBoost = 0, -- // W / S (propulsores principales)
		StickCollective = 0,
		GiantLock = 0, -- // v21: 0 a 1, cuanto la ola gigante ha apagado el motor y arrastra la nave
		SwayGain = 0, -- // v21: balanceo visual en el agua (0 a 1)
		SteerSmooth = 0, -- // v21: giro suavizado (para inclinar la nave al virar)
		AccelSmooth = 0, -- // v21: aceleracion suavizada (nariz arriba al acelerar)
		PrevSpeed = 0,

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

-- // v14: mueve la palanca virtual hacia la orden con velocidad limitada. Al soltar (orden 0) vuelve al centro con Return.
local function Stick(Current: number, Target: number, dt: number, Rise: number, Return: number): number
	local Rate = if Target == 0 then Return else Rise
	local Step = Rate * dt
	return Current + math.clamp(Target - Current, -Step, Step)
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

-- // v19: movimiento SOLO visual: se aplica al CFrame final, no a la fisica (Pitch / Roll / Position / pisos no lo ven).
-- // * Suspension: casi quieta en el aire, la nave se balancea y sube / baja muy poco, como si los gases la estabilizaran.
-- // * Motores: vibracion fina que crece con la velocidad.
-- // * Ola gigante: sacudidas bruscas segun lo alta que sea la ola bajo la nave.
local HOVER = FLIGHT.HOVER_MOTION
local JOLT = FLIGHT.WAVE_JOLT
local GIANT_HEIGHT = Gerstner.GIANT_CONFIG.Height

local function RangeSmooth(a: number, b: number, x: number): number
	local u = math.clamp((x - a) / (b - a), 0, 1)
	return u * u * (3 - 2 * u)
end

local function VisualMotion(self, Pos: Vector3, dt: number): (Vector3, CFrame)
	local Flying = self.Mode ~= 'Water'
	local Horizontal = if Flying then Vector3.new(self.Vel.X, 0, self.Vel.Z).Magnitude else math.abs(self.Speed)

	local HoverTarget = if Flying then 1 - math.clamp(Horizontal / HOVER.CALM_SPEED, 0, 1) else 0
	self.HoverGain += (HoverTarget - self.HoverGain) * (1 - math.exp(-dt / 0.6))

	local Fraction = Gerstner.ComputeGiantWave(Pos, workspace:GetServerTimeNow()).Y / GIANT_HEIGHT
	self.Rough += (RangeSmooth(JOLT.START, JOLT.FULL, Fraction) - self.Rough) * (1 - math.exp(-dt / 0.35))

	local c = os.clock()
	local Pitch, Roll, Yaw, Bob = 0, 0, 0, 0
	local H = self.HoverGain
	if H > 0.001 then
		local f = HOVER.FREQ
		Pitch += H * HOVER.PITCH * (math.noise(c * f, 1.3) * 1.4 + 0.5 * math.noise(c * f * 3.1, 7.7))
		Roll += H * HOVER.ROLL * (math.noise(c * f, 5.9) * 1.4 + 0.5 * math.noise(c * f * 2.7, 3.3))
		Yaw += H * HOVER.YAW * math.noise(c * f * 0.8, 9.1) * 1.4
		Bob += H * HOVER.BOB * math.noise(c * f * 1.3, 2.2) * 1.4
	end
	if Flying then
		local Vibration = HOVER.VIBRATION * math.clamp(Horizontal / FLIGHT.MAX_SPEED, 0, 1)
		Pitch += Vibration * math.noise(c * 31, 4.4) * 1.4
		Roll += Vibration * math.noise(c * 29, 8.8) * 1.4
	end
	-- // v21: en el agua la nave se balancea con el mar, se inclina al virar y cabecea al acelerar / frenar
	if not Flying then
		local SpeedRatio = math.clamp(math.abs(self.Speed) / MAX_SPEED, 0, 1)
		local SwayTarget = 1 - (1 - BM.SWAY.UNDERWAY) * SpeedRatio
		self.SwayGain += (SwayTarget - self.SwayGain) * (1 - math.exp(-dt / 0.8))
		local S, f = self.SwayGain, BM.SWAY.FREQ
		Pitch += S * BM.SWAY.PITCH * (math.noise(c * f, 21.1) * 1.4 + 0.4 * math.noise(c * f * 2.3, 4.2))
		Roll += S * BM.SWAY.ROLL * (math.noise(c * f * 0.9, 15.5) * 1.4 + 0.6 * math.sin(c * f * 2 * math.pi))
		Yaw += S * BM.SWAY.YAW * math.noise(c * f * 0.7, 33.3) * 1.4
		Bob += S * BM.SWAY.BOB * math.noise(c * f * 1.2, 41.7) * 1.4
		Roll -= self.SteerSmooth * BM.BANK * SpeedRatio -- // lado derecho abajo al virar a la derecha
		Pitch += BM.SQUAT * math.clamp(self.AccelSmooth / ACCELERATION, -1, 1)
	else
		self.SwayGain = 0
	end
	local R = self.Rough
	if R > 0.001 then
		-- // Señal puntiaguda (n * |n|): reposo con golpes secos en vez de un vaiven suave
		local function Spike(Seed: number): number
			local n = math.noise(c * JOLT.FREQ, Seed) * 1.4
			return n * math.abs(n) * 2
		end
		Pitch += R * JOLT.PITCH * Spike(10.1)
		Roll += R * JOLT.ROLL * Spike(20.2)
		Bob += R * JOLT.BOB * Spike(30.3)
	end
	return Vector3.new(0, Bob, 0), CFrame.Angles(Pitch, Yaw, Roll)
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
		self.StickBrake, self.StickRoll, self.StickBoost, self.StickCollective = 0, 0, 0, 0 -- // v14
	elseif Mode == 'Water' then
		self.Speed = math.clamp(self.Vel:Dot(self.Flat), -MAX_REVERSE_SPEED, MAX_SPEED)
		self.Vel = Vector3.zero
		self.Contact = nil
		self.SoftLand, self.SoftLandTime = true, 0 -- // v17: baja suave hasta tocar el agua (si ya esta bajo la ola, se apaga solo)
	end
end

local function StepFlight(self, dt: number, Throttle: number, Steer: number, Input)
	local Mode = self.Mode
	local Landing = Mode == 'Landing'
	local Takeoff = Mode == 'Takeoff'
	-- // v14: las ordenes (teclas) pasan por la palanca virtual antes de usarse
	-- // v17: W = propulsores principales (solo adelante), S = freno (no hay marcha atras en vuelo), A / D = alabeo,
	-- // Q / E = subir / bajar (Collective). En vuelo no hay tecla de guinada: el alabeo hace virar la nave.
	local RollInput = if Input then Input.Roll or 0 else 0
	self.StickBrake = Stick(self.StickBrake, math.max(-Throttle, 0), dt, FLIGHT.STICK_RISE, FLIGHT.STICK_RETURN)
	self.StickRoll = Stick(self.StickRoll, RollInput, dt, FLIGHT.STICK_RISE, FLIGHT.STICK_RETURN)
	self.StickBoost = Stick(self.StickBoost, math.max(Throttle, 0), dt, FLIGHT.STICK_RISE, FLIGHT.STICK_RETURN) -- // W: propulsores
	self.StickCollective = Stick(self.StickCollective, if Input then Input.Collective or 0 else 0, dt, FLIGHT.COLLECTIVE_RISE, FLIGHT.COLLECTIVE_RETURN)
	local Roll = self.StickRoll
	local Boost = self.StickBoost
	local Brake = self.StickBrake
	local Collective = self.StickCollective
	self.Collective = Collective

	-- // 1. Guinada (rumbo). v14: sale del alabeo (virar inclinada, como un avion): lado derecho abajo (roll < 0) = vira a la derecha.
	-- // Sin autoridad (cerca del agua) no vira.
	-- // v17: en Flight la autoridad es completa (antes se perdia por debajo de GATE_HEIGHT y la nave quedaba pegada cerca del mar;
	-- // el piso duro y la mirada hacia adelante ya la protegen). La compuerta solo rige en Takeoff / Landing.
	local YawAuthority = if Mode == 'Flight' then 1 else Smoothstep01((self.Height - FLIGHT.GATE_HEIGHT) / FLIGHT.GATE_BLEND)
	local YawRateTarget = math.clamp(self.Roll / FLIGHT.MAX_TILT, -1, 1) * FLIGHT.TURN_RATE * FLIGHT.ROLL_TURN * YawAuthority
	self.YawRate += (YawRateTarget - self.YawRate) * (1 - math.exp(-dt / FLIGHT.YAW_SMOOTH))
	self.Yaw += self.YawRate * dt
	local YawCF = CFrame.fromEulerAnglesXYZ(0, self.Yaw, 0)
	local Flat, Right = YawCF.LookVector, YawCF.RightVector
	self.Flat = Flat

	-- // 2. Autoridad horizontal: 0 por debajo de GATE_HEIGHT, 1 a GATE_HEIGHT + GATE_BLEND (con la altura del frame anterior).
	-- // Al aterrizar ademas baja la inclinacion y el limite de velocidad, mas cuanto mas cerca del agua.
	local Authority = if Mode == 'Flight' then 1 else Smoothstep01((self.Height - FLIGHT.GATE_HEIGHT) / FLIGHT.GATE_BLEND)
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
		local Direction = Flat * math.clamp(Boost, -1, 1) + Right * math.clamp(-self.Roll / FLIGHT.MAX_TILT * 0.5, -1, 1)
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
		local CeilLook = Ceiling()
		for _, Tau in FLIGHT.LOOKAHEAD_TIMES do
			local Heights, Dy = SampleHull(self, self.Position, Rotation, Tau, Projected * Tau)
			if Heights ~= nil then
				local Required = FloorFrom(self, Heights, Dy, Clearance)
				if Required > CeilLook then
					-- // v17: la ola (ola gigante) supera el techo: no se puede subir mas, asi que no tiene sentido frenar la nave
					-- // (antes quedaba al 15% de velocidad, "pegada", justo cuando mas hay que alejarse). Solo sube hasta el techo.
					FloorMax = math.max(FloorMax, CeilLook)
				else
					FloorMax = math.max(FloorMax, Required)
					Overload = math.max(Overload, (Required - self.Position.Y) / Tau / Limit)
				end
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

	-- // 5. v14: W / S inclinan la nave (cabeceo) y A / D la alabean; la inclinacion acelera un poco (TILT_ACCEL) y vira (A / D).
	-- // Los propulsores principales (Espacio / Shift) dan el empuje fuerte hacia adelante / atras (HORIZ_ACCEL_MAX).
	-- // Nariz abajo (pitch < 0) = adelante; nariz arriba (pitch > 0) tambien al subir; lado derecho abajo (roll < 0) = derecha.
	local TiltAuthority = Authority * self.TiltScale * LandTilt
	local SpeedCap = FLIGHT.MAX_SPEED * self.SpeedScale * LandSpeed * Authority
	local Soft = SpeedCap * 0.08 + 1 -- // Rango en el que el empuje se apaga al acercarse al limite (alcanza MAX_SPEED casi entero)
	local Vf, Vr = self.Vel:Dot(Flat), self.Vel:Dot(Right)
	local AccelFree = FLIGHT.HORIZ_ACCEL_MAX * FLIGHT.HOLD_BRAKE_FRACTION

	-- // Empuje de la orden (sobre el eje) que se apaga al acercarse al limite de velocidad en su misma direccion
	local function Room(Direction: number, Speed: number): number
		return math.clamp((SpeedCap - Speed * math.sign(Direction)) / Soft, 0, 1)
	end
	-- // Frenos: sobre el limite de velocidad (la ola de adelante lo bajo de golpe) y asistido con las palancas centradas
	local function Brakes(Speed: number, Command: number): number
		local Over = math.abs(Speed) - SpeedCap
		local Brake = 0
		if Over > 0 then
			Brake = -math.sign(Speed) * math.min(Over * FLIGHT.BRAKE_GAIN, FLIGHT.HORIZ_ACCEL_MAX * FLIGHT.BRAKE_FRACTION) * Authority * LandTilt
		end
		local Free = math.clamp(1 - Command * 3, 0, 1)
		local Hold = -math.clamp(Speed * FLIGHT.HOLD_BRAKE, -AccelFree, AccelFree) * Free * Authority * LandTilt
		return Brake + Hold
	end

	-- // Inclinacion pedida: A / D -> alabeo. El cabeceo es solo visual (nariz arriba / abajo al subir / bajar).
	local ClimbRatio = math.clamp(self.VerticalSpeed / FLIGHT.MAX_CLIMB_RATE, -1, 1)
	local PitchCommand = FLIGHT.PITCH_CLIMB * ClimbRatio * self.TiltScale
	local RollCommand = -Roll * FLIGHT.MAX_TILT * TiltAuthority * Room(Roll, Vr)
	PitchCommand = math.clamp(PitchCommand, -FLIGHT.MAX_TILT, FLIGHT.MAX_TILT)
	RollCommand = math.clamp(RollCommand, -FLIGHT.MAX_TILT, FLIGHT.MAX_TILT)

	local Freq, Damping = FLIGHT.TILT_FREQ, FLIGHT.TILT_DAMPING
	self.PitchRate += (Freq * Freq * (PitchCommand - self.Pitch) - 2 * Damping * Freq * self.PitchRate) * dt
	self.RollRate += (Freq * Freq * (RollCommand - self.Roll) - 2 * Damping * Freq * self.RollRate) * dt
	local TiltLimit = FLIGHT.MAX_TILT * 1.2
	self.Pitch = math.clamp(self.Pitch + self.PitchRate * dt, -TiltLimit, TiltLimit)
	self.Roll = math.clamp(self.Roll + self.RollRate * dt, -TiltLimit, TiltLimit)

	-- // Aceleracion: un poco por la inclinacion real del casco + propulsores principales (Espacio adelante, Shift atras)
	local TiltForward = 0 -- // v16: el cabeceo ya no acelera, solo W / S (Push)
	local TiltRight = -FLIGHT.TILT_ACCEL * (self.Roll / FLIGHT.MAX_TILT) * Authority
	local Push = Boost * FLIGHT.HORIZ_ACCEL_MAX * TiltAuthority * Room(Boost, Vf)
	-- // v17: S frena hasta detenerse (proporcional a la velocidad, nunca invierte el sentido)
	local StopBrake = -math.min(math.max(Vf, 0) * FLIGHT.BRAKE_GAIN, FLIGHT.HORIZ_ACCEL_MAX * FLIGHT.BRAKE_FRACTION) * Brake * Authority
	local AccelForward = TiltForward + Push + StopBrake + Brakes(Vf, math.abs(Boost) + Brake)
	local AccelRight = TiltRight + Brakes(Vr, math.abs(Roll))

	local Drag = FLIGHT.HORIZ_ACCEL_MAX / FLIGHT.MAX_SPEED
	-- // v14: gira la velocidad hacia donde apunta la nariz (conserva la rapidez, solo cambia la direccion). Se anula al alabear (A / D).
	local Align = Vector3.zero
	local Lateral = self.Vel:Dot(Right)
	if FLIGHT.NOSE_ALIGN > 0 and math.abs(Lateral) > 0.01 then
		local Weight = math.clamp(1 - math.abs(Roll) * 3, 0, 1) * Authority
		Align = -Right * Lateral * FLIGHT.NOSE_ALIGN * Weight + Flat * math.abs(Lateral) * FLIGHT.NOSE_ALIGN * Weight * math.sign(Vf + 0.001)
	end
	-- // v14: tope a la aceleracion horizontal total (empuje maximo). Evita que freno + resistencia + alineacion superen los
	-- // limites del servidor (Validate usa HORIZ_ACCEL_MAX * SERVER_TOLERANCE).
	local HorizAccel = Flat * AccelForward + Right * AccelRight - self.Vel * Drag + Align
	local AccelMax = FLIGHT.HORIZ_ACCEL_MAX * FLIGHT.ACCEL_CAP
	if HorizAccel.Magnitude > AccelMax then
		HorizAccel = HorizAccel.Unit * AccelMax
	end
	local Vel = self.Vel + HorizAccel * dt
	local Forward = Vel:Dot(Flat)
	if Forward < 0 then
		Vel -= Flat * Forward -- // v17: sin marcha atras en vuelo
	end
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
		Rate = FLIGHT.MAX_CLIMB_RATE * Collective -- // v14: proporcional a la palanca (antes todo o nada)
	elseif Collective < 0 then
		Rate = FLIGHT.MAX_DESCENT_RATE * Collective
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
	local VisualPos, VisualRot = VisualMotion(self, Pos, dt)
	self.CFrame = CFrame.new(Pos + VisualPos) * Rotation * VisualRot

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
-- // Input (opcional, solo vuelo): { Roll = -1..1 (A / D), Collective = -1..1 (Q / E subir / bajar) }. W / S entran por Throttle.
function BoatDrive.Step(self, dt: number, Throttle: number, Steer: number, Idle: boolean?, Input: { Roll: number?, Collective: number? }?)
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

	-- // v21: sobre la ola gigante el motor no hace nada (solo se puede girar) y la ola arrastra la nave
	local Time = workspace:GetServerTimeNow()
	local GL = BM.GIANT_LOCK
	local GiantFraction = Gerstner.ComputeGiantWave(self.Position, Time).Y / GIANT_HEIGHT
	local LockTarget = RangeSmooth(GL.START, GL.FULL, GiantFraction)
	self.GiantLock += (LockTarget - self.GiantLock) * (1 - math.exp(-dt / 0.3))
	local Lock = self.GiantLock
	if Lock > GL.CUTOFF then
		Throttle = 0
	end
	self.SteerSmooth += (Steer - self.SteerSmooth) * (1 - math.exp(-dt / 0.6))

	-- // Velocidad: motor, rozamiento y pendiente (la pendiente se mide el frame anterior)
	local Speed = self.Speed
	if Throttle == 1 then
		Speed = math.min(Speed + ACCELERATION * dt, math.max(Speed, MAX_SPEED))
	else
		local Drag = DECELERATION * dt * (1 + Lock * GL.EXTRA_DRAG)
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
		local SlopeAccel = SLOPE_GRAVITY * Gravity * SlopeSin * (self.Contact or 1)
		if SlopeAccel < 0 then
			SlopeAccel *= SLOPE_DOWNHILL_SCALE -- // v16: bajar una ola ya no da velocidad extra
		end
		Speed -= SlopeAccel * dt
	end
	Speed = math.clamp(Speed, -MAX_REVERSE_SPEED, MAX_SPEED)
	self.Speed = Speed

	self.AccelSmooth += (((Speed - self.PrevSpeed) / math.max(dt, 1e-3)) - self.AccelSmooth) * (1 - math.exp(-dt / 0.4))
	self.PrevSpeed = Speed

	-- // Avance horizontal + marea (corriente suave) + arrastre de la ola gigante
	local Tide = BM.CURRENT_SPEED * (0.7 + 0.3 * math.sin(Time * 0.13))
	local Drift = Gerstner.GIANT_CONFIG.Direction.Unit * (Tide + Gerstner.GIANT_CONFIG.Speed * GL.CARRY * Lock)
	local Pos = self.Position + Flat * (Speed * dt) + Drift * dt
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

		-- // v16: la pendiente se mide con la separacion horizontal REAL de los puntos (con la nave inclinada es menor que
		-- // Length / Width). Antes subestimaba la pendiente: una ola de 60 grados daba ~40 y la nariz se hundia en ella.
		local Right = YawCF.RightVector
		local SepForward = math.max(AverageAlong(Points, self.FrontIndices, Flat) - AverageAlong(Points, self.BackIndices, Flat), 1)
		local SepSide = math.max(AverageAlong(Points, self.RightIndices, Right) - AverageAlong(Points, self.LeftIndices, Right), 1)
		local SlopeForward = (Average(Now, self.FrontIndices) - Average(Now, self.BackIndices)) / SepForward
		local SlopeSide = (Average(Now, self.RightIndices) - Average(Now, self.LeftIndices)) / SepSide
		self.SlopeForward = SlopeForward

		-- // Altura: resorte amortiguado hacia la superficie mientras toca el agua; caida libre si la pierde
		-- // v16: el objetivo es el mayor entre la altura media y el piso del casco (ningun punto bajo la ola), asi el resorte
		-- // levanta la nave suavemente cuando la ola sube por un costado en vez de dejar que la atraviese.
		local Dy = {}
		for i = 1, 4 do
			Dy[i] = Rotation:VectorToWorldSpace(self.Offsets[i]).Y
		end
		local Target = math.max(SurfaceHeight + self.BaseHeight, FloorFrom(self, Now, Dy, self.FloorSlack))
		local Offset = Target - Pos.Y -- // > 0: la nave esta por debajo de su altura de flotacion
		if self.SoftLand then
			-- // v17: recien llegada de vuelo: baja suave hasta tocar el agua (se apaga al tocarla o por tiempo)
			self.SoftLandTime += dt
			if Offset > -0.3 or self.SoftLandTime > SOFT_LAND_TIMEOUT then
				self.SoftLand = false
			end
		end
		local Contact = if self.SoftLand then 1 else math.clamp(1 + Offset / AIR_MARGIN, 0, 1)
		self.Contact = Contact

		-- // v21: respuesta blanda en calma (nave pesada) y rigida sobre la ola gigante (Rough 0 a 1)
		local Stiff = self.Rough
		local HeaveFreq = BM.HEAVE_FREQ + (BM.GIANT_HEAVE_FREQ - BM.HEAVE_FREQ) * Stiff
		local HeaveDamping = BM.HEAVE_DAMPING + (BM.GIANT_HEAVE_DAMPING - BM.HEAVE_DAMPING) * Stiff
		local TiltFreq = BM.TILT_FREQ + (BM.GIANT_TILT_FREQ - BM.TILT_FREQ) * Stiff
		local TiltDamping = BM.TILT_DAMPING + (BM.GIANT_TILT_DAMPING - BM.TILT_DAMPING) * Stiff
		local Spring = HeaveFreq * HeaveFreq * Offset + 2 * HeaveDamping * HeaveFreq * (SurfaceRate - self.VerticalSpeed)
		local MaxAccel = MAX_BUOYANT_ACCEL * Gravity
		Spring = math.clamp(Spring, -MaxAccel, MaxAccel)
		local Fall = -Gravity - AIR_DRAG * self.VerticalSpeed
		local VerticalAccel = Spring * Contact + Fall * (1 - Contact)

		self.VerticalSpeed += VerticalAccel * dt
		if self.SoftLand then
			-- // Velocidad de descenso (respecto a la ola) proporcional a la altura: frena al acercarse, sin golpe
			local MaxFall = math.clamp(-Offset * SOFT_LAND_GAIN, SOFT_LAND_MIN_FALL, SOFT_LAND_MAX_FALL)
			self.VerticalSpeed = math.max(self.VerticalSpeed, SurfaceRate - MaxFall)
		end
		Pos = Vector3.new(Pos.X, Pos.Y + self.VerticalSpeed * dt, Pos.Z)
		self.Position = Pos

		-- // Inclinacion: sigue la pendiente de la ola con inercia; en el aire conserva la rotacion
		local PitchTarget = math.clamp(math.atan(SlopeForward) * TILT_FOLLOW, -MAX_TILT, MAX_TILT)
		local RollTarget = math.clamp(math.atan(SlopeSide) * TILT_FOLLOW, -MAX_TILT, MAX_TILT)
		local Air = 1 - Contact

		local PitchAccel = TiltFreq * TiltFreq * (PitchTarget - self.Pitch) - 2 * TiltDamping * TiltFreq * self.PitchRate
		local RollAccel = TiltFreq * TiltFreq * (RollTarget - self.Roll) - 2 * TiltDamping * TiltFreq * self.RollRate
		PitchAccel = PitchAccel * Contact - AIR_TILT_DAMPING * self.PitchRate * Air
		RollAccel = RollAccel * Contact - AIR_TILT_DAMPING * self.RollRate * Air

		self.PitchRate += PitchAccel * dt
		self.RollRate += RollAccel * dt
		self.Pitch = math.clamp(self.Pitch + self.PitchRate * dt, -MAX_TILT * 1.3, MAX_TILT * 1.3)
		self.Roll = math.clamp(self.Roll + self.RollRate * dt, -MAX_TILT * 1.3, MAX_TILT * 1.3)

		-- // v16: colision dura. Con la inclinacion ya actualizada, ningun punto del casco puede quedar bajo la ola.
		local Final = YawCF * CFrame.fromEulerAnglesXYZ(self.Pitch, 0, self.Roll)
		for i = 1, 4 do
			Dy[i] = Final:VectorToWorldSpace(self.Offsets[i]).Y
		end
		local HardFloor = FloorFrom(self, Now, Dy, self.FloorSlack)
		if Pos.Y < HardFloor then
			Pos = Vector3.new(Pos.X, HardFloor, Pos.Z)
			self.Position = Pos
			self.VerticalSpeed = math.max(self.VerticalSpeed, SurfaceRate) -- // sube con la ola, sin seguir hundiendose
		end
	end

	local VisualPos, VisualRot = VisualMotion(self, Pos, dt)
	self.CFrame = CFrame.new(Pos + VisualPos) * YawCF * CFrame.fromEulerAnglesXYZ(self.Pitch, 0, self.Roll) * VisualRot
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
