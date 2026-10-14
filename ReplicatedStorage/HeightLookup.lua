-- script hijo de Gerstner

--!native
--!optimize 2
--!strict

--[[
	@FlameEmber06
	Performant and accurate height lookup module for the ocean.
]]

local QuadInfo = {}
local IS_SERVER = game:GetService('RunService'):IsServer()

-- // These are our triangle maps based off our ADJACENT_OFFSETS.
-- // Should be unedited, unless the order of values in ADJACENT_OFFSETS are swapped.
local TRIANGLE_MAP_1 : { number? } = {nil, nil, nil, nil, nil, nil, 1, 5}
local TRIANGLE_MAP_2 : { number  } = {1, 2, 1, 4, 3, 5, 			2, 6}
local TRIANGLE_MAP_3 : { number  } = {2, 3, 4, 5, 6, 6, 			8, 7}

local _settings = require(script.Parent.Settings)
local Subdivisions = #_settings.Subdivisions
local Padding = _settings.GRID_SETTINGS.Padding / math.pow(2, Subdivisions)

local PLANE_OFFSET_Y = _settings.GRID_SETTINGS.PLANE_OFFSET.Y
local RAY_DISTANCE = _settings.GRID_SETTINGS.PLANE_OFFSET.Y + 5

local ADJACENT_OFFSETS = {
	Vector3.new(Padding, 0, 0),
	Vector3.new(0, 0, Padding),

	Vector3.new(-Padding, 0, Padding),
	Vector3.new(Padding, 0, -Padding),

	Vector3.new(0, 0, -Padding),
	Vector3.new(-Padding, 0, 0),
	
	Vector3.new(-Padding, 0, -Padding),
	Vector3.new(Padding, 0, Padding),
}

local SEARCH_OFFSETS = {
	Vector3.new(Padding, 0, 0),
	Vector3.new(0, 0, Padding),

	Vector3.new(-Padding, 0, Padding),
	Vector3.new(Padding, 0, -Padding),

	Vector3.new(0, 0, -Padding),
	Vector3.new(-Padding, 0, 0),

	Vector3.new(-Padding, 0, -Padding),
	Vector3.new(Padding, 0, Padding), 
	
	Vector3.new(Padding * 2, 0, Padding),
	Vector3.new(Padding * 2, 0, Padding * 2),
	Vector3.new(Padding * 2, 0, 0),
	Vector3.new(Padding * 2, 0, -Padding),
	Vector3.new(Padding * 2, 0, -Padding * 2),

	Vector3.new(-Padding * 2, 0, Padding),
	Vector3.new(-Padding * 2, 0, Padding * 2),
	Vector3.new(-Padding * 2, 0, 0),
	Vector3.new(-Padding * 2, 0, -Padding),
	Vector3.new(-Padding * 2, 0, -Padding * 2),


	Vector3.new(Padding, 0, Padding * 2),
	Vector3.new(0, 0, Padding * 2),
	Vector3.new(-Padding, 0, Padding * 2),

	Vector3.new(-Padding, 0, -Padding * 2),
	Vector3.new(0, 0, -Padding * 2),
	Vector3.new(Padding, 0, -Padding * 2),
}

local LOOKUP_METHODS = {
	PRECISE = "PRECISE",
	PRECISE_RAY = "RAY",
	
	FAST = "FAST",
}

local GerstnerModule = require(script.Parent)

local _PLANE : MeshPart? = nil
local EditableMesh: EditableMesh? = nil

local abs = math.abs
local v3new = Vector3.new
local round = math.round
local XZ_INCLUDE = Vector3.new(1, 0, 1)

--[[
	Returns the area of a triangle, given 3 vertices.
]]
local function GetTriangleArea(v1: Vector3, v2: Vector3, v3: Vector3): number
	-- // (1/2) [x1 (z2 - z3) + x2 (z3 - z1) + x3 (z1 - z2)]
	return 0.5 * abs(
		v1.X * (v2.Z - v3.Z) + 
			v2.X * (v3.Z - v1.Z) + 
			v3.X * (v1.Z - v2.Z)
	)
end

--[[
	Fetches the height of a point on a triangle, given 3 vertices and the point's position.
	Returns <code>nil</code> if the point is not on the plane of the triangle.
]]
local function GetHeight(point: Vector3, v1: Vector3, v2: Vector3, v3: Vector3): number?
	local A = GetTriangleArea(v1, v2, v3)
	local A1 = GetTriangleArea(point, v2, v3)
	local A2 = GetTriangleArea(v1, point, v3)
	local A3 = GetTriangleArea(v1, v2, point)
	
	-- // We use 1e-10 as a 'buffer' zone
	if abs(A - (A1 + A2 + A3)) < 1e-10 then
		-- // Barycentric coordinate math
		local h1, h2, h3 = v1.Y, v2.Y, v3.Y

		local weight1 = A1 / A
		local weight2 = A2 / A
		local weight3 = A3 / A

		return weight1 * h1 + weight2 * h2 + weight3 * h3
	end
	return nil
end


local HeightLookup = {}
local VertexPositionToId: { [Vector3]: number } = {}

HeightLookup.LOOKUP_METHODS = LOOKUP_METHODS
--[[
	Performs a height lookup at an XZ point. Offers lookup methods "PRECISE", "RAY" and "FAST"
	
	<strong>PRECISE:</strong> Performs an accurate height lookup off adjacent triangles.
	<strong>RAY:</strong> Performs an accurate height lookup using <code>EditableMesh.RaycastLocal</code>
	<strong>FAST:</strong> Performs an approximate height lookup through a modified formula. Prioritizes speed over accuracy.
	
	<code>UseNearbyVertices:</code> Determines whether the height lookup should use nearby mesh vertices to get the height instead of performing a Gerstner offset call for each vertex.
	Will have no effect if the server does a lookup with this set to <code>true</code>.
	
	Optional multipliers can be given, which are used for zone / island regions.
]]
function HeightLookup.Lookup(Point: Vector3, LOOKUP_METHOD: string, UseNearbyVertices: boolean, SpeedMultiplier: number?, PhaseMultiplier: number?, AmplitudeMultiplier: number?, ZONE: any?, TimeOffset: number?): number
	if _PLANE == nil and IS_SERVER == false then
		warn('[HeightLookup] Please set the _PLANE value of the module before calling \'Lookup\'.')
		return -1
	end
	local Plane, EM = nil, nil
	if IS_SERVER == false then 
		Plane = _PLANE:: MeshPart
		EM = EditableMesh:: EditableMesh
	end
	-- // Average performances were from testing the function on one point every heartbeat step.
	
	if LOOKUP_METHOD == LOOKUP_METHODS.PRECISE then -- // Average performance: ~0.01ms
		-- // 1. Get the nearest 'corner' point of a grid square relative to the point
		local Clamped = v3new(round(Point.X / Padding) * Padding, PLANE_OFFSET_Y, round(Point.Z / Padding) * Padding)
		if Subdivisions == 0 then
			Clamped += Vector3.new(Padding / 2, 0, Padding / 2)
		end
		
		-- // We define multiple 'region offset points' around our actual closest vertex. We do this due to limitation 1,
		-- // so that we still get a valid height even if the XZ positions of a vertex are very deformed / offset.
		-- // An example of this occurring would be being near or inside a whirlpool.
		-- // Doesn't seem to have a noticeable performance impact, with relatively low ms (~0.03ms) per frame.
		
		for SearchRegion = 0, 24 do
			-- // This is our corner point (which is a vertex)
			
			local CornerPosition = v3new(Clamped.X, 0, Clamped.Z)

			if SearchRegion ~= 0 then
				CornerPosition += (SEARCH_OFFSETS[SearchRegion] * 2)
			end
			
			local PlanePositionXZ = Vector3.zero
			if IS_SERVER == false then
				-- // We need to subtract the plane position as an offset to it so we can get it in local space for the client
				-- // We'll add this back later
				PlanePositionXZ = Plane.Position * XZ_INCLUDE
				CornerPosition -= PlanePositionXZ
			end
			
			
			-- // Because the adjacent table gives us our offsets in a specific order, we can easily 
			-- // create the 6 triangles using by mapping an iterator [i] from a loop to the indices
			-- // The index map would look like this:
			-- // {1, 2, 1, 4, 3, 5}
			-- // {2, 3, 4, 5, 6, 6}
			-- // Where triangle1 is points { Corner, Adj[1], Adj[2] }, triangle2 is { Corner, Adj[2], Adj[3] }, etc...
			
			-- // 2. Iterate through all the triangles in order to see which triangle we're on
			
			for i = 1, 8 do
				-- // Instead of having an array of adjacent corners, we can directly get the correct
				-- // adjacent grid corner that will form a triangle thanks to our triangle map array (memory safe)
				-- // Worst case: We loop through all 8 triangles in order to find the height
					-- // Best case: We get the height from 1 triangle (the first triangle we check)

				local CurrentAdjacent1 = CornerPosition
				local CurrentAdjacent2 = CornerPosition + ADJACENT_OFFSETS[TRIANGLE_MAP_2[i]]
				local CurrentAdjacent3 = CornerPosition + ADJACENT_OFFSETS[TRIANGLE_MAP_3[i]]
				if i == 7 or i == 8 then
					CurrentAdjacent1 = CornerPosition + ADJACENT_OFFSETS[TRIANGLE_MAP_1[i]:: number]
				end
				
				local v1, v2, v3 = Vector3.zero, Vector3.zero, Vector3.zero
				if UseNearbyVertices == true and IS_SERVER == false then
					local Vertex1Id = VertexPositionToId[CurrentAdjacent1]
					local Vertex2Id = VertexPositionToId[CurrentAdjacent2]
					local Vertex3Id = VertexPositionToId[CurrentAdjacent3]
					
					v1 = EM:GetPosition(Vertex1Id) + PlanePositionXZ
					v2 = EM:GetPosition(Vertex2Id) + PlanePositionXZ
					v3 = EM:GetPosition(Vertex3Id) + PlanePositionXZ
				else
					local t = workspace:GetServerTimeNow() + (TimeOffset or 0)
					-- // We apply our gerstner offsets to the triangle vertices, then check if we get a resulting height
					
					if IS_SERVER == false then
						CurrentAdjacent1 += PlanePositionXZ
						CurrentAdjacent2 += PlanePositionXZ
						CurrentAdjacent3 += PlanePositionXZ
					end

					v1 = CurrentAdjacent1 + GerstnerModule.ComputeTransform(_settings.Waves, CurrentAdjacent1, t, PhaseMultiplier, SpeedMultiplier, AmplitudeMultiplier)
					v2 = CurrentAdjacent2 + GerstnerModule.ComputeTransform(_settings.Waves, CurrentAdjacent2, t, PhaseMultiplier, SpeedMultiplier, AmplitudeMultiplier)
					v3 = CurrentAdjacent3 + GerstnerModule.ComputeTransform(_settings.Waves, CurrentAdjacent3, t, PhaseMultiplier, SpeedMultiplier, AmplitudeMultiplier)
					
					if ZONE ~= nil and ZONE.Type == 'Whirlpool' then
						v1 += GerstnerModule.GetVortexTransform(ZONE, CurrentAdjacent1, nil, t, nil)
						v2 += GerstnerModule.GetVortexTransform(ZONE, CurrentAdjacent2, nil, t, nil)
						v3 += GerstnerModule.GetVortexTransform(ZONE, CurrentAdjacent3, nil, t, nil)
					end
				end

				local Height = GetHeight(Point, v1, v2, v3)
				if Height ~= nil then
					-- // Once we've found a valid height, we don't need to iterate through any more triangles, so we immediately return
					return Height + PLANE_OFFSET_Y
				end
			end
		end
	elseif LOOKUP_METHOD == LOOKUP_METHODS.PRECISE_RAY then -- // Average performance: ~0.7ms
		-- // Performance is much slower compared to the default method as ROBLOX constructs a 
		-- // new KD tree everytime :RaycastLocal() is called (~0.57ms)
		
		-- // PRECISE_RAY can only be called from the client, as we need the mesh data to perform a local raycast.
		if IS_SERVER == true then
			warn('[HeightLookup] Attemped to call Lookup with PRECISE_RAY method on the server. Did you mean to call \'PRECISE\'?')
			return -1
		end
		local EM = EditableMesh:: EditableMesh
		
		-- // We'll cast a ray downards from the point, and check if we get any results
		local TriangleId, Height = EM:RaycastLocal(Point + Vector3.yAxis, -Vector3.yAxis * RAY_DISTANCE)
		if TriangleId ~= nil then
			-- // If we get a valid hit, we return the height
			return Height.Y + PLANE_OFFSET_Y
		end
		-- // In the case that we weren't able to, we return -1. This can occur if RAY_DISTANCE isn't large enough.
		-- // It's best to keep the distance short as longer raycasts can be more expensive.
		return -1
	elseif LOOKUP_METHOD == LOOKUP_METHODS.FAST then
		local t = workspace:GetServerTimeNow() + (TimeOffset or 0)
		return GerstnerModule:GetApproximateHeight(_settings.Waves, Point, t, PhaseMultiplier, SpeedMultiplier, AmplitudeMultiplier) + PLANE_OFFSET_Y
	end
	if _settings.DEBUG == true then
		warn('HEIGHT FAILED')
	end
	-- // In the case that we were not able to find a height for a given reason, we just return -1
	return -1
end

--[[
	Initializes the HeightLookup module for the client.
]]
function HeightLookup.ClientInit(Dictionary: { [Vector3]: number }, Mesh: EditableMesh, Plane: MeshPart)
	VertexPositionToId = Dictionary
	EditableMesh = Mesh
	_PLANE = Plane
end

return HeightLookup
