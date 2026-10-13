-- ModuleScript dentro de carpeta Serial dentro de script Gerstner dentro de ReplicatedStorage

--!nonstrict

--[[
	Movimiento cinematico de la nave: sin fuerzas ni resortes.
	Cada frame se calcula la posicion, el giro, la altura y la inclinacion de la nave a partir de la ola
	(HeightLookup, con la hora del servidor) y se coloca directamente el VehicleSeat. El resto de la nave va soldado al asiento.

	Lo usan dos scripts:
	- Cliente del piloto (StarterPlayerScripts/BoatDriver): mueve la nave mientras hay alguien sentado.
	- Servidor (Handler): solo la mantiene flotando cuando esta vacia.
]]

local BoatManager = require(script.Parent.BoatManager)
local ZoneManager = require(script.Parent.ZoneManager)

local MAX_SPEED = 200 -- // studs/s
local ACCELERATION = 10 -- // studs/s^2
local DECELERATION = 15 -- // studs/s^2
local TURN_RATE = math.rad(30) -- // rad/s
local HEIGHT_SMOOTHING = 0.04 -- // Segundos de filtro sobre la altura (la ola se anticipa para compensar el retraso)
local TILT_SMOOTHING = 0.2 -- // Segundos de filtro sobre la inclinacion (pitch/roll)
local ZONE_REFRESH = 3 -- // Segundos entre busquedas de zona

local POINT_NAMES = { 'TopLeft', 'TopRight', 'BottomLeft', 'BottomRight' }

local BoatDrive = {}
BoatDrive.MAX_SPEED = MAX_SPEED

-- // Crea el estado de la nave a partir de su posicion y orientacion actuales.
function BoatDrive.new(Boat: Model, Seat: VehicleSeat)
	local Main = Boat.Main

	-- // Posicion de los 4 puntos de flotacion en el espacio del asiento (constante, porque todo va soldado).
	local SeatToMain = Main.CFrame:ToObjectSpace(Seat.CFrame)
	local Offsets = {}
	for i, Name in POINT_NAMES do
		Offsets[i] = SeatToMain:PointToObjectSpace(Main[Name].Position)
	end

	local Look = Seat.CFrame.LookVector
	local Yaw = math.atan2(-Look.X, -Look.Z)
	local YawCF = CFrame.fromEulerAnglesXYZ(0, Yaw, 0)

	return {
		Seat = Seat,
		Offsets = Offsets,
		Length = Main.Size.Z,
		Width = Main.Size.X,
		BaseHeight = Main.Size.Y / 2,

		Position = Seat.Position,
		Yaw = Yaw,
		Speed = 0,
		Orientation = (YawCF:Inverse() * Seat.CFrame).Rotation,
		VerticalSpeed = 0,
		CFrame = Seat.CFrame,
		Flat = Vector3.new(Look.X, 0, Look.Z).Magnitude > 0.01 and Vector3.new(Look.X, 0, Look.Z).Unit or Vector3.zAxis * -1,

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
function BoatDrive.Step(self, dt: number, Throttle: number, Steer: number)
	dt = math.min(dt, 0.1)

	if Steer == 1 then
		self.Yaw -= TURN_RATE * dt
	elseif Steer == -1 then
		self.Yaw += TURN_RATE * dt
	end

	if Throttle == 1 then
		self.Speed = math.min(self.Speed + ACCELERATION * dt, MAX_SPEED)
	else
		self.Speed = math.max(self.Speed - DECELERATION * dt, 0)
	end

	local YawCF = CFrame.fromEulerAnglesXYZ(0, self.Yaw, 0)
	local Flat = YawCF.LookVector
	local Pos = self.Position + Flat * (self.Speed * dt)
	local PreviousY = self.Position.Y

	self.ZoneTimer += dt
	if self.ZoneTimer >= ZONE_REFRESH then
		self.ZoneTimer = 0
		self.Position = Pos
		BoatDrive.UpdateZone(self)
	end
	self.Position = Pos
	UpdateZoneMultipliers(self)

	-- // Puntos de flotacion en el mundo, con la posicion que tendra la nave este frame (sin retraso).
	local Rotation = YawCF * self.Orientation
	local Points = {}
	for i = 1, 4 do
		Points[i] = { WorldPosition = Pos + Rotation:VectorToWorldSpace(self.Offsets[i]) }
	end

	local Height, Orientation, _, WaveRate = BoatManager.CalculateBuoyancy(Pos, Pos, Points, self.Length, self.Width, self.BaseHeight, self.ZoneInfo, nil, Flat * self.Speed)
	if Height ~= Vector3.zero then
		-- // WaveRate * HEIGHT_SMOOTHING compensa el retraso del filtro
		local TargetY = Height.Y + WaveRate * HEIGHT_SMOOTHING
		local NewY = PreviousY + (TargetY - PreviousY) * (1 - math.exp(-dt / HEIGHT_SMOOTHING))
		self.Orientation = self.Orientation:Lerp(Orientation, 1 - math.exp(-dt / TILT_SMOOTHING))
		Pos = Vector3.new(Pos.X, NewY, Pos.Z)
		self.Position = Pos
	end

	self.VerticalSpeed = (Pos.Y - PreviousY) / dt
	self.Flat = Flat
	self.CFrame = CFrame.new(Pos) * YawCF * self.Orientation
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
