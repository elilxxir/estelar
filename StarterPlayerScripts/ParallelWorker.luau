-- script desactivado, hijo de OceanParallel

--!strict
--!native
--!optimize 2

-- // This is the parallel worker template.
-- // Depending on what WORKER_COUNT is configured to, there will be multiple instances of this script running.
-- // Each thread handles multiple ocean chunks, the total being divided equally between all workers to balance the load.

local AssetService = game:GetService('AssetService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local SharedTableRegistry = game:GetService('SharedTableRegistry')

local GerstnerWave = require(ReplicatedStorage.Gerstner)
local Helper = require(ReplicatedStorage.Helper)
local HeightLookup = require(ReplicatedStorage.HeightLookup)
local _settings = require(ReplicatedStorage.Settings)
local Types = require(ReplicatedStorage.Types)

local clamp = math.clamp
local XZ_INCLUDE = Vector3.new(1, 0, 1)
local Y_AXIS = Vector3.yAxis
local v3new = Vector3.new
local v3zero = Vector3.zero
local v3one = Vector3.one

local LERP_MAX_FRAMES = 30 -- // How many frames a vertex will 'lerp' for
local WORKER_COUNT = _settings.WORKER_COUNT

local GRID_SETTINGS = _settings.GRID_SETTINGS
local Camera = workspace.Camera


local Actor: Actor = script:GetActor()
local LastPlanePosition = Vector3.zero
GerstnerWave:SET_SETTINGS(GRID_SETTINGS.Padding, GRID_SETTINGS.Width, GRID_SETTINGS.Length, GRID_SETTINGS.PaddingMultiplier, GRID_SETTINGS.UV_SCALE)

local RS = game:GetService('RunService')
local ChunkInfo: { [Vector3]: Types.ChunkKey } = {}

Actor:BindToMessage('UpdateChunk', function(Position, Data)
	-- // "Position" should be in local space (Offset)
	ChunkInfo[Position] = Data
end)

local VertexTransparencyArray = SharedTableRegistry:GetSharedTable('VertexTransparency')

Actor:BindToMessage('Compute', function(waves, Plane: MeshPart, EditableMesh: EditableMesh, AssignedChunks: {Vector3}, VI, CI, SerializedChunks) 

	-- // The worker thread has received a message from the main thread to begin simulating the assigned chunks.
	-- // It also sends over the "VertexInfo" table, the "ChunkInfo" table, and the "_CHUNKS" table.
	-- // However, due to these tables being passed over VMs, they are serialized
	-- // So we need to (annoyingly) deserialize them

	local VertexCount = 0
	local VertexInfo: { Types.VertexKey } = {}
	for Key, Info in VI do
		Key = tonumber(Key)
		VertexInfo[Key:: number] = Info
		VertexCount += 1
	end

	for i, Position in CI do
		local v3 = tostring(i)

		local sX, sY, sZ = v3:match("(%-?%d+), (%-?%d+), (%-?%d+)")
		local X, Y, Z = tonumber(sX), tonumber(sY), tonumber(sZ)
		local vec = v3new(X, Y, Z)
		
		local Info: Types.ChunkKey = {
			Rendering = false,
			ISLAND = nil
		}
		ChunkInfo[vec] = Info
	end

	local _CHUNKS: { [Vector3]: { number } } = {}
	for i,v in SerializedChunks do
		local v3 = tostring(i)

		local sX, sY, sZ = v3:match("(%-?%d+), (%-?%d+), (%-?%d+)")
		local X, Y, Z = tonumber(sX), tonumber(sY), tonumber(sZ)
		local vec = v3new(X, Y, Z)

		_CHUNKS[vec] = v
	end

	-- // Connect to RunService.Heartbeat in parallel.
	-- // We'll begin simulating the assigned chunks we were given
	-- // in this event

	local FOV = Camera.FieldOfView
	Camera:GetPropertyChangedSignal('FieldOfView'):Connect(function()
		FOV = Camera.FieldOfView
	end)
	print('VERTEX COUNT: ', VertexCount)
	local Computations: Types.Computations = table.create(VertexCount + 1):: Types.Computations
	
	local PlaneSize = Plane.Size
	RS.Heartbeat:ConnectParallel(function(dt: number)
		-- // We store a bunch of variables early on that we'll be repetitively using below,
		-- // this is due to a micro-optimization with __index calls 
		-- // saving slight-moderate performance (depends on the case).
		local CameraCF = Camera.CFrame
		local distance2, farPlaneHeight2, farPlaneWidth2, rightNormal, leftNormal, topNormal, bottomNormal, frustumCFrameInverse = Helper.GetFrustumPlanes(_settings.FrustumRenderDistance, CameraCF)

		local objectCFrame = Plane.CFrame
		local ObjectPosition = Plane.Position
		local CameraPosition = CameraCF.Position
		local CameraXZ = CameraPosition * XZ_INCLUDE
		local VertexCount, VertexCount2 = 0, 0
		local t = workspace:GetServerTimeNow()

		-- // Create an array that will store the results of our parallel calculations
		-- // Since we can't edit the vertices in parallel, we use this table to edit all the vertices at once
		-- // Once we switch back to serial (task.synchronize)

		local Active = false -- // This variable is for determining whether any of the assigned chunks are "active" (rendering)

		debug.profilebegin('Ocean update')

		for i, ChunkOffset in AssignedChunks do
			local ChunkPosition = ObjectPosition + ChunkOffset
			
			local ChunkData = ChunkInfo[ChunkOffset]
			local DistanceToChunk = (ChunkPosition - CameraXZ).Magnitude
			local LOWER_QUALITY = DistanceToChunk > _settings.LowRenderDistance * 2

			-- // Use frustum culling in order to
			-- // not render any chunks that aren't on the screen
			-- // leading to some moderate performance gains

			if DistanceToChunk > _settings.MaxChunkRenderDistance or Helper.IsChunkInView(ChunkPosition, CameraCF, distance2, farPlaneHeight2, farPlaneWidth2, rightNormal, leftNormal, topNormal, bottomNormal, frustumCFrameInverse) == false then
				ChunkData.Rendering = false
				continue
			end

			Active = true
			local ChunkIsland = ChunkData.ISLAND
			local IslandPosition, IslandRadius = Vector3.zero, 0

			local ChunkZone = ChunkData.ZONE
			local ZonePosition = Vector3.zero
			local ZoneParameters: Helper.ZoneParameters? = nil
			local WhirlpoolParams: Helper.ZoneParameters? = nil

			if ChunkIsland then
				IslandPosition = ChunkIsland[1]:: Vector3
				IslandRadius = ChunkIsland[2]:: number
			end
			if ChunkZone then
				ZonePosition = ChunkZone[1].Position:: Vector3
				ZoneParameters = ChunkZone[2]:: Helper.ZoneParameters
				if ZoneParameters ~= nil and ZoneParameters.Type == 'Whirlpool' then
					WhirlpoolParams = ZoneParameters
				end
			end
			-- // Once the chunk has been validated to be inside the field of view,
			-- // we loop through all of its vertices so we can calculate the next position of it

			local Vertices = _CHUNKS[ChunkOffset]
			for i, VertexId in Vertices do
				local Info = VertexInfo[VertexId]
				local Displacement, Dampening = v3zero, v3one

				local PhaseMultiplier, SpeedMultiplier, AmplitudeMultiplier = 1, 1, 1
				local VertexInIslandRange = false
				local NormalizedDistanceToIsland = 1

				if ChunkIsland then
					debug.profilebegin('Island check')
					local Vertex = Info.Position
					local SeaPosition = Vertex + ObjectPosition
					SpeedMultiplier, PhaseMultiplier, AmplitudeMultiplier, VertexInIslandRange, NormalizedDistanceToIsland = Helper.GetIslandMultipliers(SeaPosition, IslandPosition, IslandRadius)

					debug.profileend()
				end
				if ChunkZone and VertexInIslandRange == false and ZoneParameters ~= nil and ZoneParameters.Type ~= 'Whirlpool' then
					debug.profilebegin('Zone check')
					local Vertex = Info.Position
					local SeaPosition = Vertex + ObjectPosition
					local VertexInRange = false
					
					SpeedMultiplier, PhaseMultiplier, AmplitudeMultiplier, VertexInRange = Helper.GetZoneMultipliers(SeaPosition, ZonePosition, ZoneParameters:: Helper.ZoneParameters)
					debug.profileend()
				end

				-- // If the distance to the chunk is some considerable away from the camera,
				-- // we don't prioritize rendering on this chunk and instead render it 'slowly',
				-- // using Vector3.Lerp to smoothly transition the vertex from one position to the other
				-- // this allows us to call the Gerstner computation less, at the cost of some smoothness / detail
				-- // however it is unnoticeable due to the distance.
				-- // Has moderate performance gains
				if Info.QUALITY_LEVEL == 2 and ZoneParameters == nil then
					debug.profilebegin('LOW-Chunk')

					local vertex = Info.Position
					VertexCount2 += 1

					local SeaPosition = ObjectPosition + Info.Position
					if ChunkData.Rendering == false or Info.CurrentFrame >= LERP_MAX_FRAMES or Info.Lerping == false or LastPlanePosition ~= ObjectPosition then
						local PreviousGoal = Info.GoalPosition

						-- // If the plane's position changed relative to where we last tracked it,
						-- // we have to forcefully update the vertex, as well as
						-- // the "goal position" of the lerp, otherwise it will look very desynced

						if LastPlanePosition ~= ObjectPosition or Info.Lerping == false or ChunkData.Rendering == false then
							local Transform = GerstnerWave.ComputeTransform(waves, SeaPosition, t, PhaseMultiplier, SpeedMultiplier, AmplitudeMultiplier)
							local Position = vertex + (Transform)

							PreviousGoal = Position
						end

						local Transform = 
							GerstnerWave.ComputeTransform(waves, SeaPosition, t + (dt * LERP_MAX_FRAMES), PhaseMultiplier, SpeedMultiplier, AmplitudeMultiplier)

						Info.GoalPosition = vertex + Transform
						Info.LastPosition = PreviousGoal or EditableMesh:GetPosition(VertexId)

						Info.CurrentFrame = (dt * LERP_MAX_FRAMES)

						Info.Lerping = true
					end

					if Info.Lerping == true then

						-- // We proceed with normal lerping behavior

						local CurrentFrame = Info.CurrentFrame
						local LastPosition = Info.LastPosition
						local GoalPosition = Info.GoalPosition

						local UVId = Info.UVId
						local ColorId = Info.ColorId

						local CurrentLerpPosition = Helper.Lerp(LastPosition, GoalPosition, CurrentFrame / LERP_MAX_FRAMES)

						CurrentFrame += 1
						Info.CurrentFrame = CurrentFrame

						local Transform = CurrentLerpPosition - vertex

						local ShoreTransparency = Helper.GetVertexTransparency(SeaPosition, VertexTransparencyArray, NormalizedDistanceToIsland)
						if Helper.IsVertexNearShore(ShoreTransparency) then
							Dampening += v3new(0, -0.85, 0)
						end

						local UpdateSecondary = true
						if LOWER_QUALITY == true and VertexInIslandRange == false then
							if Info.AlphaTransparency == 1 and Info.CurrentColor == _settings.WAVE_COLORS.TROUGH then
								UpdateSecondary = false
							end
						end

						local VertexColor = LOWER_QUALITY == true and _settings.WAVE_COLORS.TROUGH or Helper.GetVertexColor(Transform.Y, 0, ShoreTransparency)
						Computations[VertexId] = {
							CurrentLerpPosition * Dampening,

							UpdateSecondary == true and ColorId or nil,
							UpdateSecondary == true and VertexColor or nil,

							UVId,
							Helper.GetUV(Info.UV, t),

							UpdateSecondary == true and ShoreTransparency or nil,
						}
						Info.AlphaTransparency = ShoreTransparency
						Info.CurrentColor = VertexColor
					end

					debug.profileend()
					continue
				end

				-- // This section is for high-detail vertices, 
				-- // where we update their position directly according to the Gerstner formula
				-- // each frame, making the waves near the camera look much smoother 

				debug.profilebegin('HIGH-Chunk')
				local vertex = Info.Position
				local ColorId = Info.ColorId
				local UVId = Info.UVId
				local VortexOffsetY = 0

				local SeaPosition = ObjectPosition + vertex
				local ShoreTransparency = Helper.GetVertexTransparency(SeaPosition, VertexTransparencyArray, NormalizedDistanceToIsland)

				local Transform = GerstnerWave.ComputeTransform(waves, SeaPosition, t, PhaseMultiplier, SpeedMultiplier, AmplitudeMultiplier)
				local UpdatedUV = Helper.GetUV(Info.UV, t)
				local FinalPosition = vertex + Transform

				if WhirlpoolParams ~= nil then
					local VortexOffset, UVOffset = GerstnerWave.GetVortexTransform(WhirlpoolParams, SeaPosition, Info.UV, t, ObjectPosition)
					FinalPosition += VortexOffset
					UpdatedUV += UVOffset
					VortexOffsetY = VortexOffset.Y
				end
				
				-- // We'll further reduce the amplitude if the vertex is near the shore
				if Helper.IsVertexNearShore(ShoreTransparency) then
					Dampening += v3new(0, -0.85, 0)
				end

				Info.Lerping = false
				VertexCount += 1
				
				local UpdateSecondary = true
				if ShoreTransparency == Info.AlphaTransparency then
					UpdateSecondary = false
				end
				Computations[VertexId] = {
					(FinalPosition * Dampening) + Displacement,

					ColorId,
					Helper.GetVertexColor(Transform.Y, VortexOffsetY, ShoreTransparency),

					UVId,
					UpdatedUV,

					UpdateSecondary == true and ShoreTransparency or nil,
				}
				Info.AlphaTransparency = ShoreTransparency
				debug.profileend()
			end

			ChunkData.Rendering = true
		end

		debug.profileend()

		-- // If we're rendering any chunks, we'll need to update their positions
		-- // to do this, we need to switch back to the serial state (task.synchronize)
		-- // then manually update each vertex and color data

		-- // TODO: Switch to bulk :SetPosition() updates once ROBLOX releases it
		if Active == true then
			task.synchronize()
			debug.profilebegin('Serial Update')
			
			-- // We have to be sparse with what we update here, as updating too many things at once can lead to very high ms
			-- // ROBLOX batch update function plz

			for VertexId, Result in Computations do
				local ColorId = Result[2]:: number?
				local UVId = Result[4]:: number
				
				if ColorId ~= nil then
					local Alpha = Result[6]:: number?
					EditableMesh:SetColor(ColorId, Result[3]:: Color3)

					if Alpha ~= nil then
						EditableMesh:SetColorAlpha(ColorId, Alpha)
					end
				end
				EditableMesh:SetPosition(VertexId, Result[1]:: Vector3)
				EditableMesh:SetUV(UVId, Result[5]:: Vector2)
			end

			table.clear(Computations)
			debug.profileend()
		end

		LastPlanePosition = ObjectPosition
	end)

end)