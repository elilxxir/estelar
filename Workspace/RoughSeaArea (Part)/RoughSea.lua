-- script dentro de la part RoughSeaArea

task.wait(5)
local ZoneManager = require(game.ReplicatedStorage.Gerstner.Serial.ZoneManager)

local function SpawnRoughSeaArea()
	local Parameters = {
		Type = 'RoughSea',
		Link = script.Parent,
		Radius = 400,

		PhaseMultiplier =  0.2,
		SpeedMultiplier = '5',
		AmplitudeMultiplier = 30,
	}
	local NODE = ZoneManager:InsertZone(script.Parent.Position, Parameters)
	
end

SpawnRoughSeaArea()
print('Added rough sea zone!')