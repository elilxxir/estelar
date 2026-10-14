-- script dentro de carpeta Serial dentro de script Gerstner dentro de ReplicatedStorage

--!strict
--[[
	@FlameEmber06
	Setup helper module in order to define the plane mesh, as well as subdivide and stitch vertices.
]]

local AssetService = game:GetService('AssetService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local Types = require(script.Parent.Parent.Types)
local _settings = require(script.Parent.Parent.Settings)

local _QUADS: { [Vector3]: {} }? = {}
local _TRIANGLES: { [Vector3]: {} }? = {}
local VertexInfo: { Types.VertexKey } = {}


local Setup = {
	CurrentSubdivisions = 0,
	SETTINGS = {
		Padding = 0,
		Width = 0,
		Length = 0,
		UV_SCALE = 0,
		PLANE_OFFSET = Vector3.zero,
	},
	VertexInfo = VertexInfo,
	VertexPositionToId = {},
	
	_QUADS = _QUADS,
	_TRIANGLES = _TRIANGLES
}

local function GetMidpoint(a: Vector3, b: Vector3): Vector3
	return (a + b) / 2
end

local function MergeBorderVertex(EditableMesh: EditableMesh, VertexId: number, VertexPosition: Vector3, QuadCenter: Vector3, Subdivisions: number)
	local Displacement = (QuadCenter - VertexPosition)
	local Divisor = math.pow(2, Subdivisions)

	local VertexInfo = Setup.VertexInfo
	local GRID_SETTINGS = Setup.SETTINGS
	local VertexPositionToId = Setup.VertexPositionToId

	local _QUADS, _TRIANGLES = Setup._QUADS, Setup._TRIANGLES
	if _QUADS == nil or _TRIANGLES == nil then
		return
	end
	
	local Matched = false
	if Displacement.X < 0 then -- // left side (right side if inverted)
		Matched = true
		local TriangleCenter = VertexPosition + -Displacement
		local AdjacentMerge = VertexPosition + Vector3.new(0, 0, -GRID_SETTINGS.Padding / Divisor)
		local AdjacentMerge2 = VertexPosition + Vector3.new(0, 0, GRID_SETTINGS.Padding / Divisor)

		local CornerMerge = TriangleCenter + -Displacement + Vector3.new(0, 0, -GRID_SETTINGS.Padding / Divisor)
		local TriangleData = _TRIANGLES[TriangleCenter]
		
		local Index = (Setup.CurrentSubdivisions % 3) == 0 and 2 or 1
		EditableMesh:RemoveFace(TriangleData[Index])
		TriangleData[Index] = nil

		local Triangle1 = EditableMesh:AddTriangle(VertexPositionToId[CornerMerge], VertexPositionToId[AdjacentMerge], VertexId)
		local Triangle2 = EditableMesh:AddTriangle(VertexId, VertexPositionToId[AdjacentMerge2], VertexPositionToId[CornerMerge])
		table.insert(TriangleData, Triangle1)
		table.insert(TriangleData, Triangle2)

	elseif Displacement.X > 0 then -- // right side (left side if inverted)
		Matched = true
		local TriangleCenter = VertexPosition + -Displacement
		local AdjacentMerge = VertexPosition + Vector3.new(0, 0, GRID_SETTINGS.Padding / Divisor)
		local AdjacentMerge2 = VertexPosition + Vector3.new(0, 0, -GRID_SETTINGS.Padding / Divisor)

		local CornerMerge = TriangleCenter + -Displacement + Vector3.new(0, 0, GRID_SETTINGS.Padding / Divisor)
		local TriangleData = _TRIANGLES[TriangleCenter]
		
		local Index = (Setup.CurrentSubdivisions % 3) == 0 and 1 or 2
		EditableMesh:RemoveFace(TriangleData[Index])
		TriangleData[Index] = nil

		local Triangle1 = EditableMesh:AddTriangle(VertexPositionToId[CornerMerge], VertexPositionToId[AdjacentMerge], VertexId)
		local Triangle2 = EditableMesh:AddTriangle(VertexId, VertexPositionToId[AdjacentMerge2], VertexPositionToId[CornerMerge])
		table.insert(TriangleData, Triangle1)
		table.insert(TriangleData, Triangle2)
	end
	if Matched == false then
		if Displacement.Z > 0 then -- // bottom side (top side if inverted)
			local TriangleCenter = VertexPosition + -Displacement
			local AdjacentMerge = VertexPosition + Vector3.new(GRID_SETTINGS.Padding / Divisor, 0, 0)
			local AdjacentMerge2 = VertexPosition + Vector3.new(-GRID_SETTINGS.Padding / Divisor, 0, 0)

			local CornerMerge = TriangleCenter + -Displacement + Vector3.new(GRID_SETTINGS.Padding / Divisor, 0, 0)
			local TriangleData = _TRIANGLES[TriangleCenter]
			
			local Index = (Setup.CurrentSubdivisions % 3) == 0 and 1 or 2
			EditableMesh:RemoveFace(TriangleData[Index])
			TriangleData[Index] = nil

			local Triangle1 = EditableMesh:AddTriangle(VertexPositionToId[CornerMerge], VertexId, VertexPositionToId[AdjacentMerge])
			local Triangle2 = EditableMesh:AddTriangle(VertexPositionToId[CornerMerge], VertexPositionToId[AdjacentMerge2], VertexId)
			table.insert(TriangleData, Triangle1)
			table.insert(TriangleData, Triangle2)

		elseif Displacement.Z < 0 then -- // bottom side (top side if inverted)
			local TriangleCenter = VertexPosition + -Displacement
			local AdjacentMerge = VertexPosition + Vector3.new(-GRID_SETTINGS.Padding / Divisor, 0, 0)
			local AdjacentMerge2 = VertexPosition + Vector3.new(GRID_SETTINGS.Padding / Divisor, 0, 0)

			local CornerMerge = TriangleCenter + -Displacement + Vector3.new(-GRID_SETTINGS.Padding / Divisor, 0, 0)
			local TriangleData = _TRIANGLES[TriangleCenter]
			
			local Index = (Setup.CurrentSubdivisions % 3) == 0 and 2 or 1
			EditableMesh:RemoveFace(TriangleData[Index])
			TriangleData[Index] = nil

			local Triangle1 = EditableMesh:AddTriangle(VertexPositionToId[CornerMerge], VertexId, VertexPositionToId[AdjacentMerge])
			local Triangle2 = EditableMesh:AddTriangle(VertexPositionToId[CornerMerge], VertexPositionToId[AdjacentMerge2], VertexId)
			table.insert(TriangleData, Triangle1)
			table.insert(TriangleData, Triangle2)
		end
	end
end

local function GetUVCoordinates(Vx: number, Vz: number): Vector2
	
	local GRID_SETTINGS = Setup.SETTINGS
	local UVPadding = GRID_SETTINGS.UV_SCALE
	
	local Padding: number = GRID_SETTINGS.Padding
	local Width: number = GRID_SETTINGS.Width
	local Length: number = GRID_SETTINGS.Length

	local x = ((Vx + ((Padding * (Width - 1) / 2))) / Padding) + 1
	local y = ((Vz + ((Padding * (Length - 1) / 2))) / Padding) + 1

	return Vector2.new(x, y)
end

local function InsertToVertexInfo(EM: EditableMesh, Id: number)
	local VertexInfo = Setup.VertexInfo
	local GRID_SETTINGS = Setup.SETTINGS
	local VertexPositionToId = Setup.VertexPositionToId
	
	if VertexInfo[Id] ~= nil then
		return
	end
	
	local Position = EM:GetPosition(Id)
	local UV = GetUVCoordinates(Position.X, Position.Z)
	
	local QUALITY_LEVEL = 1
	local Distance = (Position - EM:GetCenter()).Magnitude
	if Distance > _settings.LowRenderDistance then
		QUALITY_LEVEL = 2
	end
	
	VertexInfo[Id] = {
		VertexId = Id,
		ColorId = 0,
		UVId = 0,
		NormalId = 0,
		
		UV = UV * GRID_SETTINGS.UV_SCALE,
		Position = Position,
		Lerping = false,
		CurrentFrame = 0,

		GoalPosition = Vector3.zero,
		LastPosition = Vector3.zero,
		
		CurrentColor = Color3.new(0, 0, 0),
		AlphaTransparency = 1,
		QUALITY_LEVEL = QUALITY_LEVEL,
	}
	VertexPositionToId[Position] = Id
end

function Setup.GetBlankVertexKey(Id: number, x: number, z: number): Types.VertexKey
	local GRID_SETTINGS = Setup.SETTINGS
	local UV = GetUVCoordinates(x, z)
	return {
		VertexId = Id,
		ColorId = 0,
		UVId = 0,
		NormalId = 0,
		UV = UV * GRID_SETTINGS.UV_SCALE,

		Position = Vector3.new(x, 0, z),

		Lerping = false,

		CurrentFrame = 0,
		GoalPosition = Vector3.zero,
		LastPosition = Vector3.zero,

		CurrentColor = Color3.new(0, 0, 0),
		AlphaTransparency = 1,
		QUALITY_LEVEL = 1,
	}
end

function Setup.SetupEditableMesh(): EditableMesh
	local Vertices: { { number } } = {}
	local EditableMesh = AssetService:CreateEditableMesh({ FixedSize = true; })
	
	local VertexInfo = Setup.VertexInfo
	local GRID_SETTINGS = Setup.SETTINGS
	local VertexPositionToId = Setup.VertexPositionToId
	
	local _QUADS, _TRIANGLES = Setup._QUADS, Setup._TRIANGLES
	if _QUADS == nil or _TRIANGLES == nil then
		warn('[Setup]: _QUADS or _TRIANGLES were not set.')
		return EditableMesh
	end
	
	-- // We begin to set up our vertices for the EditableMesh
	-- // Note: This segment is thanks to https://devforum.roblox.com/t/gerstner-wave-module/3011006
	
	for y = 1, GRID_SETTINGS.Length do
		local raw = {}
		for x = 1, GRID_SETTINGS.Width do
			local padding = GRID_SETTINGS.Padding

			local vertexX = (padding * (x - 1)) - (padding * (GRID_SETTINGS.Width - 1)) / 2
			local vertexZ = (padding * (y - 1)) - (padding * (GRID_SETTINGS.Length - 1)) / 2
			local VertexPosition = Vector3.new(vertexX, 0, vertexZ)
			local VertexId = EditableMesh:AddVertex(VertexPosition)

			VertexInfo[VertexId] = Setup.GetBlankVertexKey(VertexId, vertexX, vertexZ)
			local Distance = (VertexPosition - Vector3.zero).Magnitude
			if Distance > _settings.LowRenderDistance then
				VertexInfo[VertexId].QUALITY_LEVEL = 2
			end
			
			
			VertexPositionToId[VertexPosition] = VertexId
			raw[x] = VertexId
		end
		Vertices[y] = raw
	end

	for y = 1, GRID_SETTINGS.Length - 1 do
		for x = 1, GRID_SETTINGS.Width - 1 do
			local vertex1Front = Vertices[y][x]
			local vertex2Front = Vertices[y + 1][x]
			local vertex3Front = Vertices[y][x + 1]
			local vertex4Front = Vertices[y + 1][x + 1]

			local Center = 
				(EditableMesh:GetPosition(vertex1Front) + EditableMesh:GetPosition(vertex2Front) + EditableMesh:GetPosition(vertex3Front) + EditableMesh:GetPosition(vertex4Front)) / 4

			local triangle1 = EditableMesh:AddTriangle(vertex1Front, vertex2Front, vertex3Front)
			local triangle2 = EditableMesh:AddTriangle(vertex2Front, vertex4Front, vertex3Front)
			_QUADS[Center] = {
				vertex1Front,
				vertex2Front,
				vertex3Front,
				vertex4Front
			}

			_TRIANGLES[Center] = {
				triangle1,
				triangle2
			}
		end
	end

	table.clear(Vertices)
	EditableMesh:RemoveUnused()

	return EditableMesh
end

function Setup.GetPlaneFromEditableMesh(EM: EditableMesh, Name: string?): MeshPart
	-- // Create the plane mesh through the EditableMesh API.
	-- // We also set up all the properties for it, as well as
	-- // applying a SurfaceAppearance
	local Size = EM:GetSize()
	
	local Plane = AssetService:CreateMeshPartAsync(Content.fromObject(EM))
	local Existing = script.ExistingMesh
	
	Existing:ApplyMesh(Plane)
	Existing.Size = Plane.Size
	
	Plane:Destroy()
	Plane = Existing
	
	Plane.Name = Name or 'OceanPlane'
	Plane.Anchored = true
	Plane.CanCollide, Plane.CastShadow = false, false
	Plane.Material = Enum.Material.Granite
	pcall(function() Plane.RenderFidelity = Enum.RenderFidelity.Precise end) -- // v06: Roblox ya no deja escribir RenderFidelity desde scripts normales (capability PluginOrOpenCloud)
	
	local Appearance = ReplicatedStorage:FindFirstChild('Appearance')
	if Appearance == nil then
		local GerstnerRoot = ReplicatedStorage:FindFirstChild('Gerstner')
		if GerstnerRoot then
			Appearance = GerstnerRoot:FindFirstChild('Appearance')
		end
	end
	if Appearance and Appearance:IsA('SurfaceAppearance') then
		local ClonedAppearance = Appearance:Clone()
		ClonedAppearance.AlphaMode = Enum.AlphaMode.Overlay -- // v08 (antes Transparency)
		ClonedAppearance.Color = _settings.SURFACE_APPEARANCE_COLOR or Color3.fromRGB(31, 45, 62) -- // v05: con fallback, si Settings no tiene la clave el plano no falla
		pcall(function() ClonedAppearance.ColorMapContent = Content.none end) -- // v12: la propiedad nueva (Content) es la que cuenta
		pcall(function() ClonedAppearance.ColorMap = '' end) -- // v11: sin ColorMap
		if _settings.DEBUG == true then pcall(function() warn('[ColorMap] plano principal:', ClonedAppearance.ColorMapContent.SourceType, '|', ClonedAppearance.ColorMap) end) end -- // v12 diagnostico
		ClonedAppearance.Parent = Plane
	end

	-- // v12: ExistingMesh puede traer su propio SurfaceAppearance / TextureID: tambien se les quita el ColorMap
	for _, Child in Plane:GetChildren() do
		if Child:IsA('SurfaceAppearance') then
			pcall(function() Child.ColorMapContent = Content.none end)
			pcall(function() Child.ColorMap = '' end)
			if _settings.DEBUG == true then pcall(function() warn('[ColorMap] hijo del plano:', Child:GetFullName(), Child.ColorMapContent.SourceType) end) end
		end
	end
	pcall(function() Plane.TextureID = '' end)

	Plane.Color = Color3.fromRGB(255, 255, 255)
	Plane.Size = Vector3.new(Size.X, 0.001, Size.Z)
	Plane.Position = Setup.SETTINGS.PLANE_OFFSET
	Plane.Transparency = 0	
	
	Plane.Parent = workspace.Ocean

	return Plane
end

function Setup.SubdividePlane(MinimumDistance: number, Debug: boolean, EditableMesh: EditableMesh)
	local AddedQuads = {}
	local SubdividedQuadkeys = {}

	local VertexInfo = Setup.VertexInfo
	local GRID_SETTINGS = Setup.SETTINGS
	local VertexPositionToId = Setup.VertexPositionToId

	local _QUADS, _TRIANGLES = Setup._QUADS:: { [Vector3]: {} }, Setup._TRIANGLES
	
	Setup.CurrentSubdivisions += 1
	if _QUADS == nil or _TRIANGLES == nil then
		return
	end
	
	for QuadPosition, Vertices in _QUADS do
		local v1, v2, v3, v4 = Vertices[1], Vertices[2], Vertices[3], Vertices[4]
		local p1, p2, p3, p4 = VertexInfo[v1].Position, VertexInfo[v2].Position, VertexInfo[v3].Position, VertexInfo[v4].Position

		local CenterPosition = (p1 + p2 + p3 + p4) / 4
		if math.abs(CenterPosition.X) > MinimumDistance or math.abs(CenterPosition.Z) > MinimumDistance then
			continue
		end
		
		local OriginalFaces = _TRIANGLES[CenterPosition]

		for i, TriangleId in OriginalFaces do
			EditableMesh:RemoveFace(TriangleId:: number)
		end
		_TRIANGLES[CenterPosition] = nil

		local midpointAB = GetMidpoint(p1, p2)
		local midpointBD = GetMidpoint(p2, p4)
		local midpointCD = GetMidpoint(p3, p4)
		local midpointAC = GetMidpoint(p1, p3)

		local CenterVertex = EditableMesh:AddVertex(CenterPosition)
		local ABVertex = VertexPositionToId[midpointAB] or EditableMesh:AddVertex(midpointAB)
		local ACVertex = VertexPositionToId[midpointAC] or EditableMesh:AddVertex(midpointAC)
		local BDVertex = VertexPositionToId[midpointBD] or EditableMesh:AddVertex(midpointBD)
		local CDVertex = VertexPositionToId[midpointCD] or EditableMesh:AddVertex(midpointCD)
		
		
		InsertToVertexInfo(EditableMesh, CenterVertex)
		InsertToVertexInfo(EditableMesh, ABVertex)
		InsertToVertexInfo(EditableMesh, ACVertex)
		InsertToVertexInfo(EditableMesh, BDVertex)
		InsertToVertexInfo(EditableMesh, CDVertex)

		-- // top left
		local Triangle1 = EditableMesh:AddTriangle(v4, CDVertex, BDVertex)
		local Triangle2 = EditableMesh:AddTriangle(CDVertex, CenterVertex, BDVertex)
		table.insert(AddedQuads, {
			v4,
			CDVertex,
			BDVertex,
			CenterVertex,
			Triangles = {
				Triangle2,
				Triangle1
			}
		})

		-- // bottom left
		local Triangle1 = EditableMesh:AddTriangle(CDVertex, v3, CenterVertex)
		local Triangle2 = EditableMesh:AddTriangle(v3, ACVertex, CenterVertex)
		table.insert(AddedQuads, {
			CDVertex,
			v3,
			CenterVertex,
			ACVertex,
			Triangles = {
				Triangle2,
				Triangle1
			}
		})

		-- // top right
		local Triangle1 = EditableMesh:AddTriangle(BDVertex, CenterVertex, v2)
		local Triangle2 = EditableMesh:AddTriangle(CenterVertex, ABVertex, v2)
		table.insert(AddedQuads, {
			BDVertex,
			CenterVertex,
			v2,
			ABVertex,
			Triangles = {
				Triangle2,
				Triangle1
			}
		})

		-- // bottom right
		local Triangle1 = EditableMesh:AddTriangle(CenterVertex, ACVertex, ABVertex)
		local Triangle2 = EditableMesh:AddTriangle(ACVertex, v1, ABVertex)
		table.insert(AddedQuads, {
			CenterVertex,
			ACVertex,
			ABVertex,
			v1,
			Triangles = {
				Triangle2,
				Triangle1
			}
		})
		
		_QUADS[QuadPosition] = nil
		for i, Vertex in {ABVertex, ACVertex, BDVertex, CDVertex} do
			local FaceCount = #EditableMesh:GetFacesWithAttribute(Vertex)
			local Position = EditableMesh:GetPosition(Vertex)
			
			local Displacement = CenterPosition - Position
			local Neighbor = CenterPosition + (-Displacement * 2)
			local Valid = math.abs(Neighbor.X) > MinimumDistance or math.abs(Neighbor.Z) > MinimumDistance
			
			if FaceCount == 3 and Valid == true and Debug == true then
				MergeBorderVertex(EditableMesh, Vertex, Position, CenterPosition, Setup.CurrentSubdivisions)
			end
		end
	end
	EditableMesh:Triangulate()

	for i, Info in AddedQuads do
		local UpdatedTriangles = table.clone(Info.Triangles)
		Info.Triangles = nil:: any
		
		local Center = Vector3.zero
		for i, Vertex in Info do
			Center += EditableMesh:GetPosition(Vertex)
		end
		Center /= 4
		
		_QUADS[Center] = Info
		_TRIANGLES[Center] = UpdatedTriangles
	end
	
	return AddedQuads
end

function Setup.SetupSecondaryPlanes(EM: EditableMesh): { { MeshPart | Vector3 } }
	local AssetService = game:GetService('AssetService')
	local Size = EM:GetSize()
	
	local EditableMesh = AssetService:CreateEditableMesh({ FixedSize = true; })

	local v1 = EditableMesh:AddVertex(Vector3.new(-Size.X / 2, 0, -Size.Z / 2))
	local v2 = EditableMesh:AddVertex(Vector3.new(Size.X / 2, 0, -Size.Z / 2))
	local v3 = EditableMesh:AddVertex(Vector3.new(-Size.X / 2, 0, Size.Z / 2))
	local v4 = EditableMesh:AddVertex(Vector3.new(Size.X / 2, 0, Size.Z / 2))
	
	local triangle1 = EditableMesh:AddTriangle(v1, v3, v4)
	local triangle2 = EditableMesh:AddTriangle(v4, v2, v1)
	
	for i, UVId in EditableMesh:GetUVs() do
		local VertexId = EditableMesh:GetVerticesWithAttribute(UVId)[1]
		if VertexId then
			local POS = EditableMesh:GetPosition(VertexId)
			local Vx, Vz = POS.X, POS.Z
			
			local Padding = _settings.GRID_SETTINGS.Padding
			local x = ((Vx / Padding)) + 1
			local y = ((Vz / Padding)) + 1

			EditableMesh:SetUV(UVId, Vector2.new(x, y) * _settings.GRID_SETTINGS.PaddingMultiplier)
		end
	end
	for i, ColorId in EditableMesh:GetColors() do
		local VertexId = EditableMesh:GetVerticesWithAttribute(ColorId)[1]
		if VertexId then
			EditableMesh:SetColor(ColorId, _settings.WAVE_COLORS.TROUGH)
		end
	end
	
	local SecondaryPlaneInfo = {}
	for i = 1, 8 do
		local NewSize = EditableMesh:GetSize()

		local Plane = AssetService:CreateMeshPartAsync(Content.fromObject(EditableMesh))
		Plane.Name = 'SecondaryPlane'
		Plane.Anchored = true
		Plane.CanCollide, Plane.CastShadow = false, false
		Plane.Material = Enum.Material.Granite
		pcall(function() Plane.RenderFidelity = Enum.RenderFidelity.Precise end) -- // v06: Roblox ya no deja escribir RenderFidelity desde scripts normales (capability PluginOrOpenCloud)

		local Appearance = ReplicatedStorage:FindFirstChild('Appearance')
		if Appearance == nil then
			local GerstnerRoot = ReplicatedStorage:FindFirstChild('Gerstner')
			if GerstnerRoot then
				Appearance = GerstnerRoot:FindFirstChild('Appearance')
			end
		end
		if Appearance and Appearance:IsA('SurfaceAppearance') then
			local ClonedAppearance = Appearance:Clone()
			ClonedAppearance.AlphaMode = Enum.AlphaMode.Overlay -- // v08 (antes Transparency)
			ClonedAppearance.Color = _settings.SURFACE_APPEARANCE_COLOR or Color3.fromRGB(31, 45, 62) -- // v05: con fallback, si Settings no tiene la clave el plano no falla
			pcall(function() ClonedAppearance.ColorMapContent = Content.none end) -- // v12: la propiedad nueva (Content) es la que cuenta
			pcall(function() ClonedAppearance.ColorMap = '' end) -- // v11: sin ColorMap
			if _settings.DEBUG == true then pcall(function() warn('[ColorMap] plano secundario:', ClonedAppearance.ColorMapContent.SourceType, '|', ClonedAppearance.ColorMap) end) end -- // v12 diagnostico
			ClonedAppearance.Parent = Plane
		end

		Plane.Color = Color3.fromRGB(255, 255, 255)
		Plane.Size = Vector3.new(NewSize.X, 0.001, NewSize.Z)
		Plane.Position = Setup.SETTINGS.PLANE_OFFSET
		Plane.Transparency = 0
		Plane.Parent = workspace.Ocean
		
		local Offset = Vector3.zero
		if i == 1 then
			Offset = Vector3.new(-Plane.Size.X, 0, 0)
		elseif i == 2 then
			Offset = Vector3.new(Plane.Size.X, 0, 0)
		elseif i == 3 then
			Offset = Vector3.new(0, 0, -Plane.Size.Z)
		elseif i == 4 then
			Offset = Vector3.new(0, 0, Plane.Size.Z)
		elseif i == 5 then
			Offset = Vector3.new(Plane.Size.X, 0, Plane.Size.Z)
		elseif i == 6 then
			Offset = Vector3.new(-Plane.Size.X, 0, Plane.Size.Z)
		elseif i == 7 then
			Offset = Vector3.new(-Plane.Size.X, 0, -Plane.Size.Z)
		elseif i == 8 then
			Offset = Vector3.new(Plane.Size.X, 0, -Plane.Size.Z)
		end
		local Info = {
			Plane,
			Offset
		}
		table.insert(SecondaryPlaneInfo, Info)
	end
	return SecondaryPlaneInfo
end

return Setup
