-- LocalScript dentro de StarterPlayer >> StarterPlayerScripts
-- Ola gigante lejana: la malla del oceano solo cubre ~1900 studs alrededor de la camara. Este script dibuja la misma ola
-- (mismo perfil y misma hora del servidor) con unas pocas piezas estaticas que se mueven con ella, para verla venir
-- desde el horizonte en vez de que aparezca de golpe. No hay vertices que actualizar: solo se mueven las piezas.

--!nonstrict

local AssetService = game:GetService('AssetService')
local RunService = game:GetService('RunService')
local RS = game:GetService('ReplicatedStorage')

local GerstnerRoot = RS:WaitForChild('Gerstner')
local Gerstner = require(GerstnerRoot)
local Helper = require(GerstnerRoot:WaitForChild('Helper'))
local _settings = require(GerstnerRoot:WaitForChild('Settings'))

if _settings.GIANT_FAR_WAVE == false then
	return
end

local Ocean = workspace:WaitForChild('Ocean')

local CFG = Gerstner.GIANT_CONFIG
local GRID = _settings.GRID_SETTINGS

local STEP = 20 -- // Studs entre vertices a lo largo de la ola
local TILE_LENGTH = 2000 -- // Largo de cada pieza en la direccion de la ola (maximo de Roblox por malla: 2048)
local TILE_WIDTH = 2000 -- // Ancho de cada pieza (perpendicular a la ola)
local ACROSS = 1 -- // Piezas a cada lado de la camara (3 en total = 6000 studs de ancho)
local SLOTS = 2 -- // Pulsos dibujados a la vez (los dos que quedan a cada lado de la camara)

local Dir = CFG.Direction.Unit
local Perp = Vector3.new(-Dir.Z, 0, Dir.X)
local BaseY = GRID.PLANE_OFFSET.Y - CFG.Drop

-- // Altura de la ola a distancia s de su centro (igual que Gerstner.ComputeGiantWave)
local function Profile(s: number): number
	local c = 1 / math.cosh(s / CFG.Width)
	return CFG.Height * c * c
end

-- // Malla de la pieza m (m = -1, 0, 1 son los tramos de la ola, de TILE_LENGTH studs cada uno).
-- // La malla se centra en Y para que el centro de la pieza coincida con el centro de su caja, y asi su posicion sea exacta.
local function BuildMesh(m: number): (EditableMesh?, number)
	local Half = TILE_LENGTH / 2
	local Columns = math.round(TILE_LENGTH / STEP)

	local Heights = {}
	local MinG, MaxG = math.huge, -math.huge
	for i = 0, Columns do
		local g = Profile(m * TILE_LENGTH - Half + i * STEP)
		Heights[i] = g
		MinG = math.min(MinG, g)
		MaxG = math.max(MaxG, g)
	end

	-- // Si este tramo nunca llega a asomar sobre el mar (queda mas de Drop/2 por debajo), no hace falta dibujarlo
	if MaxG < CFG.Drop * 0.5 then
		return nil, 0
	end

	local Mid = (MinG + MaxG) / 2
	local EM = AssetService:CreateEditableMesh({ FixedSize = true })

	local Ids = {}
	for i = 0, Columns do
		local x = -Half + i * STEP
		local y = Heights[i] - Mid
		Ids[i] = {
			EM:AddVertex(Vector3.new(x, y, -TILE_WIDTH / 2)),
			EM:AddVertex(Vector3.new(x, y, TILE_WIDTH / 2)),
		}
	end
	for i = 0, Columns - 1 do
		-- // Mismo orden de vertices que los planos secundarios de Setup (cara hacia arriba)
		local a, c = Ids[i][1], Ids[i][2]
		local b, d = Ids[i + 1][1], Ids[i + 1][2]
		EM:AddTriangle(a, c, d)
		EM:AddTriangle(d, b, a)
	end

	for _, UVId in EM:GetUVs() do
		local VertexId = EM:GetVerticesWithAttribute(UVId)[1]
		if VertexId then
			local Pos = EM:GetPosition(VertexId)
			EM:SetUV(UVId, Vector2.new(Pos.X / GRID.Padding + 1, Pos.Z / GRID.Padding + 1) * GRID.UV_SCALE * GRID.PaddingMultiplier)
		end
	end
	for _, ColorId in EM:GetColors() do
		local VertexId = EM:GetVerticesWithAttribute(ColorId)[1]
		if VertexId then
			local Pos = EM:GetPosition(VertexId)
			EM:SetColor(ColorId, Helper.GetVertexColor(Pos.Y + Mid, 0, 1))
		end
	end

	return EM, Mid
end

local function GetAppearance(): Instance?
	local Appearance = RS:FindFirstChild('Appearance') or GerstnerRoot:FindFirstChild('Appearance')
	if Appearance and Appearance:IsA('SurfaceAppearance') then
		return Appearance
	end
	return nil
end

local function CreateTile(EM: EditableMesh): MeshPart
	local Part = AssetService:CreateMeshPartAsync(Content.fromObject(EM))
	Part.Name = 'GiantWaveFar'
	Part.Anchored = true
	Part.CanCollide, Part.CanTouch, Part.CanQuery, Part.CastShadow = false, false, false, false
	Part.Material = Enum.Material.Granite
	Part.RenderFidelity = Enum.RenderFidelity.Precise
	Part.Color = Color3.fromRGB(255, 255, 255)

	local Appearance = GetAppearance()
	if Appearance then
		Appearance:Clone().Parent = Part
	end

	local Size = EM:GetSize()
	Part.Size = Vector3.new(Size.X, math.max(Size.Y, 0.001), Size.Z)
	Part.Position = Vector3.new(0, -10000, 0)
	Part.Parent = Ocean
	return Part
end

-- // Slots[slot] = lista de { Part, m (tramo), k (pieza a lo ancho), Mid }
local Slots = {}
local Ready = false

task.spawn(function()
	local Meshes = {}
	for m = -1, 1 do
		local EM, Mid = BuildMesh(m)
		if EM then
			Meshes[m] = { EM = EM, Mid = Mid }
		end
	end

	for slot = 1, SLOTS do
		Slots[slot] = {}
		for m, Info in Meshes do
			for k = -ACROSS, ACROSS do
				table.insert(Slots[slot], { Part = CreateTile(Info.EM), m = m, k = k, Mid = Info.Mid })
			end
		end
	end
	Ready = true
end)

RunService.Heartbeat:Connect(function()
	local Camera = workspace.CurrentCamera
	if Ready == false or Camera == nil then
		return
	end

	local t = workspace:GetServerTimeNow()
	local CamPos = Camera.CFrame.Position
	local u = Dir.X * CamPos.X + Dir.Z * CamPos.Z -- // Posicion de la camara a lo largo de la ola
	local v = Perp.X * CamPos.X + Perp.Z * CamPos.Z -- // ... y a lo ancho

	-- // Los dos pulsos que quedan a cada lado de la camara (el tren es continuo, asi que siempre hay dos)
	local Center0 = Gerstner.GetGiantWaveCenter(t)
	local k0 = math.floor((u - Center0) / CFG.Spacing)
	local vBase = math.floor(v / TILE_WIDTH + 0.5) * TILE_WIDTH

	for slot = 1, SLOTS do
		local PulseU = Center0 + (k0 + slot - 1) * CFG.Spacing
		for _, Tile in Slots[slot] do
			local TU = PulseU + Tile.m * TILE_LENGTH
			local TV = vBase + Tile.k * TILE_WIDTH
			local Pos = Dir * TU + Perp * TV + Vector3.new(0, BaseY + Tile.Mid, 0)
			Tile.Part.CFrame = CFrame.fromMatrix(Pos, Dir, Vector3.yAxis)
		end
	end
end)
