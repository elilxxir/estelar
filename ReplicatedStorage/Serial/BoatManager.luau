-- script dentro de carpeta Serial dentro de script Gerstner dentro de ReplicatedStorage

--!strict
--!optimize 2

local RS = game:GetService('ReplicatedStorage')
local CS = game:GetService('CollectionService')
local RunService = game:GetService('RunService')

local IS_CLIENT = RunService:IsClient()
local HeightLookup = require(RS.Gerstner.HeightLookup)
local OctreeModule = require(RS:WaitForChild('Octree'))

local BOAT_TREE = nil
local DRAG_COEFFICIENT = 0.075

type ZONE_INFO = {
	SpeedMultiplier: number,
	AmplitudeMultiplier: number,
	PhaseMultiplier: number,
	CURRENT_ZONE: {}?,
}

local BoatManager = {}

local RATE_PROBE = 0.1 -- // Segundos hacia el futuro para medir la velocidad vertical de la ola
local MAX_TILT = 0.8 -- // Inclinacion maxima (radianes) para que la nave no vuelque en olas muy empinadas

-- // Altura de la ola en los 4 puntos de la nave. HeightLookup devuelve -1 si falla:
-- // esos puntos se reemplazan por el promedio de los validos. Devuelve nil si fallan todos.
local function SampleHeights(Points: { Attachment }, ZoneInfo: ZONE_INFO, TimeOffset: number, Shift: Vector3?): { number }?
	local Heights: { number } = {}
	local Sum, Count = 0, 0
	for i = 1, 4 do
		local Position = Points[i].WorldPosition
		if Shift ~= nil then
			Position += Shift
		end
		local h = HeightLookup.Lookup(Position, "PRECISE", false, ZoneInfo.SpeedMultiplier, ZoneInfo.PhaseMultiplier, ZoneInfo.AmplitudeMultiplier, ZoneInfo.CURRENT_ZONE, TimeOffset)
		Heights[i] = h
		if h ~= -1 then
			Sum += h
			Count += 1
		end
	end
	if Count == 0 then
		return nil
	end
	local Average = Sum / Count
	for i = 1, 4 do
		if Heights[i] == -1 then
			Heights[i] = Average
		end
	end
	return Heights
end

-- // Devuelve (altura objetivo, orientacion, profundidad, velocidad vertical de la ola).
-- // La altura objetivo se calcula con LeadTime segundos de adelanto (opcional).
-- // Si no se pudo calcular la ola devuelve Vector3.zero (el llamador debe conservar el objetivo anterior).
function BoatManager.CalculateBuoyancy(CenterOfMass: Vector3, Bottom: Vector3, Points: { Attachment }, Length: number, Width: number, Height: number, ZoneInfo: ZONE_INFO, LeadTime: number?, Velocity: Vector3?): (Vector3, CFrame, number, number)
	local Now = SampleHeights(Points, ZoneInfo, 0)
	if Now == nil then
		return Vector3.zero, CFrame.identity, 0, 0
	end

	-- // Orientation
	local Front = (Now[1] + Now[2]) / 2
	local Back = (Now[3] + Now[4]) / 2
	local Left = (Now[1] + Now[3]) / 2
	local Right = (Now[2] + Now[4]) / 2

	local pitch = math.clamp(math.atan2(Front - Back, Length), -MAX_TILT, MAX_TILT)
	local roll = math.clamp(math.atan2(Right - Left, Width), -MAX_TILT, MAX_TILT)
	local Orientation = CFrame.fromEulerAnglesXYZ(pitch, 0, roll)

	local Target = Now
	if LeadTime ~= nil and LeadTime > 0 then
		Target = SampleHeights(Points, ZoneInfo, LeadTime) or Now
	end

	local WaveHeightNow = (Now[1] + Now[2] + Now[3] + Now[4]) / 4
	local WaveHeightTarget = (Target[1] + Target[2] + Target[3] + Target[4]) / 4

	-- // Profundidad: positiva si el fondo esta bajo el agua, negativa si esta en el aire.
	-- // La fuerza es siempre continua (sin apagarse), asi no hay rebotes por encendido/apagado.
	local Depth = math.clamp(WaveHeightNow - Bottom.Y, -5, 20)


	-- // Velocidad vertical de la ola en el punto al que va la nave: se mide la altura RATE_PROBE segundos en el futuro,
	-- // desplazando los puntos con la velocidad horizontal de la nave. Incluye el movimiento de la ola y la pendiente que cruza la nave.
	local VerticalRate = 0
	if Velocity ~= nil then
		local Probe = SampleHeights(Points, ZoneInfo, RATE_PROBE, Velocity * RATE_PROBE)
		if Probe ~= nil then
			VerticalRate = ((Probe[1] + Probe[2] + Probe[3] + Probe[4]) / 4 - WaveHeightNow) / RATE_PROBE
		end
	end

	return Vector3.new(0, WaveHeightTarget + Height, 0), Orientation, Depth, VerticalRate
end

return BoatManager
