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

-- // Ola gigante periodica (pulso sech^2). Se calcula solo con el tiempo del servidor,
-- // asi cliente y servidor coinciden sin eventos.
local GIANT = {
	Direction = Vector3.new(1, 0, 0), -- direccion de avance (unitario)
	Height = 1600,  -- altura maxima en studs
	Width = 1000,   -- ancho del pulso (menor = mas empinada)
	Speed = 120,    -- studs/s
	Period = 90,    -- segundos entre olas
	Start = -3600,  -- distancia inicial detras del origen
}

function Gerstner.ComputeGiantWave(Position: Vector3, t: number): Vector3
	local center = GIANT.Start + GIANT.Speed * (t % GIANT.Period)
	local d = GIANT.Direction:Dot(Position) - center
	local s = 1 / math.cosh(d / GIANT.Width)
	return v3new(0, GIANT.Height * s * s, 0)
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
function Gerstner.ComputeTransform( Waves: { WaveInfo }, Position: Vector3, t: number, phaseMulti: number?, speedMulti: number?, amplitudeMulti: number? ): Vector3
	local Transform = v3zero
	local phaseMulti = phaseMulti:: number or 1
	local speedMulti = speedMulti:: number or 1
	local amplitudeMulti = amplitudeMulti:: number or 1

	for i, Wave: WaveInfo in Waves do
		local waveNumber, waveSpeed, waveAmplitude = Wave.WaveNumber * phaseMulti, Wave.WaveSpeed * speedMulti, Wave.WaveAmplitude * amplitudeMulti
		Transform += Gerstner.ComputeWave(Position, t, waveNumber, waveSpeed, waveAmplitude, Wave.Direction)
	end

	Transform += Gerstner.ComputeGiantWave(Position, t)
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
