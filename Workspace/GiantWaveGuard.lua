-- Script (servidor) dentro de Workspace (tambien sirve en ServerScriptService)
-- Jugadores a pie:
--   * Registra los grupos de colision del piso invisible (lo crea cada cliente en StarterPlayerScripts/PlayerFloor): el piso
--     solo choca con los personajes, no con la nave ni con el resto del mapa.
--   * La ola gigante mata al jugador cuando su superficie le pasa por encima del torso (el agua se lo lleva: ver PlayerFloor).
--     Los jugadores sentados en la nave no se tocan.
--   * Si alguien queda por debajo del piso (por ejemplo al aparecer antes de que cargue su piso) lo devuelve al piso.

--!nonstrict

local Players = game:GetService('Players')
local PhysicsService = game:GetService('PhysicsService')
local RS = game:GetService('ReplicatedStorage')

local Gerstner = require(RS:WaitForChild('Gerstner'))
local Settings = require(RS:WaitForChild('Gerstner'):WaitForChild('Settings'))
local PLAYER = Settings.PLAYER

local SEA_LEVEL = Settings.GRID_SETTINGS.PLANE_OFFSET.Y
local FLOOR_TOP = SEA_LEVEL - PLAYER.FLOOR_DEPTH

-- // Grupos de colision
local function Register(Name: string)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(Name)
	end)
end
Register('SeaFloor')
Register('Characters')
PhysicsService:CollisionGroupSetCollidable('SeaFloor', 'Default', false)
PhysicsService:CollisionGroupSetCollidable('SeaFloor', 'Characters', true)
PhysicsService:CollisionGroupSetCollidable('Characters', 'Default', true)

local function SetGroup(Part: Instance)
	if Part:IsA('BasePart') then
		Part.CollisionGroup = 'Characters'
	end
end

local function OnCharacter(Character: Model)
	for _, Descendant in Character:GetDescendants() do
		SetGroup(Descendant)
	end
	Character.DescendantAdded:Connect(SetGroup)
end

local function OnPlayer(Player: Player)
	Player.CharacterAdded:Connect(OnCharacter)
	if Player.Character then
		OnCharacter(Player.Character)
	end
end

Players.PlayerAdded:Connect(OnPlayer)
for _, Player in Players:GetPlayers() do
	OnPlayer(Player)
end

-- // Revision periodica
while true do
	task.wait(PLAYER.CHECK_INTERVAL)
	local t = workspace:GetServerTimeNow()

	for _, Player in Players:GetPlayers() do
		local Character = Player.Character
		local Humanoid = Character and Character:FindFirstChildOfClass('Humanoid')
		local Root = Humanoid and Humanoid.RootPart
		if Humanoid == nil or Root == nil or Humanoid.Health <= 0 or Humanoid.SeatPart ~= nil then
			continue
		end

		local Position = Root.Position
		local WaveY = Gerstner.ComputeGiantWave(Vector3.new(Position.X, 0, Position.Z), t).Y
		if SEA_LEVEL + WaveY > Position.Y + PLAYER.KILL_ABOVE_ROOT then
			Humanoid.Health = 0
		elseif Position.Y < FLOOR_TOP - PLAYER.FALL_RESCUE then
			Character:PivotTo(CFrame.new(Position.X, FLOOR_TOP + 4, Position.Z))
			Root.AssemblyLinearVelocity = Vector3.zero
		end
	end
end
