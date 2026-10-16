-- Script (servidor) hijo del modelo ServerBoat
-- Entrada a la nave: el prompt de la parte "Door" sienta al jugador en el primer asiento libre
-- (VehicleSeat = conductor, luego Seat1, Seat2, Seat3). Un asiento reservado no se asigna a dos jugadores a la vez.
-- Con Espacio (pedido por SeatExit) el jugador sale y se teletransporta a la parte "Exit" (si no existe, sobre "Door").
-- Nadie salta fuera de los asientos: mientras esta sentado su salto vale 0.

--!nonstrict

local Players = game:GetService('Players')

local Boat = script.Parent
local Door = Boat:WaitForChild('Door', 10)
local DriverSeat = Boat:WaitForChild('VehicleSeat')

local SEAT_NAMES = { 'Seat1', 'Seat2', 'Seat3' }
local EXIT_HEIGHT = 3.5 -- // studs sobre la parte de salida a los que aparece el jugador
local SIT_TIMEOUT = 1.5 -- // segundos maximos esperando a que el asiento reserve al jugador

if Door == nil then
	warn('[BoatSeats] No hay ninguna parte llamada "Door" dentro de ' .. Boat.Name)
	return
end

-- // Asientos en orden de asignacion
local Seats = { DriverSeat }
for _, Name in SEAT_NAMES do
	local Seat = Boat:FindFirstChild(Name)
	if Seat and Seat:IsA('Seat') then
		table.insert(Seats, Seat)
	else
		warn('[BoatSeats] Falta el asiento ' .. Name)
	end
end

local Reserved = {} -- // [Seat] = Player mientras se esta sentando (evita que dos jugadores reciban el mismo asiento)
local Seated = {} -- // [Seat] = Humanoid que ocupa el asiento
local SavedJump = {} -- // [Humanoid] = { JumpPower, JumpHeight }

local SeatEvent = Instance.new('RemoteEvent')
SeatEvent.Name = 'SeatEvent'
SeatEvent.Parent = Boat

local Prompt = Door:FindFirstChildOfClass('ProximityPrompt')
if Prompt == nil then
	Prompt = Instance.new('ProximityPrompt')
	Prompt.ObjectText = 'Nave'
	Prompt.ActionText = 'Abordar'
	Prompt.HoldDuration = 0
	Prompt.MaxActivationDistance = 10
	Prompt.RequiresLineOfSight = false
	Prompt.Parent = Door
end

local function IsFree(Seat: Seat): boolean
	return Seat.Occupant == nil and Reserved[Seat] == nil
end

local function RefreshPrompt()
	local AnyFree = false
	for _, Seat in Seats do
		if IsFree(Seat) then
			AnyFree = true
			break
		end
	end
	Prompt.Enabled = AnyFree
end

local function GetSeatOf(Humanoid: Humanoid): Seat?
	for _, Seat in Seats do
		if Seat.Occupant == Humanoid then
			return Seat
		end
	end
	return nil
end

local function ExitCFrame(): CFrame
	local Part = Boat:FindFirstChild('Exit')
	if Part == nil or not Part:IsA('BasePart') then
		Part = Door
	end
	return Part.CFrame * CFrame.new(0, Part.Size.Y / 2 + EXIT_HEIGHT, 0)
end

local function LockJump(Humanoid: Humanoid)
	if SavedJump[Humanoid] == nil then
		SavedJump[Humanoid] = { Humanoid.JumpPower, Humanoid.JumpHeight }
	end
	Humanoid.JumpPower = 0
	Humanoid.JumpHeight = 0
end

local function RestoreJump(Humanoid: Humanoid)
	local Saved = SavedJump[Humanoid]
	if Saved then
		Humanoid.JumpPower, Humanoid.JumpHeight = Saved[1], Saved[2]
		SavedJump[Humanoid] = nil
	end
end

-- // Los asientos vacios estan desactivados: solo se ocupan por el prompt (nadie se sienta por contacto)
for _, Seat in Seats do
	Seat:SetAttribute('BoatSeat', true)
	if Seat.Occupant == nil then
		Seat.Disabled = true
	end

	Seat:GetPropertyChangedSignal('Occupant'):Connect(function()
		local Occupant = Seat.Occupant
		local Previous = Seated[Seat]
		Seated[Seat] = Occupant

		if Occupant ~= nil then
			LockJump(Occupant)
		elseif Previous ~= nil then
			-- // El jugador salio del asiento: se libera y se teletransporta a la salida
			Seat.Disabled = true
			local Character = Previous.Parent
			if Previous.Health > 0 and Character and Character.Parent then
				task.defer(function()
					local Root = Previous.RootPart
					if Root == nil or Previous.Health <= 0 then
						RestoreJump(Previous)
						return
					end
					Character:PivotTo(ExitCFrame())
					Root.AssemblyLinearVelocity = Vector3.zero
					Root.AssemblyAngularVelocity = Vector3.zero
					RestoreJump(Previous)
				end)
			else
				RestoreJump(Previous)
			end
		end
		RefreshPrompt()
	end)
end

Prompt.Triggered:Connect(function(Player: Player)
	local Character = Player.Character
	local Humanoid = Character and Character:FindFirstChildOfClass('Humanoid')
	if Humanoid == nil or Humanoid.Health <= 0 or Humanoid.SeatPart ~= nil or Humanoid.RootPart == nil then
		return
	end

	-- // Primer asiento libre (conductor primero). Se reserva antes de sentar: es lo que impide el doble teletransporte.
	local Chosen: Seat? = nil
	for _, Seat in Seats do
		if IsFree(Seat) then
			Chosen = Seat
			break
		end
	end
	if Chosen == nil then
		RefreshPrompt()
		return
	end

	Reserved[Chosen] = Player
	RefreshPrompt()
	Chosen.Disabled = false
	Chosen:Sit(Humanoid)

	local Waited = 0
	while Chosen.Occupant ~= Humanoid and Waited < SIT_TIMEOUT and Humanoid.Health > 0 do
		Waited += task.wait(0.05)
	end

	Reserved[Chosen] = nil
	if Chosen.Occupant == nil then
		Chosen.Disabled = true
	end
	RefreshPrompt()
end)

-- // Pedido de salida (Espacio). El conductor solo puede salir con la nave en el agua.
SeatEvent.OnServerEvent:Connect(function(Player: Player, Action: string)
	if Action ~= 'Exit' then
		return
	end
	local Character = Player.Character
	local Humanoid = Character and Character:FindFirstChildOfClass('Humanoid')
	if Humanoid == nil then
		return
	end
	local Seat = GetSeatOf(Humanoid)
	if Seat == nil then
		return
	end
	if Seat == DriverSeat and (Boat:GetAttribute('FlightMode') or 'Water') ~= 'Water' then
		return
	end

	-- // Quitar la soldadura del asiento saca al jugador; el teletransporte lo hace el cambio de Occupant
	local Weld = Seat:FindFirstChild('SeatWeld')
	Humanoid.Sit = false
	if Weld then
		Weld:Destroy()
	end
end)

Players.PlayerRemoving:Connect(function(Player)
	for Seat, Reserver in Reserved do
		if Reserver == Player then
			Reserved[Seat] = nil
		end
	end
	RefreshPrompt()
end)

RefreshPrompt()
