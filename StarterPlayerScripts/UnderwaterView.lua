-- LocalScript dentro de StarterPlayer >> StarterPlayerScripts
-- El agua es opaca tambien desde abajo: la malla del mar tiene una sola cara, asi que con la camara bajo la superficie
-- se veia a traves (cielo, horizonte, fondo). Cuando la camara queda bajo la ola, una capa de color tapa la vista.

--!nonstrict

local Players = game:GetService('Players')
local RunService = game:GetService('RunService')
local RS = game:GetService('ReplicatedStorage')

local GerstnerRoot = RS:WaitForChild('Gerstner')
local Settings = require(GerstnerRoot:WaitForChild('Settings'))
local HeightLookup = require(GerstnerRoot:WaitForChild('HeightLookup'))
local CFG = Settings.UNDERWATER

if not CFG.ENABLED then
	return
end

local Gui = Instance.new('ScreenGui')
Gui.Name = 'UnderwaterView'
Gui.IgnoreGuiInset = true
Gui.ResetOnSpawn = false
Gui.DisplayOrder = -1 -- // por debajo de cualquier otra interfaz
Gui.Parent = Players.LocalPlayer:WaitForChild('PlayerGui')

local Cover = Instance.new('Frame')
Cover.Name = 'Cover'
Cover.Size = UDim2.fromScale(1, 1)
Cover.BackgroundColor3 = CFG.COLOR
Cover.BorderSizePixel = 0
Cover.BackgroundTransparency = 1
Cover.Active = false
Cover.Parent = Gui

-- // HeightLookup solo responde cuando OceanParallel ya preparo el plano del mar
workspace:WaitForChild('Ocean'):WaitForChild('OceanPlane')
task.wait(3)

local Alpha = 0 -- // 0 = sobre el agua, 1 = sumergida

RunService.RenderStepped:Connect(function(dt)
	local Camera = workspace.CurrentCamera
	if Camera == nil then
		return
	end
	local Position = Camera.CFrame.Position
	local Surface = HeightLookup.Lookup(Position, 'PRECISE', false)

	local Target = 0
	if Surface ~= -1 and Position.Y < Surface - CFG.MARGIN then
		Target = 1
	end
	Alpha += (Target - Alpha) * math.min(dt / CFG.FADE_TIME, 1)
	Cover.BackgroundTransparency = 1 - Alpha
end)
