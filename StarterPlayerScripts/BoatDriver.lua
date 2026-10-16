-- LocalScript dentro de StarterPlayer >> StarterPlayerScripts
-- Mueve la nave desde el cliente del piloto mientras esta sentado (sin fisica: ver Serial/BoatDrive).
--
-- Vuelo (ver Settings.FLIGHT.KEYS): F despega / aterriza. En vuelo W = propulsores principales, S = freno (sin marcha atras),
-- A / D = alabeo (inclina y vira), Q / E = subir / bajar (propulsores verticales). Espacio no hace nada: solo se absorbe
-- para que nunca saque al piloto del asiento.
-- El servidor concede los modos (atributo FlightMode del modelo) y valida el vuelo: este script solo los copia.

--!nonstrict

local Players = game:GetService('Players')
local RunService = game:GetService('RunService')
local ContextActionService = game:GetService('ContextActionService')
local RS = game:GetService('ReplicatedStorage')

local Gerstner = RS:WaitForChild('Gerstner')
local BoatDrive = require(Gerstner:WaitForChild('Serial'):WaitForChild('BoatDrive'))
local FLIGHT = require(Gerstner:WaitForChild('Settings')).FLIGHT
local Keys = FLIGHT.KEYS

local ACTION_NAME = 'BoatFlightInput'

local Player = Players.LocalPlayer

local Drive = nil
local Seat = nil
local Boat = nil
local FlightEvent = nil
local StepConnection = nil
local EventConnection = nil
local Paused = false -- // true: el servidor tiene la nave (aterrizaje forzado) y este cliente no la mueve
local Held = {} -- // [Enum.KeyCode] = true mientras esta pulsada

local function GetMode(): string
	return if Boat then Boat:GetAttribute('FlightMode') or 'Water' else 'Water'
end

-- // F: segun el modo pide despegar, aterrizar o cancelar el aterrizaje. El servidor decide si lo concede.
local function RequestToggle()
	if not FLIGHT.ENABLED or FlightEvent == nil or Paused then
		return
	end
	local Mode = GetMode()
	if Mode == 'Water' or Mode == 'Landing' then
		FlightEvent:FireServer('Takeoff')
	else
		FlightEvent:FireServer('Land')
	end
end

local function OnAction(_, State: Enum.UserInputState, Input: InputObject)
	local Key = Input.KeyCode
	if State == Enum.UserInputState.Begin then
		Held[Key] = true
		if Key == Keys.Toggle then
			RequestToggle()
		end
	elseif State == Enum.UserInputState.End or State == Enum.UserInputState.Cancel then
		Held[Key] = nil
	end
	-- // v14: Espacio nunca debe hacer saltar al piloto fuera del asiento (ni en agua ni en vuelo)
	if Key == Keys.NoJump then
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

local function BindInput()
	ContextActionService:BindActionAtPriority(
		ACTION_NAME,
		OnAction,
		false,
		Enum.ContextActionPriority.High.Value,
		Keys.Up,
		Keys.Down,
		Keys.RollLeft,
		Keys.RollRight,
		Keys.Toggle
	)
end

local function UnbindInput()
	ContextActionService:UnbindAction(ACTION_NAME)
	table.clear(Held)
end

local function Step(dt: number)
	-- // El modo lo manda el servidor. Si la ola acaba de arrastrar la nave (Swept), este cliente ya paso a Water y espera
	-- // a que el servidor lo confirme, para no volver a vuelo con el atributo anterior.
	local Mode = GetMode()
	if Drive.Swept then
		if Mode == 'Water' then
			Drive.Swept = false
		end
	else
		BoatDrive.SetMode(Drive, Mode)
	end

	local Input = {
		Roll = (if Held[Keys.RollRight] then 1 else 0) - (if Held[Keys.RollLeft] then 1 else 0),
		Collective = (if Held[Keys.Up] then 1 else 0) - (if Held[Keys.Down] then 1 else 0),
	}
	-- // En agua A / D son el volante (Seat.Steer); en vuelo BoatDrive ignora Steer y usa el alabeo (Input.Roll)
	BoatDrive.Step(Drive, dt, Seat.Throttle, Seat.Steer, false, Input)
	BoatDrive.Apply(Drive)
end

local function Connect()
	if StepConnection == nil then
		StepConnection = RunService.PreSimulation:Connect(Step)
	end
end

local function Disconnect()
	if StepConnection then
		StepConnection:Disconnect()
		StepConnection = nil
	end
end

local StartDriving

local function OnFlightEvent(Action: string, Reason: string?)
	if Action == 'ServerControl' then
		-- // El servidor detecto una infraccion y aterriza la nave por su cuenta
		Paused = true
		Disconnect()
		table.clear(Held)
		warn(`[Vuelo] Aterrizaje forzado por el servidor: {Reason}`)
	elseif Action == 'Resume' then
		local Current = Seat
		if Current then
			StartDriving(Current) -- // Reconstruye el estado desde donde quedo la nave
		end
	end
end

local function StopDriving()
	Disconnect()
	if EventConnection then
		EventConnection:Disconnect()
		EventConnection = nil
	end
	UnbindInput()
	Drive, Seat, Boat, FlightEvent = nil, nil, nil, nil
	Paused = false
end

function StartDriving(NewSeat: VehicleSeat)
	StopDriving()
	Seat = NewSeat
	Boat = NewSeat.Parent
	Drive = BoatDrive.new(Boat, NewSeat)
	BindInput()
	Connect()

	-- // El servidor crea el RemoteEvent; si tarda, el vuelo simplemente no responde hasta que aparezca
	task.spawn(function()
		local Event = Boat:WaitForChild('FlightEvent', 10)
		if Event and Seat == NewSeat then
			FlightEvent = Event
			EventConnection = Event.OnClientEvent:Connect(OnFlightEvent)
		end
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
