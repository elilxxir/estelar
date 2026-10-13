-- script hijo de Gerstner

--!native
--!optimize 2
--!strict

local Camera = workspace.Camera

local FOV = math.tan(math.rad(Camera.FieldOfView) / 2)
local ViewportRatio = (Camera.ViewportSize.X / Camera.ViewportSize.Y)
Camera:GetPropertyChangedSignal('DiagonalFieldOfView'):Connect(function()
	FOV = math.tan(math.rad(Camera.FieldOfView) / 2)
end)

Camera:GetPropertyChangedSignal('ViewportSize'):Connect(function()
	ViewportRatio = (Camera.ViewportSize.X / Camera.ViewportSize.Y)
end)

local Helper = {}
local _settings = require(script.Parent.Settings)

local v3 = Vector3.new
local v2 = Vector2.new
local acos = math.acos
local max = math.max
local min = math.min
local fmod = math.fmod
local clamp = math.clamp

local sqrt = math.sqrt
local pow = math.pow

local BAND = bit32.band

local COLOR_LOW, COLOR_HIGH =_settings.WAVE_COLORS.TROUGH, _settings.WAVE_COLORS.CREST
local SHORE_COLOR = _settings.WAVE_COLORS.SHORE
local VORTEX_LOW = _settings.WAVE_COLORS.VORTEX
local WHITECAP = Color3.new(1, 1, 1)
local COLOR_MAX_Y = _settings.COLOR_MAX_HEIGHT or 2 -- // v10: altura a partir de la cual el color deja de aclararse (evita que la ola gigante se vea pálida/espumosa)

local SCROLL_DIRECTION_X, SCROLL_DIRECTION_Y = _settings.UV_SCROLL_DIRECTION.X, _settings.UV_SCROLL_DIRECTION.Y
local DEPTH_RAY = _settings.DEPTH_RAY_LENGTH
local DEPTH_RAY_OFFSET = _settings.DEPTH_RAY_OFFSET
local UV_SCROLL_SPEED = _settings.UV_SCROLL_SPEED
local SHORE_TRANSPARENCY = _settings.SHORE_TRANSPARENCY

local CHUNK_SIZE = _settings.GRID_SETTINGS.CHUNK_SIZE
local CHUNK_OFFSETS = {
	Vector3.new(CHUNK_SIZE, 0, CHUNK_SIZE),
	Vector3.new(-CHUNK_SIZE, 0, -CHUNK_SIZE),
	Vector3.new(CHUNK_SIZE, 0, -CHUNK_SIZE),
	Vector3.new(-CHUNK_SIZE, 0, CHUNK_SIZE),
	
	Vector3.new(0, -CHUNK_SIZE, 0) -- // An addition point placed at the bottom so that the camera being underwater won't bug out the frustum checks
}

local GOLDEN_RATIO = 1.618

local IslandParameters = RaycastParams.new()
IslandParameters.FilterDescendantsInstances = { workspace.Map }
IslandParameters.FilterType = Enum.RaycastFilterType.Include

export type ZoneParameters = {
	Type: string,
	Link: BasePart,
	Radius: number,

	PhaseMultiplier: number,
	SpeedMultiplier: number,
	AmplitudeMultiplier: number,

	Island: any?,
	Despawn: boolean?,
	
	FullDecayAt: number?,
	DissolveTime: number?,
}

function Helper.GetTableLength(Table: {[any]: any}): number
	local n = 0
	for i, v in Table do
		n += 1
	end
	return n
end

function Helper.GetFrustumPlanes(Distance: number, CamCF: CFrame): (number, number, number, Vector3, Vector3, Vector3, Vector3, CFrame)
	local cameraCFrame = CamCF
	local cameraPos = cameraCFrame.Position
	local rightVec, upVec = cameraCFrame.RightVector, cameraCFrame.UpVector

	local farPlaneCFrame = cameraCFrame * CFrame.new(0, 0, -Distance)

	local distance2 = Distance / 2
	local farPlaneHeight2 = FOV * Distance
	local farPlaneWidth2 = farPlaneHeight2 * ViewportRatio
	local farPlaneTopRight = farPlaneCFrame * Vector3.new(farPlaneWidth2, farPlaneHeight2, 0)
	local farPlaneBottomLeft = farPlaneCFrame * Vector3.new(-farPlaneWidth2, -farPlaneHeight2, 0)
	local farPlaneBottomRight = farPlaneCFrame * Vector3.new(farPlaneWidth2, -farPlaneHeight2, 0)

	local frustumCFrameInverse = (cameraCFrame * CFrame.new(0, 0, -distance2)):Inverse()

	local rightNormal = upVec:Cross(farPlaneBottomRight - cameraPos).Unit
	local leftNormal = (farPlaneBottomLeft - cameraPos):Cross(upVec).Unit
	local topNormal = (farPlaneTopRight - cameraPos):Cross(rightVec).Unit
	local bottomNormal = rightVec:Cross(farPlaneBottomRight - cameraPos).Unit
	
	-- // distance2, farPlaneHeight2, farPlaneWidth2,    rightNormal, leftNormal, topNormal, bottomNormal, frustumCFrameInverse
	return distance2, farPlaneHeight2, farPlaneWidth2,    rightNormal, leftNormal, topNormal, bottomNormal, frustumCFrameInverse
	
end

function Helper.IsInView(Point: Vector3, CameraCF: CFrame, distance2: number, farPlaneHeight2: number, farPlaneWidth2: number, rightNormal: Vector3, leftNormal: Vector3, topNormal: Vector3, bottomNormal: Vector3, frustumCFrameInverse: CFrame): boolean	
	local relativeToOBB = frustumCFrameInverse * Point
	if
		relativeToOBB.X > farPlaneWidth2
		or relativeToOBB.X < -farPlaneWidth2
		or relativeToOBB.Y > farPlaneHeight2
		or relativeToOBB.Y < -farPlaneHeight2
		or relativeToOBB.Z > distance2
		or relativeToOBB.Z < -distance2
	then
		return false
	end
	
	local lookToPoint = Point - CameraCF.Position
	if
		rightNormal:Dot(lookToPoint) < 0
		or leftNormal:Dot(lookToPoint) < 0
		or topNormal:Dot(lookToPoint) < 0
		or bottomNormal:Dot(lookToPoint) < 0
	then
		return false
	end
	return true
end

function Helper.IsChunkInView(Point: Vector3, CameraCF: CFrame, distance2: number, farPlaneHeight2: number, farPlaneWidth2: number, rightNormal: Vector3, leftNormal: Vector3, topNormal: Vector3, bottomNormal: Vector3, frustumCFrameInverse: CFrame): boolean	
	local Original = Point
	for i = 1, 6 do
		if i ~= 1 then
			Point = Original + CHUNK_OFFSETS[i - 1]
		end
		local relativeToOBB = frustumCFrameInverse * Point
		if
			relativeToOBB.X > farPlaneWidth2
			or relativeToOBB.X < -farPlaneWidth2
			or relativeToOBB.Y > farPlaneHeight2
			or relativeToOBB.Y < -farPlaneHeight2
			or relativeToOBB.Z > distance2
			or relativeToOBB.Z < -distance2
		then
			continue
		end

		local lookToPoint = Point - CameraCF.Position
		if
			rightNormal:Dot(lookToPoint) < 0
			or leftNormal:Dot(lookToPoint) < 0
			or topNormal:Dot(lookToPoint) < 0
			or bottomNormal:Dot(lookToPoint) < 0
		then
			continue
		end
		return true
	end
	return false
end

function Helper.GetVertexColor(TransformY: number, VortexY: number, AlphaTransparency: number): Color3
	if TransformY < -1 then
		TransformY = -1
	end
	
	local VertexColor = COLOR_LOW:Lerp(COLOR_HIGH, min(((min(TransformY, COLOR_MAX_Y) + -1) * 4)  / 30, 1)) -- // v10: tope de altura para el color
	if AlphaTransparency < 1 then
		return VertexColor:Lerp(SHORE_COLOR, 1 - (AlphaTransparency / GOLDEN_RATIO))
	end
	
	if TransformY > _settings.WHITECAP_HEIGHT then
		-- // We'll do a mini-version of 'whitecaps' / 'foam' by changing the color to be white if the wave is steeper than usual
		VertexColor = VertexColor:Lerp(WHITECAP, (TransformY - _settings.WHITECAP_HEIGHT) / 10)
	end
	
	if VortexY < 0 then
		return VertexColor:Lerp(VORTEX_LOW, min(-VortexY / 60, 1))
	end
	return VertexColor
end

function Helper.GetVertexTransparency(VertexPosition: Vector3, Array: SharedTable, NormalizedDistanceToIsland: number): number
	if _settings.DEPTH_ENABLED == false then
		return 1
	end
	-- // alpha 1 = no transparency, alpha 0 = transparent
	-- // I would also like to note SharedTable's being way less performant than regular tables, which is very sad
	
	if NormalizedDistanceToIsland > 0.6 then
		return 1
	end
	
	local X, Z = VertexPosition.X, VertexPosition.Z
	local Hashed = Helper.HashVector(X, Z)
	
	if Array[Hashed] ~= nil then
		return Array[Hashed]
	end
	
	local Result = workspace:Raycast(VertexPosition + DEPTH_RAY_OFFSET, DEPTH_RAY, IslandParameters)
	if Result == nil then
		Array[Hashed] = 1
		return 1
	end
	
	local Depth = Result.Distance
	local Alpha = 1
	if Depth < 5 then
		Alpha = SHORE_TRANSPARENCY
	else
		Alpha = 0.2 + (Depth / 15)
	end
	Array[Hashed] = Alpha
	return Alpha
end

function Helper.IsVertexNearShore(VertexTransparency: number): boolean
	if VertexTransparency < 0.85 then
		return true
	end
	return false
end

function Helper.GetUV(UV: Vector2, t: number): Vector2
	local Scroll = -fmod(t * UV_SCROLL_SPEED, 1) -- TODO: Could probably optimize(?) by using something else in place of modulo
	local AdjustedUV = UV + v2(Scroll * SCROLL_DIRECTION_X, Scroll * SCROLL_DIRECTION_Y)
	return AdjustedUV
end


function Helper.Lerp(a: Vector3, b: Vector3, Alpha: number): Vector3
	return v3(
		a.X + (b.X - a.X) * Alpha,
		a.Y + (b.Y - a.Y) * Alpha,
		a.Z + (b.Z - a.Z) * Alpha
	)
end

function Helper.PointInEllipse(Point: Vector3, Center: Vector3, Size: Vector3): boolean
	local a = Size.X / 2
	local b = Size.Z / 2
	local deltaX = (Point.X - Center.X) / a
	local deltaZ = (Point.Z - Center.Z) / b
	local distanceSquared = (deltaX*deltaX) + (deltaZ*deltaZ)

	return distanceSquared <= 1
end

function Helper.ScaledDistance(Point: Vector3, Center: Vector3, Size: Vector3, Exponent: number): (number, number)
	local a = Size.X / 2
	local b = Size.Z / 2
	local deltaX = (Point.X - Center.X) / a
	local deltaZ = (Point.Z - Center.Z) / b

	local radialDistance = sqrt((deltaX*deltaX) + (deltaZ*deltaZ))
	local adjustedDistance = pow(radialDistance, Exponent)

	return max(0, 1 - adjustedDistance), max(0, 1 - radialDistance)
end

function Helper.GetIslandMultipliers(Point: Vector3, IslandPosition: Vector3, Radius: number): (number, number, number, boolean, number)
	local IslandPosition: Vector3 = IslandPosition
	local Distance = (Point - IslandPosition).Magnitude
	local SpeedMultiplier, PhaseMultiplier, AmplitudeMultiplier = 1, 1, 1
	local InRadius = Distance < Radius
	local NormalizedDistance = 1
	
	if InRadius then
		local Factor = Distance / Radius
		NormalizedDistance = Factor

		SpeedMultiplier = _settings.ISLAND_SPEED_MULTIPLIER
		PhaseMultiplier = _settings.ISLAND_PHASE_MULTIPLIER
		AmplitudeMultiplier = Factor
	end
	return SpeedMultiplier, PhaseMultiplier, AmplitudeMultiplier, InRadius, NormalizedDistance
end

function Helper.GetZoneMultipliers(Point: Vector3, ZonePosition: Vector3, ZoneParameters: ZoneParameters): (number, number, number, boolean)
	local Radius = ZoneParameters.Radius
	local Distance = (Point - ZonePosition).Magnitude

	local SpeedMultiplier, PhaseMultiplier, AmplitudeMultiplier = 1, 1, 1
	local InRadius = Distance < Radius
	if InRadius then
		local InverseRatio = 1 - (Distance / Radius)
		local Scaled = 1 + (ZoneParameters.AmplitudeMultiplier - 1) * InverseRatio

		SpeedMultiplier = ZoneParameters.SpeedMultiplier
		PhaseMultiplier = ZoneParameters.PhaseMultiplier
		AmplitudeMultiplier = Scaled
	end
	return SpeedMultiplier, PhaseMultiplier, AmplitudeMultiplier, InRadius
end

function Helper.HashVector(X: number, Z: number): number
	-- https://www.beosil.com/download/CollisionDetectionHashing_VMV03.pdf
	
	-- // Luau numbers are a double-precision (64-bit) floating-point number
	-- // However, the SharedTable limit is a nonnegative integer that can only go up to 2^32,
	-- //	So we'll bitwise AND it to 0xFFFFFFFF to ensure it's positive + stays within the 2^32 range
	-- //	Overall, we should be able to safely hash vectors in a large range, which is more than enough for our case
	
	return BAND((X * 73856093) + (Z * 83492791), 0xFFFFFFFF)
end

return Helper
