-- ModuleScript in ReplicatedStorage > Gerstner > Serial (junto a BoatManager)
-- Registra la estela de los botes (puntos en el mar) para que ParallelWorker la pinte en los vertices.
-- Update() devuelve un array plano con stride 7: x, z, t, r0, spread, life, strength

local CS = game:GetService("CollectionService")

local STRIDE = 7
local MIN_SPEED = 6
local SPEED_FULL = 60
local INTERVAL = 0.1
local MIN_DIST = 4
local MAX_POINTS = 150

-- radio inicial, crecimiento, vida (s)
local STERN = { r0 = 10, spread = 18, life = 5 }
local BOW = { r0 = 7, spread = 8, life = 2.5 }

local WakeTracker = {}

local boats = {}
local points = {} -- { x, z, t, r0, spread, life, strength }

local function register(boat)
	if boats[boat] then
		return
	end
	local main = boat:WaitForChild("Main", 10)
	local seat = boat:WaitForChild("VehicleSeat", 10)
	if not main or not seat then
		return
	end
	local list = {}
	for _, name in { "TopLeft", "TopRight", "BottomLeft", "BottomRight" } do
		local a = main:WaitForChild(name, 10)
		if not a then
			return
		end
		table.insert(list, a)
	end
	local look = seat.CFrame.LookVector
	table.sort(list, function(a, b)
		return (a.WorldPosition - main.Position):Dot(look) > (b.WorldPosition - main.Position):Dot(look)
	end)
	boats[boat] = {
		main = main,
		bow = { list[1], list[2] },
		stern = { list[3], list[4] },
		lastT = 0,
		lastPos = Vector3.zero,
	}
	boat.Destroying:Once(function()
		boats[boat] = nil
	end)
end

local started = false
local function start()
	if started then
		return
	end
	started = true
	for _, b in CS:GetTagged("Boat") do
		if b:IsA("Model") then
			task.spawn(register, b)
		end
	end
	CS:GetInstanceAddedSignal("Boat"):Connect(function(b)
		if b:IsA("Model") then
			task.spawn(register, b)
		end
	end)
	local sb = workspace:FindFirstChild("ServerBoat")
	if sb and sb:IsA("Model") then
		task.spawn(register, sb)
	end
end

local function push(pos, t, cfg, strength)
	table.insert(points, { pos.X, pos.Z, t, cfg.r0, cfg.spread, cfg.life, strength })
end

function WakeTracker.Update()
	start()
	local now = workspace:GetServerTimeNow()

	for _, b in boats do
		local main = b.main
		local vel = main.AssemblyLinearVelocity
		local speed = Vector3.new(vel.X, 0, vel.Z).Magnitude
		local center = main.Position
		if speed > MIN_SPEED and now - b.lastT >= INTERVAL and (center - b.lastPos).Magnitude >= MIN_DIST then
			b.lastT = now
			b.lastPos = center
			local strength = math.clamp(speed / SPEED_FULL, 0.4, 1)
			push((b.stern[1].WorldPosition + b.stern[2].WorldPosition) / 2, now, STERN, strength)
			push(b.bow[1].WorldPosition, now, BOW, strength * 0.7)
			push(b.bow[2].WorldPosition, now, BOW, strength * 0.7)
		end
	end

	-- limpiar expirados
	local alive = {}
	for _, p in points do
		if now - p[3] < p[6] then
			table.insert(alive, p)
		end
	end
	points = alive
	while #points > MAX_POINTS do
		table.remove(points, 1)
	end

	local flat = table.create(#points * STRIDE)
	local n = 0
	for _, p in points do
		for k = 1, STRIDE do
			n += 1
			flat[n] = p[k]
		end
	end
	return flat
end

return WakeTracker
