-- module script dentro de replicatedStorage

--!strict
--!optimize 2
--!native

--[[
	@FlameEmber06
	Implementation of Gerstner waves.
]]


-- // We try to use Vector3s most of the time here, since ROBLOX uses native vectors, however there is no native
-- // implementations of Vector2's or CFrames.
-- // See: https://devforum.roblox.com/t/native-luau-vector3-beta/1180548/25?page=2 for benchmarking.

export type WaveInfo = {
	Direction: Vector3,
	WaveLength: number,
	Steepness: number,
	Gravity: number,

	WaveNumber: number,
	WaveSpeed: number,
	WaveAmplitude: number,
}

local PI = math.pi

local XZ_AXIS = Vector3.new(1, 0, 1)
local X_AXIS = Vector3.xAxis
local Y_AXIS = Vector3.yAxis
local Z_AXIS = Vector3.zAxis

local TwoPi = 2 * math.pi
local TWO_OVER_PI = 2 / math.pi

local acos = math.acos
local abs = math.abs

local sqrt = math.sqrt
local cos = math.cos
local sin = math.sin
local atan2 = math.atan2

local v3new = Vector3.new
local v2new = Vector2.new
local v3zero = Vector3.zero
local v2zero = Vector2.zero

local clamp = math.clamp
local sign = math.sign
local rad = math.rad
local min = math.min

local GRID_INFO = {
	Padding = 0,
	Width = 0,
	Length = 0,
	PaddingMultiplier = 1,
	UV_SCALE = 1
}

--[[
	Lerps a number "a" to "b", and alpha "t", with a cosine easing style.
]]
local function CosineLerp(a: number, b: number, t: number): number
	local cosineT = (1 - cos(t * PI)) / 2  -- Cosine easing
	return a + (b - a) * cosineT
end

--[[
	Fetches the UV coordinates of an (x, z) point. Used for whirlpools.
]]
local function GetUVCoordinates(Vx: number, Vz: number): Vector2
	local Padding: number = GRID_INFO.Padding
	local Width: number = GRID_INFO.Width
	local Length: number = GRID_INFO.Length

	local x = ((Vx + ((Padding * (Width - 1) / 2))) / Padding) + 1
	local y = ((Vz + ((Padding * (Length - 1) / 2))) / Padding) + 1

	return v2new(x, y)
end

--[[
	Rotates a UV around a pivot point, given as a Vector2. Used for whirlpools.
]]
local function RotateUV(UV: Vector2, Angle: number, Center: Vector2): Vector2
	local cosA = cos(Angle)
	local sinA = sin(Angle)

	local x = cosA * (UV.X - Center.X) - sinA * (UV.Y - Center.Y) + Center.X
	local y = sinA * (UV.X - Center.X) + cosA * (UV.Y - Center.Y) + Center.Y

	return v2new(x, y)
end

local Gerstner = {}
local PaddingMultiplier = GRID_INFO.PaddingMultiplier
local UV_SCALE = GRID_INFO.UV_SCALE

function Gerstner:SET_SETTINGS(Padding: number, Width: number, Length: number, PaddingMulti: number, SCALE: number)
	GRID_INFO.Padding = Padding
	GRID_INFO.Width = Width
	GRID_INFO.Length = Length
	GRID_INFO.PaddingMultiplier = PaddingMulti

	PaddingMultiplier = PaddingMulti
	UV_SCALE = SCALE
end

--[[
	Constructs and returns a <strong>WaveInfo</strong> object.
	<strong>Direction:</strong> The direction of the wave, as a Vector3.
	<strong>WaveLength:</strong> The wave length of the wave, as a number.
	<strong>Steepness:</strong> The steepness (height) of the wave, as a number.
	<strong>Gravity:</strong> The gravity of the wave, as a number. Defaults to 9.8
]]
function Gerstner.new(Direction: Vector3, WaveLength: number, Steepness: number, Gravity: number?): WaveInfo
	local g = Gravity or 9.8

	local WaveNumber = TwoPi / WaveLength
	local WaveSpeed = sqrt(g / WaveNumber)
	local waveAmplitude = Steepness / WaveNumber

	return {
		Direction = Direction,
		WaveLength = WaveLength,
		Steepness = Steepness,
		Gravity = g,

		WaveNumber = WaveNumber,
		WaveSpeed = WaveSpeed,
		WaveAmplitude = waveAmplitude,
	}
end

-- // Ola gigante: tren continuo de pulsos sech^2, separados Spacing studs. Se calcula solo con el tiempo del servidor,
-- // asi cliente y servidor coinciden sin eventos. Al ser un tren no hay saltos: cuando un pulso se va, el siguiente ya viene.
local GIANT = {
	Direction = Vector3.new(1, 0, 0), -- direccion de avance (unitario)
	Height = 2000,  -- altura maxima en studs (v07, antes 700). Tope practico: ~2048, el maximo de una malla de Roblox (ver GiantWaveFar)
	Width = 800,    -- ancho del pulso (v07, antes 280). Height/Width = 2.5 como antes, asi la pendiente no cambia
	Speed = 100,     -- studs/s (v07, antes 60)
	Spacing = 20000, -- distancia entre pulsos en studs (v07, antes 5400). Segundos entre olas = Spacing / Speed = 160 s. Debe ser > ~9 * Width para que entre pulsos el mar quede plano
	Start = -1800,  -- posicion de un pulso cuando el tiempo del servidor es multiplo de Spacing / Speed
	Drop = 10,      -- studs que la ola lejana (GiantWaveFar) queda por debajo del mar para no chocar con sus olas pequenas

	-- // v13: realismo. Todo es determinista (solo depende de la hora del servidor y de la posicion).
	FrontScale = 1.1, -- // Frente: su ancho es Width * FrontScale (antes 0.8, mas empinado; mas ancho = pendiente mas suave y menos estiramiento de textura)
	BackScale = 1.3,  -- // La parte de atras es mas larga y suave: Width * BackScale
	SurgeAmp = 90,    -- // La ola acelera y frena: se adelanta / atrasa hasta SurgeAmp studs (velocidad ~ Speed +- 2*pi*SurgeAmp/SurgePeriod)
	SurgePeriod = 47, -- // Segundos de un ciclo de aceleracion
	-- // La cresta no es una pared recta: se curva. Las longitudes deben dividir 2000 (ancho de las piezas de GiantWaveFar)
	CrestAmp1 = 90, CrestLen1 = 2000, CrestPhase1 = 0.7, -- // antes 150
	CrestAmp2 = 15, CrestLen2 = 1000, CrestPhase2 = 2.1, -- // antes 60
	-- // Ondulacion que recorre la cresta (solo en el plano, se desvanece hacia su borde)
	CrestDynAmp = 6, CrestDynLen = 500, CrestDynSpeed = 40, -- // antes 40
	RippleScale = 0.15, -- // Multiplica las olas internas de la ola gigante (1 = como antes, 0 = lisa)
}

Gerstner.GIANT_CONFIG = GIANT

-- // v13: olas dentro de la ola gigante. Su altura se escala con la de la ola (solo existen sobre ella).
local RIPPLES: { { Direction: Vector3, K: number, Speed: number, Amp: number, Phase: number } } = {}
do
	local Defs = {
		{ Dir = Vector3.new(1, 0, 0.3), Wavelength = 420, Amp = 38, Phase = 0.3 },
		{ Dir = Vector3.new(0.9, 0, -0.5), Wavelength = 280, Amp = 24, Phase = 1.7 },
		{ Dir = Vector3.new(0.7, 0, 0.7), Wavelength = 190, Amp = 14, Phase = 3.1 },
		{ Dir = Vector3.new(1, 0, -0.15), Wavelength = 130, Amp = 8, Phase = 4.4 },
	}
	for _, Def in Defs do
		local K = TwoPi / Def.Wavelength
		table.insert(RIPPLES, { Direction = Def.Dir.Unit, K = K, Speed = sqrt(9.8 / K), Amp = Def.Amp, Phase = Def.Phase })
	end
end

local GIANT_PERP = Vector3.new(-GIANT.Direction.Z, 0, GIANT.Direction.X) -- // Perpendicular a la direccion de avance (a lo largo de la cresta)

local function Smoothstep(a: number, b: number, x: number): number
	local u = clamp((x - a) / (b - a), 0, 1)
	return u * u * (3 - 2 * u)
end

-- // Perfil de la ola (0 a 1) a distancia firmada w de su centro (w > 0 = por delante). Asimetrico: frente empinado, cola larga.
-- // La ventana lo lleva a 0 antes de llegar al siguiente pulso, para que entre olas el mar quede plano.
local function GiantFraction(w: number): number
	local Scale = if w >= 0 then GIANT.FrontScale else GIANT.BackScale
	local s = 1 / math.cosh(w / (GIANT.Width * Scale))
	return s * s * (1 - Smoothstep(0.55, 1, abs(w) / (GIANT.Spacing / 2)))
end

-- // Posicion (a lo largo de Direction) de uno de los pulsos en el instante t. Los demas estan a +- k * Spacing.
-- // v13: ademas se adelanta y atrasa (SurgeAmp), asi su velocidad no es constante.
function Gerstner.GetGiantWaveCenter(t: number): number
	return GIANT.Start + (GIANT.Speed * t) % GIANT.Spacing + GIANT.SurgeAmp * sin(TwoPi * t / GIANT.SurgePeriod)
end

-- // Altura de la ola gigante en Position, siendo w0 la distancia firmada al centro del pulso.
-- // t = nil: solo la forma estatica (curvatura de la cresta), que es lo que dibuja GiantWaveFar.
-- // Edge (0 a 1): cuanto de la parte dinamica (ondulacion de la cresta y olas internas) se aplica; 0 en el borde del plano.
function Gerstner.GetGiantShape(w0: number, Position: Vector3, t: number?, Edge: number?): number
	local f0 = GiantFraction(w0)
	if f0 < 0.002 then
		return GIANT.Height * f0
	end

	local v = GIANT_PERP:Dot(Position)
	local Offset = GIANT.CrestAmp1 * sin(TwoPi * v / GIANT.CrestLen1 + GIANT.CrestPhase1)
		+ GIANT.CrestAmp2 * sin(TwoPi * v / GIANT.CrestLen2 + GIANT.CrestPhase2)
	local e = Edge or 1
	local Live = t ~= nil and e > 0
	if Live then
		Offset += e * GIANT.CrestDynAmp * sin(TwoPi * (v - GIANT.CrestDynSpeed * (t :: number)) / GIANT.CrestDynLen)
	end

	-- // La curvatura se desvanece en las colas (peso 0 -> 1 entre f0 = 0 y 0.1), asi no hay saltos
	local f = GiantFraction(w0 - Offset * Smoothstep(0, 0.1, f0))
	local Height = GIANT.Height * f

	if Live and f > 0.01 then
		local tt = t :: number
		local Ripple = 0
		for _, Rp in RIPPLES do
			Ripple += Rp.Amp * sin(Rp.K * (Rp.Direction:Dot(Position) - Rp.Speed * tt) + Rp.Phase)
		end
		Height += Ripple * f * e * GIANT.RippleScale
	end
	return Height
end

-- // Altura estatica a distancia w del centro y posicion v a lo largo de la cresta (para GiantWaveFar).
function Gerstner.GetGiantStaticHeight(w: number, v: number): number
	return Gerstner.GetGiantShape(w, GIANT_PERP * v, nil, nil)
end

-- // EdgeScale (0 a 1): 1 = ola completa. Hacia 0 la ola se reduce solo hasta quedar GIANT.Drop studs mas baja,
-- // que es donde la retoma la ola lejana. Asi no hay acantilado ni desaparicion brusca en el borde del plano.
function Gerstner.ComputeGiantWave(Position: Vector3, t: number, EdgeScale: number?): Vector3
	local Spacing = GIANT.Spacing
	local d = GIANT.Direction:Dot(Position) - Gerstner.GetGiantWaveCenter(t)
	local w = (d + Spacing / 2) % Spacing - Spacing / 2 -- // distancia al pulso mas cercano
	local Height = Gerstner.GetGiantShape(w, Position, t, EdgeScale)
	if EdgeScale ~= nil and EdgeScale < 1 then
		Height -= clamp(Height, 0, GIANT.Drop) * (1 - EdgeScale)
	end
	return v3new(0, Height, 0)
end

--[[
	Computes all active waves for a specific Vector3 point and returns the new point.
	<strong>Waves:</strong> All the active waves given as a table.
	<strong>Position:</strong> The position of the vertex, as a Vector3.
	<strong>t:</strong> Time variable.
	<strong>phaseMulti:</strong> The phase multiplier for the wave, used for zone / island parameters.
	<strong>speedMulti:</strong> The speed multiplier for the wave, used for zone / island parameters.
	<strong>amplitudeMulti:</strong> The amplitude multiplier for the wave, used for zone / island parameters.
	
]]
function Gerstner.ComputeTransform( Waves: { WaveInfo }, Position: Vector3, t: number, phaseMulti: number?, speedMulti: number?, amplitudeMulti: number?, giantScale: number? ): Vector3 -- // giantScale = EdgeScale de ComputeGiantWave
	local Transform = v3zero
	local phaseMulti = phaseMulti:: number or 1
	local speedMulti = speedMulti:: number or 1
	local amplitudeMulti = amplitudeMulti:: number or 1

	for i, Wave: WaveInfo in Waves do
		local waveNumber, waveSpeed, waveAmplitude = Wave.WaveNumber * phaseMulti, Wave.WaveSpeed * speedMulti, Wave.WaveAmplitude * amplitudeMulti
		Transform += Gerstner.ComputeWave(Position, t, waveNumber, waveSpeed, waveAmplitude, Wave.Direction)
	end

	-- // Cerca del borde del plano las olas pequenas se calman igual que la gigante, para no dejar un escalon contra los planos secundarios (planos)
	if giantScale ~= nil and giantScale < 1 then
		Transform *= giantScale
	end

	Transform += Gerstner.ComputeGiantWave(Position, t, giantScale)
	return Transform
end

function Gerstner.ComputeWave(Position: Vector3, t: number, WaveNumber: number, WaveSpeed: number, WaveAmplitude: number, WaveDirection: Vector3): Vector3
	local Phase = WaveNumber * (WaveDirection:Dot(Position) - WaveSpeed * t)

	local cosf = cos(Phase)
	local sinf = sin(Phase)
	local Acosf = (WaveAmplitude * cosf)
	local X, Y, Z = WaveDirection.X * Acosf, WaveAmplitude * sinf, WaveDirection.Z * Acosf

	return v3new(X, Y, Z)
end 

--[[
	The same as Gerstner.ComputeTransform, but includes calculating the wave normals as well.
	Use this if you want to have accurate lighting reflections on the ocean.
]]
function Gerstner.ComputeTransformAndNormal( Waves: { WaveInfo }, Position: Vector3, t: number, phaseMulti: number?, speedMulti: number?, amplitudeMulti: number? ): (Vector3, Vector3)
	local Transform = v3zero
	local Tangent = X_AXIS
	local Binormal = Z_AXIS

	local phaseMulti = phaseMulti:: number or 1
	local speedMulti = speedMulti:: number or 1
	local amplitudeMulti = amplitudeMulti:: number or 1

	for i, Wave: WaveInfo in Waves do
		local waveNumber, waveSpeed, waveAmplitude = Wave.WaveNumber * phaseMulti, Wave.WaveSpeed * speedMulti, Wave.WaveAmplitude * amplitudeMulti
		local _transform, _tangent, _binormal = Gerstner.ComputeWaveAndNormals(Position, t, waveNumber, waveSpeed, waveAmplitude, Wave.Direction, Wave.Steepness)
		Transform += _transform

		Tangent += _tangent
		Binormal += _binormal
	end

	local Normal = Binormal:Cross(Tangent).Unit

	return Transform, Normal
end

function Gerstner.ComputeWaveAndNormals(Position: Vector3, t: number, WaveNumber: number, WaveSpeed: number, WaveAmplitude: number, WaveDirection: Vector3, Steepness: number): (Vector3, Vector3, Vector3)
	local Phase = WaveNumber * (WaveDirection:Dot(Position) - WaveSpeed * t)

	local cosf = cos(Phase)
	local sinf = sin(Phase)
	local Acosf = (WaveAmplitude * cosf)
	local X, Y, Z = WaveDirection.X * Acosf, WaveAmplitude * sinf, WaveDirection.Z * Acosf


	local dX, dZ = WaveDirection.X, WaveDirection.Z
	local SteepnessSinF = (Steepness * sinf)
	local SteepnessCosF = (Steepness * cosf)

	local Tangent = v3new(
		-dX * dX * SteepnessSinF,
		dX * SteepnessCosF,
		-dX * dZ * SteepnessSinF
	)
	local Binormal = v3new(
		-dX * dZ * SteepnessSinF,
		dZ * SteepnessCosF,
		-dZ * dZ * SteepnessSinF
	)
	return v3new(X, Y, Z), Tangent, Binormal
end 

--[[
	Returns a transformation / offset position, as well as a UV offset for whirlpools / vortices.
]]
function Gerstner.GetVortexTransform(VortexParams: any, VertexPosition: Vector3, BaseUV: Vector2?, t: number, PlanePosition: Vector3?): (Vector3, Vector2)
	local WhirlpoolCenter: Vector3 = VortexParams.Origin * XZ_AXIS
	local Radius: number = VortexParams.Radius

	local Displacement = (VertexPosition * XZ_AXIS) - WhirlpoolCenter
	local Distance = Displacement.Magnitude

	if Distance > Radius then
		return v3zero, v2zero
	end
	local FormationTime: number = VortexParams.FormationTime
	local SpawnedAt: number = VortexParams.SpawnedAt

	local Decay = 1
	local Despawn: boolean? = VortexParams.Despawn
	local Delta: number? = nil

	if Despawn == true then
		local DissolveTime: number = VortexParams.DissolveTime
		local FullyDecayAt: number = VortexParams.FullDecayAt

		if t > FullyDecayAt then
			-- return v3zero, v2zero
		end

		Delta = clamp(1 - ((FullyDecayAt - t) / DissolveTime), 0, 1)
		Decay = CosineLerp(1, 0, Delta:: number)
	end


	local Elapsed = t - SpawnedAt
	local ElapsedClamped = Elapsed >= FormationTime and 1 or CosineLerp(0, 1, min(Elapsed / FormationTime, 1))

	local DownwardForce: number = VortexParams.DownwardForce
	local TangentSpeed: number = VortexParams.TangentSpeed
	local RotSpeed: number = VortexParams.RotSpeed
	local Scale: number = VortexParams.Scale

	local DistanceFactor = (Distance / Radius)
	local DividedDistance = Distance / Scale
	local VelocityDistance = DistanceFactor * DistanceFactor

	local Falloff = clamp(1 - DistanceFactor, 0, 1)
	local FalloffSmooth = Falloff * Falloff * (3 - 2 * Falloff)

	-- // Calculate our main forces

	local DownwardForce = v3new(0, -DownwardForce / (DividedDistance + 1), 0) * FalloffSmooth * ElapsedClamped * Decay
	local TangentVelocity = Displacement:Cross(Y_AXIS).Unit * (TangentSpeed * VelocityDistance) * FalloffSmooth * ElapsedClamped * Decay

	-- // UV rotation: To simulate a spinning effect, the UV is rotated if we're in the whirlpool radius
	-- // This does create an issue where the UVs at the borders are distorted
	-- // 	Normally we'd avoid this by not rotating the actual UV at all, and instead having an 'overlay' texture 
	-- // 	and rotate that texture. However, ROBLOX doesn't have a stacking ability with PBR texture as far as I'm aware
	-- // 	and you'd need to use an EditableImage as well (assuming you want it to be directly layered over the ocean)

	local OffsetUV = v2zero
	if BaseUV ~= nil then
		local PlanePosition = PlanePosition:: Vector3
		local AngularSpeed = -sign(TangentSpeed) * RotSpeed 

		local VortexUV: Vector2 = VortexParams.UVCenter or GetUVCoordinates(WhirlpoolCenter.X - PlanePosition.X, WhirlpoolCenter.Z - PlanePosition.Z)
		VortexParams.UVCenter = VortexUV

		local angle = (rad(AngularSpeed * ElapsedClamped) * Elapsed) % TwoPi

		if Despawn == true then
			angle = CosineLerp(angle, TwoPi, Delta:: number)
		end
		local PM = 1 / UV_SCALE
		OffsetUV = (RotateUV(BaseUV * PM, angle, VortexUV) / PM) - BaseUV
	end

	return DownwardForce + TangentVelocity, OffsetUV
end

--[[
	Performs an approximation of the ocean height at a Vector3 position, at the cost of accuracy for speed.
]]
function Gerstner:GetApproximateHeight(Waves: { WaveInfo }, Position: Vector3, t: number, phaseMulti: number?, speedMulti: number?, amplitudeMulti: number?)
	local TransformY = 0
	local phaseMulti = phaseMulti:: number or 1
	local speedMulti = speedMulti:: number or 1
	local amplitudeMulti = amplitudeMulti:: number or 1

	for _, Wave: WaveInfo in Waves do
		local waveNumber, waveSpeed, waveAmplitude = Wave.WaveNumber * phaseMulti, Wave.WaveSpeed * speedMulti, Wave.WaveAmplitude * amplitudeMulti
		local wavePhase = waveNumber * (Wave.Direction:Dot(Position) - waveSpeed * t)
		local sin = sin(wavePhase)

		local Approximate = (1 - abs(TWO_OVER_PI * acos(sin)))

		TransformY += waveAmplitude * Approximate
	end

	return TransformY
end

return Gerstner
