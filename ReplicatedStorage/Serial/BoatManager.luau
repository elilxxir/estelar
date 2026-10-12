-- script dentro de carpeta Serial dentro de script Gerstner dentro de ReplicatedStorage

--!strict
--!optimize 2

local RS = game:GetService('ReplicatedStorage')
local CS = game:GetService('CollectionService')
local RunService = game:GetService('RunService')

local IS_CLIENT = RunService:IsClient()
local HeightLookup = require(RS.HeightLookup)
local OctreeModule = require(RS:WaitForChild('Octree'))

local BOAT_TREE = nil
local DRAG_COEFFICIENT = 0.075

type ZONE_INFO = {
	SpeedMultiplier: number,
	AmplitudeMultiplier: number,
	PhaseMultiplier: number,
	CURRENT_ZONE: {}?,
}

local BoatManager = {}

function BoatManager.CalculateBuoyancy(CenterOfMass: Vector3, Bottom: Vector3, Points: { Attachment }, Length: number, Width: number, Height: number, ZoneInfo: ZONE_INFO): (Vector3, CFrame, number)
	local TopLeftHeight = HeightLookup.Lookup(Points[1].WorldPosition, "PRECISE", false, ZoneInfo.SpeedMultiplier, ZoneInfo.PhaseMultiplier, ZoneInfo.AmplitudeMultiplier, ZoneInfo.CURRENT_ZONE)
	local TopRightHeight = HeightLookup.Lookup(Points[2].WorldPosition, "PRECISE", false, ZoneInfo.SpeedMultiplier, ZoneInfo.PhaseMultiplier, ZoneInfo.AmplitudeMultiplier, ZoneInfo.CURRENT_ZONE)
	local BottomLeftHeight = HeightLookup.Lookup(Points[3].WorldPosition, "PRECISE", false, ZoneInfo.SpeedMultiplier, ZoneInfo.PhaseMultiplier, ZoneInfo.AmplitudeMultiplier, ZoneInfo.CURRENT_ZONE)
	local BottomRightHeight = HeightLookup.Lookup(Points[4].WorldPosition, "PRECISE", false, ZoneInfo.SpeedMultiplier, ZoneInfo.PhaseMultiplier, ZoneInfo.AmplitudeMultiplier, ZoneInfo.CURRENT_ZONE)

	local TotalHeight = (TopLeftHeight + TopRightHeight + BottomLeftHeight + BottomRightHeight)
	
	-- // Orientation
	local Front = (TopLeftHeight + TopRightHeight) / 2
	local Back = (BottomLeftHeight + BottomRightHeight) / 2
	local Left = (TopLeftHeight + BottomLeftHeight) / 2
	local Right = (TopRightHeight + BottomRightHeight) / 2
	
	local pitch = math.atan2(Front - Back, Length)
	local roll = math.atan2(Right - Left, Width)
	
	local Orientation = CFrame.fromEulerAnglesXYZ(pitch, 0, roll)
	
	
	local WaveHeightCenter = (TotalHeight / 4)
	local Depth = WaveHeightCenter - Bottom.Y
	if Depth > -0.5 then
		local ClampedDepth = math.min(Depth, 0)
		local TargetHeight = (WaveHeightCenter + ClampedDepth)
		local RelativeSpeed = (CenterOfMass.Y - TargetHeight)
		local DRAG = RelativeSpeed * DRAG_COEFFICIENT

		local TargetY = (WaveHeightCenter + Height) - DRAG
		return Vector3.new(0, TargetY, 0), Orientation, ClampedDepth

	elseif Depth < -0.25 then
		return Vector3.zero, Orientation, 0
	end
	return Vector3.zero, Orientation, 0
end

return BoatManager
