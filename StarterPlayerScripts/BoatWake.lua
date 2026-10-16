-- LocalScript in StarterPlayer > StarterPlayerScripts
-- Boat effects (client only, nothing replicated):
--   * Stern spray (L/R), bow spray (L/R), propeller churn, surface foam trail
--   * Ribbon wakes on the Gerstner surface: stern L/R, bow L/R, center
--   * Impact splash (burst + droplets + ripple + sound) when the hull slams into the water
-- Boats: models tagged "Boat" or workspace.ServerBoat.
-- Needs in the boat: Main (TopLeft, TopRight, BottomLeft, BottomRight attachments), VehicleSeat.
-- Bow/stern is detected automatically from VehicleSeat.LookVector.

local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CS = game:GetService("CollectionService")
local Debris = game:GetService("Debris")

local HeightLookup = require(RS:WaitForChild("Gerstner"):WaitForChild("HeightLookup"))
local FLIGHT = require(RS:WaitForChild("Gerstner"):WaitForChild("Settings")).FLIGHT

-- // Config
local MIN_SPEED = 6
local SPEED_FULL = 120            -- speed at which particle rates reach their maximum
local SURFACE_OFFSET = 0.15
local RIBBON_INTERVAL = 0.15
local RIBBON_MIN_DIST = 3
local STARTUP_DELAY = 6
local IDLE_RATIO = 0.25           -- v19: fraccion de la espuma / agitacion que queda con la nave quieta
local DOWNWASH_MAX = 45           -- v19: particulas / s de agua levantada por los gases al flotar bajo (por Propulsor)

-- Impact splash
local IMPACT_MIN_DV = 18          -- studs/s change in vertical velocity that counts as a slam (lower = more sensitive)
local IMPACT_COOLDOWN = 0.4
local SPLASH_SOUND_IDS = {        -- REPLACE with your own splash sounds
	"rbxassetid://9120589560",
}

local SMOKE = "rbxasset://textures/particles/smoke_main.dds"

-- Partes Propulsor del bote (tag "propulsor", o hijas llamadas "Propulsor"). Cada una tiene su churn y su espuma.
local function FindPropulsors(boat)
	local list = {}
	for _, inst in CS:GetTagged("propulsor") do
		if inst:IsA("BasePart") and inst:IsDescendantOf(boat) then
			table.insert(list, inst)
		end
	end
	if #list == 0 then
		for _, inst in boat:GetChildren() do
			if inst.Name == "Propulsor" and inst:IsA("BasePart") then
				table.insert(list, inst)
			end
		end
	end
	return list
end

local folder = Instance.new("Folder")
folder.Name = "WakeFolder"
folder.Parent = workspace

-- // Part pool
local pool = {}
local function getPart()
	local p = table.remove(pool)
	if p then
		return p
	end
	p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.Color = Color3.new(1, 1, 1)
	return p
end
local function releasePart(p)
	p.Parent = nil
	table.insert(pool, p)
end

local function waterY(pos, fallback)
	local h = HeightLookup.Lookup(pos, "PRECISE", false)
	if h == -1 then
		return fallback
	end
	return h + SURFACE_OFFSET
end

-- // Emitter helpers
local function makeAtt(main, worldPos, worldDir, name)
	local pos = main.CFrame:PointToObjectSpace(worldPos)
	local dir = main.CFrame:VectorToObjectSpace(worldDir.Unit)
	local att = Instance.new("Attachment")
	att.Name = name
	-- +Y axis of the attachment points along dir (emitter default direction = Top)
	att.CFrame = CFrame.lookAt(pos, pos + dir) * CFrame.Angles(-math.pi / 2, 0, 0)
	att.Parent = main
	return att
end

local function makeEmitter(parent, p)
	local e = Instance.new("ParticleEmitter")
	e.Texture = p.Texture or SMOKE
	e.Color = ColorSequence.new(Color3.new(1, 1, 1))
	e.LightEmission = p.Light or 0.3
	e.Lifetime = p.Lifetime
	e.Speed = p.Speed
	e.SpreadAngle = p.Spread
	e.Acceleration = p.Accel or Vector3.zero
	e.Drag = p.Drag or 0
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = p.RotSpeed or NumberRange.new(-60, 60)
	e.Orientation = p.Orientation or Enum.ParticleOrientation.FacingCamera
	e.Size = p.Size
	e.Transparency = p.Transparency
	e.Rate = 0
	e.Enabled = true
	e.Parent = parent
	return e
end

local function seq(a, b)
	return NumberSequence.new({ NumberSequenceKeypoint.new(0, a), NumberSequenceKeypoint.new(1, b) })
end
local function fade(a, mid, b)
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, a),
		NumberSequenceKeypoint.new(0.4, mid),
		NumberSequenceKeypoint.new(1, b),
	})
end

-- // Ribbon helpers
local function renderRibbon(r, now)
	local pts, parts = r.pts, r.parts
	local segCount = math.max(#pts - 1, 0)
	while #parts > segCount do
		releasePart(table.remove(parts))
	end
	for i = 1, segCount do
		local a, b = pts[i], pts[i + 1]
		local part = parts[i]
		if not part then
			part = getPart()
			part.Parent = folder
			parts[i] = part
		end
		if b.t - a.t > 1 then
			part.Transparency = 1
			continue
		end
		local ageA = math.clamp((now - a.t) / r.life, 0, 1)
		local ageB = math.clamp((now - b.t) / r.life, 0, 1)
		local pa = a.pos + a.lat * (r.spread * ageA)
		local pb = b.pos + b.lat * (r.spread * ageB)
		local len = (pb - pa).Magnitude
		if len < 0.05 then
			part.Transparency = 1
			continue
		end
		local age = (ageA + ageB) / 2
		part.Size = Vector3.new(r.baseW + age * (r.endW - r.baseW), 0.05, len + 0.1)
		part.CFrame = CFrame.lookAt((pa + pb) / 2, pb)
		part.Transparency = r.minT + (1 - r.minT) * (age ^ 1.5)
	end
end

local function clearRibbon(r)
	for _, p in r.parts do
		releasePart(p)
	end
	table.clear(r.parts)
end

-- // Boat setup
local states = {}

local function setupBoat(boat)
	if states[boat] then
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
	local right = seat.CFrame.RightVector
	local back = -look
	local up = Vector3.yAxis

	table.sort(list, function(a, b)
		return (a.WorldPosition - main.Position):Dot(look) > (b.WorldPosition - main.Position):Dot(look)
	end)
	local function sides(a, b)
		-- returns left, right
		if (a.WorldPosition - b.WorldPosition):Dot(right) > 0 then
			return b, a
		end
		return a, b
	end
	local bowL, bowR = sides(list[1], list[2])
	local sternL, sternR = sides(list[3], list[4])

	local emitters = {} -- { e, max, curve }
	local function add(e, max, curve, idle)
		-- idle: 'water' = tambien en reposo sobre el agua; 'surface' = tambien en reposo (agua o flotando bajo)
		table.insert(emitters, { e = e, max = max, curve = curve, idle = idle })
	end

	-- Stern spray (big plume up/back)
	for _, info in { { sternL, -1 }, { sternR, 1 } } do
		local src, sign = info[1], info[2]
		local att = makeAtt(main, src.WorldPosition, back * 0.8 + up * 0.6 + right * sign * 0.25, "SternSpray")
		add(makeEmitter(att, {
			Lifetime = NumberRange.new(0.6, 1.3), Speed = NumberRange.new(6, 12),
			Spread = Vector2.new(25, 25), Accel = Vector3.new(0, -14, 0),
			Size = seq(1.2, 4.5), Transparency = seq(0.35, 1),
		}), 35, 1)
		-- fine droplets
		add(makeEmitter(att, {
			Lifetime = NumberRange.new(0.5, 1.0), Speed = NumberRange.new(10, 22),
			Spread = Vector2.new(35, 35), Accel = Vector3.new(0, -45, 0),
			Size = seq(0.35, 0.15), Transparency = seq(0.1, 1), Light = 0.1,
		}), 20, 1.2)
	end

	-- Bow spray (thrown sideways and up)
	for _, info in { { bowL, -1 }, { bowR, 1 } } do
		local src, sign = info[1], info[2]
		local att = makeAtt(main, src.WorldPosition, right * sign * 0.8 + up * 0.7 + look * 0.2, "BowSpray")
		add(makeEmitter(att, {
			Lifetime = NumberRange.new(0.5, 1.1), Speed = NumberRange.new(5, 11),
			Spread = Vector2.new(20, 20), Accel = Vector3.new(0, -16, 0),
			Size = seq(0.8, 3.2), Transparency = seq(0.4, 1),
		}), 20, 1.5)
	end

	-- Propeller churn + surface foam: uno por cada Propulsor (si no hay, uno al centro de la popa)
	local sources = {}
	for _, part in FindPropulsors(boat) do
		table.insert(sources, part.Position)
	end
	if #sources == 0 then
		table.insert(sources, (sternL.WorldPosition + sternR.WorldPosition) / 2)
	end
	local foamAtts = {}
	for i, srcPos in sources do
		local churnAtt = makeAtt(main, srcPos, back * 0.7 + up * 0.35, "Churn" .. i)
		add(makeEmitter(churnAtt, {
			Lifetime = NumberRange.new(0.8, 1.6), Speed = NumberRange.new(4, 9),
			Spread = Vector2.new(30, 30), Accel = Vector3.new(0, -4, 0),
			Size = seq(2, 7), Transparency = fade(0.3, 0.6, 1),
		}), 18, 0.8, 'water')

		-- v21: la espuma de superficie ya NO es de particulas (quedaban fijas en el mundo mientras el agua subia y bajaba:
		-- se hundian, se encimaban y reaparecian). La estela se pinta en los vertices del mar (WakeTracker + ParallelWorker).
		-- Solo se conserva el punto que sigue el agua bajo cada Propulsor, para el agua levantada por los gases (downwash).
		local foamAtt = makeAtt(main, srcPos, up, "SurfaceFoam" .. i)
		table.insert(foamAtts, foamAtt)
	end

	-- v19: agua levantada por los gases al flotar bajo (sigue el punto del agua bajo cada Propulsor, como la espuma)
	local downwash = {}
	for _, att in foamAtts do
		table.insert(downwash, makeEmitter(att, {
			Lifetime = NumberRange.new(0.6, 1.2), Speed = NumberRange.new(10, 22),
			Spread = Vector2.new(75, 75), Accel = Vector3.new(0, -18, 0),
			Size = seq(1.5, 5), Transparency = fade(0.35, 0.65, 1), Light = 0.15,
		}))
	end

	-- Impact effects (burst only)
	local centerAtt = main:FindFirstChild("Center")
	local impactAtt = makeAtt(main, centerAtt and centerAtt.WorldPosition or main.Position, up, "ImpactSplash")
	local impact = {
		splash = makeEmitter(impactAtt, {
			Lifetime = NumberRange.new(0.8, 1.5), Speed = NumberRange.new(15, 35),
			Spread = Vector2.new(45, 45), Accel = Vector3.new(0, -45, 0),
			Size = seq(3, 10), Transparency = seq(0.3, 1),
		}),
		drops = makeEmitter(impactAtt, {
			Lifetime = NumberRange.new(0.6, 1.2), Speed = NumberRange.new(25, 55),
			Spread = Vector2.new(65, 65), Accel = Vector3.new(0, -70, 0),
			Size = seq(0.5, 0.2), Transparency = seq(0.1, 1), Light = 0.1,
		}),
		ripple = makeEmitter(impactAtt, {
			Lifetime = NumberRange.new(1.2, 1.6), Speed = NumberRange.new(0, 0),
			Spread = Vector2.new(0, 0), Size = seq(6, 45), Transparency = seq(0.5, 1),
			Orientation = Enum.ParticleOrientation.FacingCameraWorldUp, RotSpeed = NumberRange.new(0, 0), Light = 0.1,
		}),
	}

	-- Ribbons
	local function ribbon(src, sign, spread, life, baseW, endW, minT)
		return {
			src = src, sign = sign, spread = spread, life = life, baseW = baseW, endW = endW, minT = minT,
			pts = {}, parts = {},
		}
	end
	-- La estela ahora se pinta en los vertices del oceano (WakeTracker + ParallelWorker)
	local ribbons = {}

	states[boat] = {
		boat = boat, main = main, seat = seat,
		emitters = emitters, foamAtts = foamAtts, downwash = downwash, impact = impact, impactAtt = impactAtt,
		ribbons = ribbons, lastT = 0, lastPos = Vector3.zero, frame = 0,
		prevVy = 0, lastImpact = 0,
		prevPos = nil, prevClock = 0, vel = Vector3.zero,
	}

	boat.Destroying:Once(function()
		local s = states[boat]
		if s then
			for _, r in s.ribbons do
				clearRibbon(r)
			end
			states[boat] = nil
		end
	end)
end

-- // Impact
local function playSplash(s, strength)
	if #SPLASH_SOUND_IDS == 0 then
		return
	end
	local snd = Instance.new("Sound")
	snd.SoundId = SPLASH_SOUND_IDS[math.random(#SPLASH_SOUND_IDS)]
	snd.Volume = 0.6 + 3 * strength
	snd.PlaybackSpeed = 0.9 + math.random() * 0.3 + (1 - strength) * 0.2
	snd.RollOffMaxDistance = 400
	snd.Parent = s.impactAtt
	snd:Play()
	Debris:AddItem(snd, 3)
end

local function doImpact(s, strength)
	s.impact.splash:Emit(math.floor(25 + 60 * strength))
	s.impact.drops:Emit(math.floor(30 + 90 * strength))
	s.impact.ripple:Emit(1)
	playSplash(s, strength)
end

-- // Update
local function update(s)
	local now = workspace:GetServerTimeNow()
	-- Velocidad a partir del movimiento real (la nave se mueve sin fisica, AssemblyLinearVelocity no es fiable)
	local pos = s.main.Position
	local clock = os.clock()
	if s.prevPos then
		local dtv = clock - s.prevClock
		if dtv > 1e-3 then
			s.vel = s.vel:Lerp((pos - s.prevPos) / dtv, 0.4)
		end
	end
	s.prevPos, s.prevClock = pos, clock
	local vel = s.vel
	local speed = Vector3.new(vel.X, 0, vel.Z).Magnitude
	-- En vuelo (FlightMode ~= Water, ver Serial/BoatDrive) la nave no toca el agua: sin salpicaduras de impacto.
	-- v14: la espuma y el spray solo aparecen si vuela cerca del agua (WAKE_FULL_HEIGHT..WAKE_HEIGHT, se desvanecen).
	local OnWater = (s.seat.Parent:GetAttribute("FlightMode") or "Water") == "Water"
	local fade = 1
	if not OnWater then
		local h = HeightLookup.Lookup(pos, "PRECISE", false)
		if h == -1 then
			fade = 0
		else
			local height = pos.Y - h - s.main.Size.Y / 2
			fade = math.clamp(1 - (height - FLIGHT.WAKE_FULL_HEIGHT) / (FLIGHT.WAKE_HEIGHT - FLIGHT.WAKE_FULL_HEIGHT), 0, 1)
		end
	end
	local active = speed > MIN_SPEED and fade > 0.05
	s.frame += 1

	-- Impact splash: sudden positive change in vertical velocity (hull hitting water / wave)
	local dv = vel.Y - s.prevVy
	if OnWater and dv > IMPACT_MIN_DV and now - s.lastImpact > IMPACT_COOLDOWN then
		s.lastImpact = now
		doImpact(s, math.clamp(dv / 60, 0.2, 1))
	end
	s.prevVy = vel.Y

	-- Particle rates scale with speed
	local ratio = if active then math.clamp((speed - MIN_SPEED) / (SPEED_FULL - MIN_SPEED), 0, 1) * fade else 0
	-- v19: en reposo sigue habiendo agitacion (sobre el agua, o flotando bajo para la espuma de superficie)
	local idleWater = if OnWater then IDLE_RATIO else 0
	local idleSurface = if fade > 0.05 then IDLE_RATIO * fade else 0
	for _, em in s.emitters do
		local r = ratio
		if em.idle == "water" then
			r = math.max(r, idleWater)
		elseif em.idle == "surface" then
			r = math.max(r, idleSurface)
		end
		em.e.Rate = em.max * (r ^ em.curve)
	end
	local washRate = if OnWater then 0 else DOWNWASH_MAX * fade
	for _, wash in s.downwash do
		wash.Rate = washRate
	end

	-- Keep surface foam on the water
	for _, att in s.foamAtts do
		local fp = att.WorldPosition
		att.WorldPosition = Vector3.new(fp.X, waterY(fp, fp.Y), fp.Z)
	end

	-- Record ribbon points
	local center = s.main.Position
	if active and now - s.lastT >= RIBBON_INTERVAL and ((center - s.lastPos).Magnitude >= RIBBON_MIN_DIST or s.lastT == 0) then
		s.lastT = now
		s.lastPos = center
		local right = s.seat.CFrame.RightVector * Vector3.new(1, 0, 1)
		right = if right.Magnitude > 0 then right.Unit else Vector3.xAxis
		for _, r in s.ribbons do
			local p = r.src()
			table.insert(r.pts, {
				pos = Vector3.new(p.X, waterY(p, p.Y), p.Z),
				lat = right * r.sign,
				t = now,
			})
		end
	end

	-- Prune and refresh heights (one ribbon per frame, round-robin)
	for _, r in s.ribbons do
		while #r.pts > 0 and now - r.pts[1].t > r.life do
			table.remove(r.pts, 1)
		end
	end
	local rr = s.ribbons[(s.frame % math.max(#s.ribbons, 1)) + 1]
	if rr then
		for _, p in rr.pts do
			p.pos = Vector3.new(p.pos.X, waterY(p.pos, p.pos.Y), p.pos.Z)
		end
	end

	for _, r in s.ribbons do
		renderRibbon(r, now)
	end
end

-- // Boat discovery
task.spawn(function()
	task.wait(STARTUP_DELAY)

	for _, boat in CS:GetTagged("Boat") do
		if boat:IsA("Model") then
			task.spawn(setupBoat, boat)
		end
	end
	CS:GetInstanceAddedSignal("Boat"):Connect(function(boat)
		if boat:IsA("Model") then
			task.spawn(setupBoat, boat)
		end
	end)

	local sb = workspace:FindFirstChild("ServerBoat")
	if sb and sb:IsA("Model") then
		task.spawn(setupBoat, sb)
	end

	RunService.Heartbeat:Connect(function()
		for _, s in states do
			update(s)
		end
	end)
end)
