-- script dentro de StarterPlayer >> StarterPlayerScripts

--!strict
--!native
--!optimize 2

--[[
	Gerstner Wave System
	@FlameEmber06
	
	Special thanks to @N0tKep, @SkySickz, @NewPuncher and @excuseslewis
	
	Simulates an ocean system on a mesh plane, with Gerstner waves.
	Uses Luau's parallel framework to run the ocean on multiple threads.
	
	Features:
		- Multithreading (Parallel Lua)
		- Frustum culling
		- Vertex lerping / LOD for vertices far from the camera
		- Customizable settings for the ocean
		- Infinite (ocean plane repositions to follow the camera)
		- Vertex coloring / Depth coloring
		- UV texture scrolling
		- Accurate & performant height lookups
			- Buoyancy / BoatManager module for boats
		- ZoneManager system, allowing for custom ocean zones with different parameters
		- Whirlpools
		- Subdivided mesh which acts as a grid
		- Shorelines (vertices are slightly transparent and colored differently near shallow water)
		
	Future Improvements:
		- Bulk updates for :SetPosition() [ROBLOX has no API for this yet]
		- Ocean tides
		
		- Plane instancing: Have multiple planes around you in a grid, all linked to the same EditableMesh.
			Note: You'd have to disable Frustum Culling for this to work properly, or have a second "low-res" EditableMesh 
			that has all its vertices also updated and instance that one around the 'main' ocean plane. Would allow you to stretch the
			ocean much further than you currently can with this system.
		
		- Calculate normals: Normals aren't calculated for the ocean, although this is relatively easy to do, 
			and I've implemented the functions for doing so in the Gerstner module already.
		
		- Better Subsurface Scattering: Instead of simply coloring waves on height, can also have the color depend on the angle of
			the camera towards the ocean plane, as well as the sun's direction to be more realistic.
			For those interested in approaching this, I'd recommend looking into the Fresnel effect.
		
		- Better Zone Handling: Instead of zones just being simple multipliers on the wave parameters, it'd be better to assign them
			their own wave parameters and smoothly interpolate between a set of wave parameters to the other 
			depending on distance.
	
	Limitations:
		Height Lookup: This relies on computing triangles based on a flat grid, but if vertices are very deformed on the XZ axis, there's a 
			good chance that the height lookup will fail due to the function scanning the wrong triangles. I've added a workaround to this,
			but there can still be incorrect heights given if the vertices are extremely deformed.
		   
		Whirlpool UV rotation: Due to the UV's of the ocean itself being rotated near whirlpools, there is UV distortion around
			the borders of the whirlpool.
			
		Vertex Popping: Due to the way LOD is handled, vertices can occasionally 'pop' when the ocean plane readjusts itself to follow
			the camera, depending on your wave parameters. This is specifically due to the LOD having no smooth transition 
			between different levels. If anyone wants to improve upon the system, I recommend looking into Continuous LOD systems (CLOD)
		
]]

local AssetService = game:GetService('AssetService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local SharedTableRegistry = game:GetService('SharedTableRegistry')

local GerstnerWave = require(ReplicatedStorage.Gerstner)
local Helper = require(ReplicatedStorage.Gerstner.Helper)
local HeightLookup = require(ReplicatedStorage.Gerstner.HeightLookup)
local _settings = require(ReplicatedStorage.Gerstner.Settings)
local Types = require(ReplicatedStorage.Gerstner.Types)

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

local Actor: Actor? = script:GetActor()
local LastPlanePosition = Vector3.zero
GerstnerWave:SET_SETTINGS(GRID_SETTINGS.Padding, GRID_SETTINGS.Width, GRID_SETTINGS.Length, GRID_SETTINGS.PaddingMultiplier, GRID_SETTINGS.UV_SCALE)

do
	-- // This is the "main" thread that will set up all the workers
	-- // as well as the EditableMesh (Plane)

	local ChunkCount = 0

	local BoatManager = require(ReplicatedStorage.Gerstner.Serial.BoatManager)
	local ZoneManager = require(ReplicatedStorage.Gerstner.Serial.ZoneManager)
	local Setup = require(ReplicatedStorage.Gerstner.Serial.Setup)


	local VertexPositionToId: { [Vector3]: number } = {}
	local VertexInfo: { [number]: Types.VertexKey } = {}
	local CI = {}
	local ChunkInfo: { [Vector3]: Types.ChunkKey } = {}

	local _CHUNKS = {}
	local _QUADS: any = {}
	local _TRIANGLES: any = {}

	Setup._QUADS = _QUADS
	Setup._TRIANGLES = _TRIANGLES
	Setup.VertexPositionToId = VertexPositionToId
	Setup.VertexInfo = VertexInfo
	Setup.SETTINGS = table.clone(GRID_SETTINGS)

	local function SetupSecondaryIds(EditableMesh: EditableMesh, Info: { Types.VertexKey })
		-- // We grab the colors and UVs of the EditableMesh, each linked to a certain vertex
		-- // so that we can apply them to the specific vertex later on

		for i, ColorId in EditableMesh:GetColors() do
			local VertexId = EditableMesh:GetVerticesWithAttribute(ColorId)[1]
			if Info[VertexId] then
				Info[VertexId].ColorId = ColorId
				EditableMesh:SetColor(ColorId, Helper.GetVertexColor(0, 0, 1))
			end
		end
		for i, UVId in EditableMesh:GetUVs() do
			local VertexId = EditableMesh:GetVerticesWithAttribute(UVId)[1]
			if Info[VertexId] then
				Info[VertexId].UVId = UVId
				EditableMesh:SetUV(UVId, Info[VertexId].UV)
			end
		end
	end
	
	-- // Create a bunch of worker threads and place them under the main thread
	local workers = {}
	for i = 1, _settings.WORKER_COUNT do
		local actor = Instance.new('Actor')
		local ParallelWorker = script.ParallelWorker:Clone()
		ParallelWorker.Enabled = true
		ParallelWorker.Parent = actor
		table.insert(workers, actor)
	end
	for _, actor in workers do
		actor.Parent = script
	end

	local EditableMesh = Setup.SetupEditableMesh() 
	for i, SubdivisionRadius in _settings.Subdivisions do
		Setup.SubdividePlane(SubdivisionRadius:: number, true, EditableMesh)
	end

	local Plane = Setup.GetPlaneFromEditableMesh(EditableMesh, nil)
	if _settings.DEPTH_ENABLED == true then
	
		warn('WARNING: "DEPTH_ENABLED" setting is set to true, which may lead to some render issues.\nSee known issues section in: https://devforum.roblox.com/t/client-beta-in-experience-mesh-image-apis-now-available-in-published-experiences/3267293')
	end
	
	if _settings.FRUSTUM_CULLING_FIX == true then
		-- // Because of a bounding box issue with ROBLOX's frustum culling, we'll insert a highlight into the ocean plane so that it is rendered
		-- // at all times. ROBLOX has plans to fix this, but until then, we need to insert a highlight to force rendering.
		Instance.new('Highlight', Plane).Enabled = false
	end
	
	do
		-- // Begin creating chunks based off the vertices of the mesh
		-- // We'll be using these chunks in order to update the vertices in an optimized manner

		local CHUNK_SIZE = GRID_SETTINGS.CHUNK_SIZE
		for _, VertexId in EditableMesh:GetVertices() do
			if VertexInfo[VertexId] == nil then
				continue
			end
			local Position = Plane.CFrame * EditableMesh:GetPosition(VertexId)
			Position = v3new(math.round(Position.X / CHUNK_SIZE) * CHUNK_SIZE, 0, math.round(Position.Z / CHUNK_SIZE) * CHUNK_SIZE)
			local Distance = (Position - Plane.Position).Magnitude

			if Distance > _settings.MaxChunkRenderDistance then
				continue
			end

			if _CHUNKS[Position] == nil then
				ChunkCount += 1
				_CHUNKS[Position] = {VertexId}
				
				local Info: Types.ChunkKey = {
					Rendering = false,
					ISLAND = nil,
				}
				ChunkInfo[Position] = Info
			else
				table.insert(_CHUNKS[Position], VertexId)
			end
		end

		SetupSecondaryIds(EditableMesh, VertexInfo)
	end
	
	-- // Here, we go over all of the chunks we have and assign them to a worker.
	-- // It is done this way so that each worker has an equal amount of chunks to iterate through
	-- // so the load is balanced across all the workers

	local WorkerAssignments = {}
	local ChunkToWorker = {}
	local i = 0
	for ChunkPosition, Vertices in _CHUNKS do
		i += 1
		local worker_index = (i - 1) % WORKER_COUNT + 1
		table.insert(CI, ChunkPosition)

		if not WorkerAssignments[worker_index] then
			WorkerAssignments[worker_index] = {
				AssignedChunks = {},
				VertexInfo = {},
				ChunkInfo = {},
			}
		end
		for n, VertexId in Vertices do
			WorkerAssignments[worker_index].VertexInfo[VertexId] = VertexInfo[VertexId]
		end
		WorkerAssignments[worker_index].ChunkInfo[ChunkPosition] = ChunkInfo[ChunkPosition]

		table.insert(WorkerAssignments[worker_index].AssignedChunks, ChunkPosition)
		ChunkToWorker[ChunkPosition] = workers[worker_index]
	end

	if _settings.DEBUG == true then
		local TRI_COUNT = Helper.GetTableLength(_TRIANGLES)
		warn(`TOTAL CHUNKS: {ChunkCount}`)
		warn(`WORKER COUNT: {WORKER_COUNT}`)
		warn(`TOTAL TRIANGLES: {TRI_COUNT} ({Helper.GetTableLength(VertexInfo)} VERTICES)`)
	end
	
	do
		-- // We don't need these tables anymore, so clear them from memory
		Setup._QUADS = nil
		Setup._TRIANGLES = nil
		table.clear(_TRIANGLES)
		table.clear(_QUADS)
		_TRIANGLES = nil
		_QUADS = nil
	end

	local SecondaryPlanes = Setup.SetupSecondaryPlanes(EditableMesh)
	
	task.defer(function()
		-- // Once our worker table is ready, we loop through it and send a message to
		-- // the worker in order to begin the simulation
		local VertexTransparencyArray = SharedTable.new()
		SharedTableRegistry:SetSharedTable('VertexTransparency', VertexTransparencyArray)

		for worker_index, _DATA in WorkerAssignments do
			local AssignedChunks = _DATA.AssignedChunks
			local AssociatedVertexInfo = _DATA.VertexInfo
			local AssociatedChunkInfo = _DATA.ChunkInfo

			local worker = workers[worker_index]
			if _settings.DEBUG == true then
				warn('Sending compute message to worker ' .. tostring(worker_index) .. ' for chunks ', AssignedChunks)
			end
			worker:SendMessage('Compute', _settings.Waves, Plane, EditableMesh, AssignedChunks, AssociatedVertexInfo, AssociatedChunkInfo, _CHUNKS)
		end

	end)
	HeightLookup.ClientInit(VertexPositionToId, EditableMesh, Plane)

	local WakeTracker = require((ReplicatedStorage:FindFirstChild("Serial", true) :: any).WakeTracker)
	task.spawn(function()
		while true do
			task.wait(0.1)
			local flat = WakeTracker.Update()
			for _, actor in workers do
				actor:SendMessage('WakeUpdate', flat)
			end
		end
	end)

	-- // For the main thread itself, we have our own loop that moves the plane mesh with us
	-- // This allows us to have an 'infinite' effect on the ocean

	local function UpdateIslands()
		local GRID_AREA = GRID_SETTINGS.Width * GRID_SETTINGS.Padding + (GRID_SETTINGS.Width - 1) * GRID_SETTINGS.Padding
		local CameraPosition = Camera.CFrame.Position * XZ_INCLUDE
		local NearbyIslands = ZoneManager.ISLAND_TREE:GetNearest(CameraPosition, GRID_AREA)
		local FilledChunks = {}

		for i, Node in NearbyIslands do
			-- // There are island(s) near the camera, and thus, they are also in our grid			
			local Island, Radius = Node.Object.Island, Node.Object.Radius
			local IslandCenter = Node.Position
			for ChunkOffset, Vertices in _CHUNKS do
				local ChunkPosition = Plane.Position + ChunkOffset
				local Distance = (ChunkPosition - IslandCenter).Magnitude
				if FilledChunks[ChunkOffset] then
					if Distance > FilledChunks[ChunkOffset] then
						continue
					end
				end
				if math.floor(Distance) < Radius then
					local Info: {number | any} = {
						[1] = Island.Center.Position,
						[2] = Radius / 2,
					}
					FilledChunks[ChunkOffset] = Distance
					ChunkInfo[ChunkOffset].ISLAND = Info
					ChunkToWorker[ChunkOffset]:SendMessage('UpdateChunk', ChunkOffset, ChunkInfo[ChunkOffset])
				end
			end
		end
		for ChunkOffset, Vertices in _CHUNKS do
			if FilledChunks[ChunkOffset] == nil then
				local Info = ChunkInfo[ChunkOffset]
				if Info.ISLAND ~= nil then
					Info.ISLAND = nil
					ChunkToWorker[ChunkOffset]:SendMessage('UpdateChunk', ChunkOffset, ChunkInfo[ChunkOffset])
				end
			end
		end
		table.clear(FilledChunks)
	end
	local function UpdateZones()
		local GRID_AREA = GRID_SETTINGS.Width * GRID_SETTINGS.Padding + (GRID_SETTINGS.Width - 1) * GRID_SETTINGS.Padding
		local CameraPosition = Camera.CFrame.Position * XZ_INCLUDE
		local NearbyZones = ZoneManager.ZONE_TREE:GetNearest(CameraPosition, GRID_AREA)

		local FilledChunks = {}

		for i, Node in NearbyZones do
			local ZoneParameters, Radius = Node.Object, Node.Object.Radius

			for ChunkOffset, Vertices in _CHUNKS do
				local ChunkPosition = (Plane.Position + ChunkOffset) * XZ_INCLUDE
				local ZoneCenter = ZoneParameters.Link.Position * XZ_INCLUDE
				local Distance = (ChunkPosition - ZoneCenter).Magnitude

				if math.floor(Distance) < Radius * 2 then
					local Info: {number | any} = {
						[1] = ZoneParameters.Link,
						[2] = ZoneParameters,
					}
					FilledChunks[ChunkOffset] = true
					ChunkInfo[ChunkOffset].ZONE = Info
					ChunkToWorker[ChunkOffset]:SendMessage('UpdateChunk', ChunkOffset, ChunkInfo[ChunkOffset])
				end
			end
		end
		for ChunkOffset, Vertices in _CHUNKS do
			if FilledChunks[ChunkOffset] ~= true then
				local Info = ChunkInfo[ChunkOffset]
				if Info.ZONE ~= nil then
					Info.ZONE = nil
					ChunkToWorker[ChunkOffset]:SendMessage('UpdateChunk', ChunkOffset, ChunkInfo[ChunkOffset])
				end
			end
		end
		table.clear(FilledChunks)
	end

	ZoneManager.ZoneUpdated:Connect(function()
		UpdateZones()
	end)

	while true do
		local dt = task.wait(0.1)
		local distance2, farPlaneHeight2, farPlaneWidth2, rightNormal, leftNormal, topNormal, bottomNormal, frustumCFrameInverse = Helper.GetFrustumPlanes(_settings.FrustumRenderDistance, Camera.CFrame)

		local Padding = GRID_SETTINGS.Padding
		local Multiplier = GRID_SETTINGS.PaddingMultiplier

		local CameraPosition = Camera.CFrame.Position * XZ_INCLUDE
		local modPosition = v3new(CameraPosition.X % (Padding * Multiplier), 0, CameraPosition.Z % (Padding * Multiplier))

		local PlanePosition = Plane.Position
		local ObjectPosition = PlanePosition * Vector3.yAxis + (CameraPosition - modPosition)

		if LastPlanePosition ~= ObjectPosition then
			UpdateIslands()
			UpdateZones()
			Plane.Position = ObjectPosition

			for i, SecondaryPlane in SecondaryPlanes do
				local SP = SecondaryPlane[1]:: MeshPart
				local Offset = SecondaryPlane[2]:: Vector3

				SP.Position = ObjectPosition + Offset
			end
		end

		LastPlanePosition = ObjectPosition
	end
end
