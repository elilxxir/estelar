-- LocalScript dentro de StarterPlayer >> StarterPlayerScripts
-- Mueve la nave desde el cliente del piloto mientras esta sentado (sin fisica: ver Serial/BoatDrive).

--!nonstrict

local Players = game:GetService('Players')
local RunService = game:GetService('RunService')
local RS = game:GetService('ReplicatedStorage')

local BoatDrive = require(RS:WaitForChild('Gerstner'):WaitForChild('Serial'):WaitForChild('BoatDrive'))

local Player = Players.LocalPlayer

local Drive = nil
local Seat = nil
local StepConnection = nil

local function StopDriving()
	if StepConnection then
		StepConnection:Disconnect()
		StepConnection = nil
	end
	Drive, Seat = nil, nil
end

local function StartDriving(NewSeat: VehicleSeat)
	StopDriving()
	Seat = NewSeat
	Drive = BoatDrive.new(NewSeat.Parent, NewSeat)
	StepConnection = RunService.PreSimulation:Connect(function(dt)
		BoatDrive.Step(Drive, dt, Seat.Throttle, Seat.Steer)
		BoatDrive.Apply(Drive)
	end)
end

local function OnCharacter(Character: Model)
	local Humanoid = Character:WaitForChild('Humanoid')
	Humanoid.Seated:Connect(function(Active: boolean, SeatPart: Instance?)
		if Active and SeatPart and SeatPart:IsA('VehicleSeat') and SeatPart.Parent:FindFirstChild('Main') then
			StartDriving(SeatPart)
		else
			StopDriving()
		end
	end)
end

Player.CharacterAdded:Connect(OnCharacter)
if Player.Character then
	task.spawn(OnCharacter, Player.Character)
end
