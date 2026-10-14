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
	- Servidor (Handler): solo la mantiene flotando cuando esta vacia.
]]

local BoatManager = require(script.Parent.BoatManager)
local ZoneManager = require(script.Parent.ZoneManager)

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

local function UpdateZoneMultipliers(self)
	local Info = self.ZoneInfo
	local Zone = Info.CURRENT_ZONE
	if Zone == nil then
		Info.SpeedMultiplier, Info.PhaseMultiplier, Info.AmplitudeMultiplier = 1, 1, 1
	elseif Zone.Type ~= 'Whirlpool' then
		if Zone.Link then
			Info.SpeedMultiplier, Info.PhaseMultiplier, Info.AmplitudeMultiplier = ZoneManager:GetZoneMultipliers(self.Position, Zone.Link.Position, Zone)
		else
			Info.SpeedMultiplier, Info.PhaseMultiplier, Info.AmplitudeMultiplier = ZoneManager:GetIslandMultipliers(self.Position, Zone.Island.Center.Position, Zone.Radius / 2)
		end
	end
end

-- // Avanza la nave dt segundos. Throttle y Steer son los del VehicleSeat (-1, 0 o 1).
-- // Idle = true para la nave vacia: no se desliza por las pendientes.
function BoatDrive.Step(self, dt: number, Throttle: number, Steer: number, Idle: boolean?)
	dt = math.min(dt, 0.05)
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

	self.ZoneTimer += dt
	if self.ZoneTimer >= ZONE_REFRESH then
		self.ZoneTimer = 0
		BoatDrive.UpdateZone(self)
	end
	UpdateZoneMultipliers(self)

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
	Seat.AssemblyLinearVelocity = self.Flat * self.Speed + Vector3.new(0, self.VerticalSpeed, 0)
	Seat.AssemblyAngularVelocity = Vector3.zero
end

return BoatDrive
