-- LocalScript dentro de StarterPlayer >> StarterPlayerScripts
-- Piso invisible que sigue al jugador local: siempre camina a la misma altura (Settings.PLAYER.FLOOR_DEPTH bajo el mar en
-- calma) y no cae del mapa por mas que se aleje. El piso solo existe en este cliente (cada cliente simula su personaje) y
-- solo choca con personajes (grupos de colision creados por Workspace/GiantWaveGuard).
-- Si la ola gigante mata al jugador, el piso desaparece y el agua arrastra el cuerpo en la direccion de la ola.

--!nonstrict

local Players = game:GetService('Players')
local RunService = game:GetService('RunService')
local RS = game:GetService('ReplicatedStorage')

local Gerstner = require(RS:WaitForChild('Gerstner'))
local Settings = require(RS:WaitForChild('Gerstner'):WaitForChild('Settings'))
local PLAYER = Settings.PLAYER
local GIANT = Gerstner.GIANT_CONFIG

local SEA_LEVEL = Settings.GRID_SETTINGS.PLANE_OFFSET.Y
local FLOOR_TOP = SEA_LEVEL - PLAYER.FLOOR_DEPTH
local THICKNESS = 8
local SWEEP_TIME = 6 -- // segundos que el agua arrastra el cuerpo (mas que Players.RespawnTime)

local LocalPlayer = Players.LocalPlayer

local Floor = Instance.new('Part')
Floor.Name = 'PlayerSeaFloor'
Floor.Anchored = true
Floor.CanCollide = true
Floor.CanQuery = false
Floor.CanTouch = false
Floor.CastShadow = false
Floor.Transparency = 1
Floor.Size = Vector3.new(PLAYER.FLOOR_SIZE, THICKNESS, PLAYER.FLOOR_SIZE)
Floor.Position = Vector3.new(0, FLOOR_TOP - THICKNESS / 2, 0)
pcall(function()
	Floor.CollisionGroup = 'SeaFloor'
end)
Floor.Parent = workspace

local Swept = false

local function Snap(x: number): number
	return math.round(x / PLAYER.FLOOR_SNAP) * PLAYER.FLOOR_SNAP
end

-- // El agua se lleva el cuerpo
local function Sweep(Root: BasePart)
	Swept = true
	Floor.CanCollide = false
	local Direction = GIANT.Direction.Unit * GIANT.Speed * PLAYER.SWEEP_SPEED
	local Start = os.clock()
	local Connection
	Connection = RunService.Heartbeat:Connect(function()
		if Root.Parent == nil or os.clock() - Start > SWEEP_TIME then
			Connection:Disconnect()
			return
		end
		Root.AssemblyLinearVelocity = Direction + Vector3.new(0, -4, 0)
	end)
end

local function OnCharacter(Character: Model)
	Swept = false
	Floor.CanCollide = true

	local Humanoid = Character:WaitForChild('Humanoid')
	local Root = Character:WaitForChild('HumanoidRootPart')

	Humanoid.Died:Connect(function()
		local Position = Root.Position
		local WaveY = Gerstner.ComputeGiantWave(Vector3.new(Position.X, 0, Position.Z), workspace:GetServerTimeNow()).Y
		if SEA_LEVEL + WaveY > Position.Y then
			Sweep(Root)
		end
	end)
end

LocalPlayer.CharacterAdded:Connect(OnCharacter)
if LocalPlayer.Character then
	task.spawn(OnCharacter, LocalPlayer.Character)
end

RunService.Heartbeat:Connect(function()
	local Character = LocalPlayer.Character
	local Root = Character and Character:FindFirstChild('HumanoidRootPart')
	if Root == nil then
		return
	end
	local Position = Root.Position
	local X, Z = Snap(Position.X), Snap(Position.Z)
	local Current = Floor.Position
	if Current.X ~= X or Current.Z ~= Z then
		Floor.Position = Vector3.new(X, FLOOR_TOP - THICKNESS / 2, Z)
	end
end)
