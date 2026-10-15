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

-- // Ola gigante lejana (StarterPlayerScripts/GiantWaveFar). Si se desactiva, el plano desvanece la ola por completo hacia su borde
-- // (Drop = infinito en Gerstner.ComputeGiantWave), para no dejar un acantilado contra los planos secundarios.
local GIANT_FAR_WAVE = true
if GIANT_FAR_WAVE == false then
	GerstnerWave.GIANT_CONFIG.Drop = math.huge
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
	FrustumRenderDistance = 1500,
	LowRenderDistance = 200,
	MaxChunkRenderDistance = 2800,

	Subdivisions = {
		[1] = 400,
		[2] = 200,
	},

	--Waves = BrownianMotionWaves(6);
	Waves = {
		-- // Mar quieto tipo Miller: oleaje largo y lento + olas medianas + rizado fino.
		-- // Las direcciones deben ser unitarias (.Unit). Amplitud = Steepness / (2pi / WaveLength). Velocidad = sqrt(9.8 / (2pi / WaveLength)).
		-- // Oleaje largo (swell): 1 a 2 studs de altura, ~20 s entre olas
		GerstnerWave.new(Vector3.new(1, 0, 0.15).Unit,    620, 0.0024),
		GerstnerWave.new(Vector3.new(0.9, 0, -0.4).Unit,  470, 0.0022),
		GerstnerWave.new(Vector3.new(0.6, 0, 0.8).Unit,   340, 0.0019),
		-- // Olas medianas
		GerstnerWave.new(Vector3.new(0.5, 0, -0.85).Unit, 170, 0.0060),
		GerstnerWave.new(Vector3.new(0.85, 0, 0.3).Unit,  115, 0.0066),
		GerstnerWave.new(Vector3.new(-0.2, 0, 0.95).Unit,  80, 0.0192), -- // v02 (antes 0.024)
		-- // Rizado fino (cerca de la camara la malla es de 12 studs, asi que 36+ de largo se ve aceptable)
		GerstnerWave.new(Vector3.new(0.4, 0, 0.9).Unit,    50, 0.0270), -- // v02 (antes 0.030)
		GerstnerWave.new(Vector3.new(-0.7, 0, 0.45).Unit,  36, 0.0270), -- // v02 (antes 0.030)
		-- // v01: trenes extra en direcciones cruzadas. Rompen el patron repetitivo del mar quieto (interferencia entre olas).
		-- // Cada ola cuesta calculo por vertice y por consulta de altura: si baja el rendimiento, comenta lineas de aqui.
		-- // Todas >= 36 de largo (la malla cerca de la camara es de 12 studs). Suma de Steepness total ~0.30 (< 1, sin bucles).
		GerstnerWave.new(Vector3.new(0.75, 0, -0.65).Unit, 260, 0.0054), -- // ~0.74 studs
		GerstnerWave.new(Vector3.new(-0.45, 0, 0.9).Unit,  140, 0.0066), -- // ~0.49 studs
		GerstnerWave.new(Vector3.new(0.95, 0, -0.2).Unit,   95, 0.0156), -- // ~0.39 studs
		GerstnerWave.new(Vector3.new(-0.9, 0, -0.35).Unit,  65, 0.0180), -- // ~0.31 studs, rizado que viaja contra el viento
		GerstnerWave.new(Vector3.new(0.1, 0, -1).Unit,      44, 0.0204), -- // ~0.24 studs, rizado fino lateral
	},

	ISLAND_SPEED_MULTIPLIER = 1.1,
	ISLAND_PHASE_MULTIPLIER = 1,

	WAVE_COLORS = {
		CREST = Color3.fromRGB(118, 128, 126); -- // v02 (antes 95,105,110): destello gris calido
		TROUGH = Color3.fromRGB(32, 48, 54); -- // v02 (antes 40,48,55): teal pizarra oscuro
		VORTEX = Color3.fromRGB(18, 28, 33);
		SHORE = Color3.fromRGB(60, 70, 75)
	},
	SURFACE_APPEARANCE_COLOR = Color3.fromRGB(80, 118, 161), -- // v03: tinte del SurfaceAppearance del mar (AlphaMode = Transparency)
	UV_SCROLL_SPEED = 1/90, -- // Mas lento = mar mas quieto (modo lago)
	UV_SCROLL_DIRECTION = Vector2.new(1, 1),

	DEPTH_ENABLED = false, -- // Note: Check known issues #4 in thread linked below
	DEPTH_RAY_LENGTH = Vector3.new(0, -15, 0),
	DEPTH_RAY_OFFSET = Vector3.new(0, 5, 0),

	SMALL_WAVE_CONTRAST = 0.8, -- // Contraste de color para ver las mini olas (0 = sin contraste). Ver Helper.GetVertexColor
	COLOR_MAX_HEIGHT = 2, -- // v10: tope de altura para el color de las olas. La ola gigante queda de un solo tono en vez de aclararse hasta casi blanco
	GIANT_FAR_EXTRA_DROP = 14, -- // v10: studs extra que baja la ola lejana (GiantWaveFar). Debe ser > suma de amplitudes (~8.3) para que no asome a traves del plano
	WHITECAP_HEIGHT = math.huge, -- // v09: sin espuma (antes 60). La ola gigante superaba ese umbral y se pintaba de blanco
	SHORE_TRANSPARENCY = 0.2,

	-- // Vuelo de la nave (Serial/BoatDrive, StarterPlayerScripts/BoatDriver, ServerBoat/Handler).
	-- // "Altura" = studs de la nave por encima de su altura de flotacion sobre la ola local (0 = flotando).
	-- // La referencia de vuelo es la superficie de Gerstner muestreada (HeightLookup); los planos del mar no colisionan.
	FLIGHT = {
		ENABLED = true,
		KEYS = {
			Toggle = Enum.KeyCode.F, -- // Despegar / aterrizar (en aterrizaje: cancelar y volver a subir)
			Up = Enum.KeyCode.E, -- // v14: subir (propulsores verticales, gas hacia abajo)
			Down = Enum.KeyCode.Q, -- // v14: bajar (gas hacia arriba)
			PitchUp = Enum.KeyCode.Space, -- // v16: nariz arriba
			PitchDown = Enum.KeyCode.LeftShift, -- // v16: nariz abajo
			RollLeft = Enum.KeyCode.A, -- // v14: alabeo (inclina y vira)
			RollRight = Enum.KeyCode.D,
		}, -- // v16: W / S = propulsores principales (adelante / atras, Seat.Throttle). En modo agua W / A / S / D siguen siendo el volante del VehicleSeat

		-- // Alturas
		MIN_CLEARANCE = 8, -- // Altura minima del punto de flotacion mas bajo sobre su ola (con la inclinacion del casco)
		GATE_HEIGHT = 25, -- // Hasta esta altura no hay inclinacion horizontal ni aceleracion horizontal
		GATE_BLEND = 15, -- // Studs sobre GATE_HEIGHT en los que la autoridad horizontal sube de 0 a 1
		TAKEOFF_EXTRA = 20, -- // El despegue sube hasta GATE_HEIGHT + TAKEOFF_EXTRA
		LIFTOFF_CLEARANCE = -2, -- // Piso duro durante Takeoff: puede empezar un poco hundida (flotando) sin que el piso la salte de golpe
		TOUCHDOWN_CLEARANCE = 1, -- // Altura minima al aterrizar (el agua toma el control suavemente)
		TOUCHDOWN_HEIGHT = 3, -- // El servidor pasa de Landing a Water por debajo de esta altura
		MAX_ALTITUDE = 160, -- // Techo sobre el nivel del mar (PLANE_OFFSET.Y). Absoluto, NO relativo a la ola: la ola gigante no se puede sobrevolar
		SWEPT_TOLERANCE = 2, -- // Si la ola sube por encima del techo mas esto, la nave es arrastrada (vuelve a Water)

		-- // Vertical (colectivo)
		MAX_CLIMB_RATE = 45, -- // studs/s
		MAX_DESCENT_RATE = 35,
		TAKEOFF_CLIMB_RATE = 18,
		LAND_MAX_RATE = 14, -- // Velocidad de descenso al aterrizar lejos del agua
		LAND_MIN_RATE = 3, -- // ...y cerca del agua
		LAND_RATE_PER_HEIGHT = 0.5, -- // 1/s: rate = altura * esto, entre LAND_MIN_RATE y LAND_MAX_RATE
		ALT_GAIN = 1.5, -- // 1/s: error de altura -> velocidad vertical deseada
		VERT_GAIN = 4, -- // 1/s: error de velocidad vertical -> aceleracion
		MAX_UP_ACCEL = 60, -- // studs/s^2
		MAX_DOWN_ACCEL = 40,
		ALT_LEAD = 30, -- // Cuanto puede adelantarse la altitud objetivo a la nave

		-- // Horizontal (cabeceo / alabeo -> aceleracion)
		MAX_SPEED = 140, -- // studs/s
		HORIZ_ACCEL_MAX = 50, -- // v14 (antes 45): empuje de los propulsores principales (Espacio / Shift). studs/s^2 con la inclinacion maxima. La resistencia del aire es HORIZ_ACCEL_MAX / MAX_SPEED
		MAX_TILT = 0.4, -- // rad. Cabeceo / alabeo maximos (W / S, A / D)
		TILT_FREQ = 5, -- // v14: rad/s. Respuesta del cabeceo / alabeo visual
		TILT_DAMPING = 0.85,
		BRAKE_GAIN = 1.5, -- // v14: studs/s^2 de frenado por cada stud/s sobre el limite de velocidad
		BRAKE_FRACTION = 0.8, -- // v14: fraccion de HORIZ_ACCEL_MAX disponible para frenar
		TURN_RATE = math.rad(60), -- // v14: rad/s
		YAW_SMOOTH = 0.3, -- // v14: s. La guinada arranca y se detiene con un poco de inercia

		-- // v14: manejo tipo Ranger (Interstellar). Las teclas son digitales; se convierten en una palanca virtual que se mueve
		-- // con velocidad limitada (como una palanca / yugo) y la nave responde con peso: tarda en inclinarse, en acelerar y en frenar.
		STICK_RISE = 3.5, -- // v14: unidades de palanca / s al empujar (1 = tope). 3.5 = 0.3 s hasta el tope
		STICK_RETURN = 4.5, -- // v14: ...al soltar (vuelve a 0 un poco mas rapido que al empujar)
		COLLECTIVE_RISE = 2.5, -- // v14: palanca del colectivo. Mas lenta: los motores verticales tardan en subir de potencia
		COLLECTIVE_RETURN = 3, -- // v14
		HOLD_BRAKE = 0.5, -- // v14: 1/s. Freno asistido con la palanca centrada (la computadora de vuelo frena sola, suave)
		HOLD_BRAKE_FRACTION = 0.5, -- // v14: fraccion de HORIZ_ACCEL_MAX que puede usar ese freno
		PITCH_CLIMB = 0.10, -- // v14: rad de cabeceo visual (nariz arriba al subir, abajo al bajar) a MAX_CLIMB_RATE
		TILT_ACCEL = 16, -- // v14: studs/s^2 que acelera la inclinacion maxima (W / S, A / D). "Un poco": el empuje fuerte es Espacio / Shift
		ROLL_TURN = 0.8, -- // v14: fraccion de TURN_RATE con el alabeo maximo (el alabeo hace virar; en vuelo no hay tecla de guinada)
		NOSE_ALIGN = 0.35, -- // v14: 1/s. Gira la velocidad hacia donde apunta la nariz (vuelo hacia adelante). 0 = deriva libre. Se anula al usar Q / E
		ACCEL_CAP = 1.4, -- // v14: tope de la aceleracion horizontal total, en veces HORIZ_ACCEL_MAX (debe ser < SERVER_TOLERANCE)

		-- // Aterrizaje: menos inclinacion y velocidad
		LAND_TILT_SCALE = 0.35,
		LAND_SPEED_SCALE = 0.3, -- // Limite de velocidad (fraccion) al empezar a aterrizar
		LAND_MIN_SPEED_SCALE = 0.12, -- // ...y al llegar a GATE_HEIGHT o menos

		-- // Muestreo hacia adelante: mira la altura de la ola a lo largo de la trayectoria
		LOOKAHEAD_TIMES = { 0.5, 1, 1.75, 2.75 }, -- // s hacia el futuro (posicion = velocidad * t, ola = hora del servidor + t)
		LOOK_INTERVAL = 0.05, -- // s entre muestreos
		LOOK_MARGIN = 4, -- // studs extra de margen sobre MIN_CLEARANCE al mirar hacia adelante
		LOOK_RATE_FRACTION = 0.7, -- // Fraccion de MAX_CLIMB_RATE que se considera "al limite del controlador"
		MIN_SPEED_SCALE = 0.15, -- // Tope inferior del limite de velocidad por muestreo hacia adelante
		MIN_TILT_SCALE = 0.35,
		SCALE_ATTACK = 0.15, -- // s: cuanto tarda en reducir los limites (rapido)
		SCALE_RELEASE = 1.2, -- // s: cuanto tarda en recuperarlos (lento)
		TARGET_RISE_RATE = 40, -- // studs/s: tope al cambio del objetivo de altura minima (debe ser <= MAX_CLIMB_RATE)
		TARGET_FALL_RATE = 12,
		TARGET_SMOOTH = 0.25, -- // s

		-- // Validacion del servidor
		VALIDATE_INTERVAL = 0.25, -- // s entre comprobaciones
		SERVER_TOLERANCE = 1.6, -- // Multiplicador de los limites (jitter de replicacion)
		CLEARANCE_TOLERANCE = 4, -- // studs
		CEILING_TOLERANCE = 10, -- // studs
		UNAUTHORIZED_HEIGHT = 80, -- // En modo Water, mas alto que esto durante 2 comprobaciones = vuelo no autorizado
		STRIKES_TO_ENFORCE = 3, -- // Comprobaciones seguidas con infraccion antes de tomar el control
		LOCKOUT_SECONDS = 8, -- // Sin despegar tras una infraccion
		SWEPT_LOCKOUT_SECONDS = 6, -- // Sin despegar tras ser arrastrado por la ola
		REQUEST_COOLDOWN = 0.5, -- // s entre peticiones del cliente
		ALLOW_IN_WHIRLPOOL = false,

		-- // v14: estela y salpicaduras en vuelo. Solo hay estela si la nave vuela cerca del agua.
		WAKE_FULL_HEIGHT = 6, -- // studs sobre el agua (casco) hasta los que la estela es completa
		WAKE_HEIGHT = 16, -- // studs sobre el agua a partir de los que ya no hay estela (entre ambas se desvanece)

		-- // v14: propulsores verticales pequenos (eyeccion de gas). Suben: gas hacia abajo; bajan: gas hacia arriba.
		GAS = {
			CLIMB_REF = 22, -- // studs/s de velocidad vertical que cuentan como empuje completo
			ACCEL_REF = 60, -- // studs/s^2 de aceleracion vertical que cuentan como empuje completo (pulso al arrancar / frenar)
			DEADZONE = 0.08,
			RATE = 90, -- // particulas / s por boquilla con empuje completo
		},

		-- // v14: sonidos del vuelo. REEMPLAZA los IDs (vacio = ese sonido no se crea).
		SOUNDS = {
			ThrusterLoop = '', -- // Propulsores principales en vuelo (loop). Volumen y tono suben con empuje y velocidad
			GasLoop = '', -- // Propulsores verticales pequenos (loop de eyeccion de gas)
			GasBurst = '', -- // Soplido corto cuando los propulsores verticales arrancan
			THRUSTER_VOLUME = 4,
			GAS_VOLUME = 3,
			BURST_VOLUME = 3,
			ROLLOFF = 600,
			MUTE_IN_FLIGHT = { 'Agua' }, -- // Capas de Handler > SOUND_LAYERS que se silencian en vuelo (por nombre)
		},

		-- // v14: vibracion de camara del piloto (solo en vuelo)
		SHAKE = {
			ENABLED = true,
			BASE = 0.35, -- // vibracion constante con los motores encendidos (0..1 de la intensidad maxima)
			SPEED = 0.45, -- // se suma a velocidad completa
			GAS = 0.5, -- // se suma con propulsores verticales a tope
			ROT = 0.0045, -- // rad de giro maximo
			POS = 0.09, -- // studs de desplazamiento maximo (Humanoid.CameraOffset)
			FREQ = 26, -- // Hz aproximados del temblor
		},
	},

	-- // DEBUG
	-- // Known issues thread: https://devforum.roblox.com/t/client-beta-in-experience-mesh-image-apis-now-available-in-published-experiences/3267293
	DISABLE_CHUNK_CULLING = true, -- // Actualiza todos los chunks aunque no esten en pantalla (evita vertices congelados / estirados)
	FORCE_FULL_QUALITY = true, -- // Todos los vertices se calculan cada frame (sin LOD por lerp)
	GIANT_EDGE_FADE = 350, -- // Studs en los que la ola gigante del plano baja hacia la ola lejana (GiantWaveFar)
	GIANT_EDGE_SLACK = 150, -- // Margen respecto al borde del plano donde termina ese descenso
	GIANT_FAR_WAVE = GIANT_FAR_WAVE, -- // (editar arriba, junto a la variable local) Dibuja la ola gigante mas alla del plano (StarterPlayerScripts/GiantWaveFar). false = desactivado

	FRUSTUM_CULLING_FIX = true; -- // See known issues #7

}
