-- script hijo de Gerstner

local GerstnerWave = require(script.Parent)

-- // This is our setup for the Gerstner Waves,
-- // We use a table to store multiple waves
-- // The more waves you can use, the more detail / realism you will get to actual ocean waves
-- // However, this comes at the cost of performance

--[[ 
	// Properties:
		 	1. Direction: a Vector3 value which stores the waves direction in the XZ axis
				2. WaveLength: The distance between each peak or trough. The lower the value, the more peaks, the higher, the less
				3. Amplitude: How 'high' the waves go
				4. Gravity
	
	// DEBUG: Boolean indicating whether debug messages will be shown in console.
	
  	// Grid Settings:
		Width: Width of the plane mesh (X)
		Length: Length of the plane mesh (Z)
		Padding: Distance between each vertex
		PaddingMultiplier: Multiplier for the padding. Used for tiling the material of the plane
		CHUNK_SIZE: The size of each 'chunk' for the ocean.
		PLANE_OFFSET: A Vector3 offset for the plane mesh, used if you want the plane to be on a different Y level, instead of y=0
					  as the origin.
		
	// WORKER_COUNT: How many threads or workers to use for the ocean. Should be balanced for the amount of chunks the ocean has.
	
	// FrustumRenderDistance: How far the camera plane extends for Frustum Culling. For example, any chunks past 'FrustumRenderDistance'
							  will be considered 'not in view'.
	
	// LowRenderDistance: 	  Any chunks past this distance will be considered a 'low quality' chunk, and will use lerping in order to
						  	  keep calculations at a minimum.
						  	  
	
	// MaxChunkRenderDistance: Any chunks past this distance will not have any computations done on them.
	
	// Subdivisions: Takes an array in the format of
					 [int] = Distance,
					 Where distance is just the 'range' in which subdivision will occur. This allows you to generate different
					 LOD levels depending on the ocean planes size and have more detail near the 'center' of the mesh (near the camera)
	
	// ISLAND_SPEED_MULTIPLIER / ISLAND_PHASE_MULTIPLIER: Simple multipliers for the phase and speed properties of Gerstner waves,
														  which are applied when a vertex is near an island.
														  
	// Wave Colors:
		CREST: The color of the top of a wave. Usually a lighter color compared to the trough.
		TROUGH: The color of the bottom of a wave. Usually a darker color.
		VORTEX: The intended color for a water vortex / whirlpool in the ocean.
		SHORE: The color of the ocean near shores of islands. ([DEPTH_ENABLED = TRUE] REQUIRED)
		
	// UV_SCROLL_SPEED: The speed of the texture scrolling on the ocean.
	// UV_SCROLL_DIRECTION: The direction for the texture scrolling on the ocean.
	
	// DEPTH_ENABLED: A boolean indicating whether depth coloring is active, allowing the ocean handler to automatically detect shores of islands
		and set their color to the "SHORE" color, as well as giving them some transparency.
	// DEPTH_RAY_LENGTH: The length for a raycast for depth, performed on each vertex of the mesh.
	// DEPTH_RAY_OFFSET: The offset position for depth raycasts.
	// SHORE_TRANSPARENCY: The transparency for vertices on shallow water
	
	// WHITECAP_HEIGHT: Determines the height at which ocean vertices will begin to turn white to simulate a foam effect.]]


-- // https://www.desmos.com/calculator/uvdibm39mm

local Seed = script.Seed.Value
if Seed == 0 then
	Seed = math.random(-100000, 100000)
	print(`SEED: {Seed}`)
	script.Seed.Value = Seed
end
local R = Random.new(Seed)

-- // This is basically a function to generate random waves
local WLMultiplier, AmplitudeMultiplier = 1.14, 0.86
local function BrownianMotionWaves(Amount: number): { GerstnerWave.WaveInfo }
	local Results = {}
	local WaveLength, Amplitude = 40, 0.3
	
	local PrimaryDirectionUnit = workspace.GlobalWind.Unit
	
	for i = 1, Amount do
		if Amplitude <= 0.05 then
			warn('Stopped at ' .. i .. ' as amplitude reached threshold (0.025)')
			break
		end
		local RandomDirectionUnit = R:NextUnitVector()
		local Direction = i == 1 
			and PrimaryDirectionUnit 
			or (RandomDirectionUnit + PrimaryDirectionUnit).Unit
		
		local WaveInfo = GerstnerWave.new(Direction, WaveLength, Amplitude)
		table.insert(Results, WaveInfo)
		
		WaveLength *= WLMultiplier
		Amplitude *= AmplitudeMultiplier
	end
	print('Successfully generated '.. #Results .. ' waves!')
	return Results
end

return {
	DEBUG = true,
	GRID_SETTINGS = {
		CHUNK_SIZE = 100, 
		Padding = 48,
		PLANE_OFFSET = Vector3.new(0, 25, 0),
		Width = 40,
		Length = 40,

		PaddingMultiplier = 1,
		UV_SCALE = 2;
	},

	WORKER_COUNT = 6,
	FrustumRenderDistance = 900,
	LowRenderDistance = 200,
	MaxChunkRenderDistance = 2800,

	Subdivisions = {
		[1] = 400,
		[2] = 200,
	},

	--Waves = BrownianMotionWaves(6);
	Waves = {
		GerstnerWave.new(Vector3.new(0.6, 0, 0.05), 50, 0.04),
		GerstnerWave.new(Vector3.new(0.2, 0, 0.4),  60, 0.03),
		GerstnerWave.new(Vector3.new(0.15, 0, 0.1), 75, 0.02),
	},

	ISLAND_SPEED_MULTIPLIER = 1.1,
	ISLAND_PHASE_MULTIPLIER = 1,

	WAVE_COLORS = {
		CREST = Color3.fromRGB(95, 105, 110);
		TROUGH = Color3.fromRGB(40, 48, 55);
		VORTEX = Color3.fromRGB(18, 28, 33);
		SHORE = Color3.fromRGB(60, 70, 75)
	},
	UV_SCROLL_SPEED = 1/12,
	UV_SCROLL_DIRECTION = Vector2.new(1, 1),

	DEPTH_ENABLED = false, -- // Note: Check known issues #4 in thread linked below
	DEPTH_RAY_LENGTH = Vector3.new(0, -15, 0),
	DEPTH_RAY_OFFSET = Vector3.new(0, 5, 0),

	WHITECAP_HEIGHT = 60,
	SHORE_TRANSPARENCY = 0.2,

	-- // DEBUG
	-- // Known issues thread: https://devforum.roblox.com/t/client-beta-in-experience-mesh-image-apis-now-available-in-published-experiences/3267293
	FRUSTUM_CULLING_FIX = true; -- // See known issues #7
	
}