-- LocalScript dentro de StarterPlayer >> StarterPlayerScripts
-- Mientras el jugador esta en un asiento de la nave (atributo BoatSeat), Espacio no salta: pide al servidor salir
-- (ServerBoat/BoatSeats lo teletransporta a la salida). Sustituye al bloqueo de Espacio que tenia BoatDriver.

--!nonstrict

local Players = game:GetService('Players')
local ContextActionService = game:GetService('ContextActionService')
local RS = game:GetService('ReplicatedStorage')

local Keys = require(RS:WaitForChild('Gerstner'):WaitForChild('Settings')).FLIGHT.KEYS

local ACTION_NAME = 'BoatSeatExit'
local Player = Players.LocalPlayer
local Bound = false
local CurrentSeat: Seat? = nil

local function OnAction(_, State: Enum.UserInputState)
	if State == Enum.UserInputState.Begin and CurrentSeat then
		local Event = CurrentSeat.Parent:FindFirstChild('SeatEvent')
		if Event then
			Event:FireServer('Exit')
		end
	end
	return Enum.ContextActionResult.Sink
end

local function SetSeat(SeatPart: Instance?)
	if SeatPart and SeatPart:GetAttribute('BoatSeat') then
		CurrentSeat = SeatPart
		if not Bound then
			Bound = true
			ContextActionService:BindActionAtPriority(ACTION_NAME, OnAction, false, Enum.ContextActionPriority.High.Value, Keys.NoJump)
		end
	else
		CurrentSeat = nil
		if Bound then
			Bound = false
			ContextActionService:UnbindAction(ACTION_NAME)
		end
	end
end

local function OnCharacter(Character: Model)
	local Humanoid = Character:WaitForChild('Humanoid')
	Humanoid:GetPropertyChangedSignal('SeatPart'):Connect(function()
		SetSeat(Humanoid.SeatPart)
	end)
	SetSeat(Humanoid.SeatPart)
end

Player.CharacterAdded:Connect(OnCharacter)
if Player.Character then
	task.spawn(OnCharacter, Player.Character)
end
