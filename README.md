# estelar

This readme file mainly works as a list for improvements ideas, future sys integrations, etc.
Also include some issues which gotta be fixed.
Currently working on Miller's planet, more places might be added, however, current objetive is developing a fully functional/interactive/bug free Miller's planet experience.

* Fix published game online sync, only driver sees the ship movement, others see it still, prob happens after respawning.
* Fix player fling when touching ship.
* Fix wrong teleport when leaving ship, make it possible to leave only when on water and standing still

*Search for every possible issue related to online sync (game published)

Options for more realistic water [ask for recommendation]
- Keep system and improve textures and physics
- Change still water for native studio water (?), plus keep big wave from original system

Player:
* Custom walking anim (lift legs)
* Add water FX (Beam when idle, splash when moving)
* Fix walkspeed, disable jump.
* Suit w/ visual fps helmet. (?)

Sounds:
* Quiet sea.
* Wave roaming.
* Footsteps

Visuals:
* Add ship lights/sounds/others effets as gas ejection, maintain atachment system.
* Improve ship's trail/splash on sea.
* Change ship's engine effects to match movie -low priority.
* Add camera shaking/blur/etc depending on movement/waving.

Sys:
* Fix particle emitters attachment location (BoatWakes > func makeAtt).
* Add multiple cameras attached to the ship for immersion.
* Add enter driver/passenger seats prompt by the ship door:
  (Include entering, exiting sound).
* Ship's ability to fly -implemented, needs in-game tuning (all values in Settings > FLIGHT):
  * Controls (v14): F take off / land (while landing: cancel). In flight (v17): W main thrusters (forward only, HORIZ_ACCEL_MAX), S brakes to a stop (no reverse), A/D roll (tilts, accelerates a little and turns the ship: no yaw key; side gas nozzles fire opposite to the turn), Q/E up/down (vertical gas thrusters, bottom nozzles always fire while airborne: GAS.HOVER). Space is only sunk so the pilot isn't ejected; pitch keys were removed (pitch is visual only). Flight keeps full horizontal authority at any height above the hard floor (the gate only applies to takeoff/landing). Landing hands over to water with a soft descent (SOFT_LAND_* in BoatDrive). Gas nozzle effects (v18): particles are LockedToPart so they eject from the nozzle instead of trailing in the world; to customize, put ParticleEmitters in ReplicatedStorage > Gerstner > GasEffects (optional subfolders Vertical / Lateral); their Rate is the full-thrust rate. In water mode W/A/S/D are still the steering wheel. Space is always sunk while seated so the pilot isn't ejected from the seat.
  * Pitch also gets a visual nose-up/down when climbing (PITCH_CLIMB). Inputs go through a virtual stick (STICK_RISE / STICK_RETURN) and HOLD_BRAKE brakes by itself with the stick centered.
  * Wake: only while flying near the water (WAKE_FULL_HEIGHT..WAKE_HEIGHT, fades out). Vertical gas thrusters, flight sounds and camera shake: StarterPlayerScripts/FlightEffects (Settings.FLIGHT GAS / SOUNDS / SHAKE). SOUNDS IDs are empty: fill them in.
  * States (BoatDrive.Mode, granted by the server through the Boat's FlightMode attribute): Water > Takeoff > Flight > Landing > Water. Takeoff climbs by itself past the gate; Landing descends by itself and hands over to the water simulation.
  * Hover/flight reference is the sampled Gerstner surface (HeightLookup, giant wave included); the rendered ocean planes stay non-collidable.
  * Hard floor: wave height under the 4 buoyancy points, with hull tilt (MIN_CLEARANCE). Descent commands can't cross it (the altitude target is clamped to it), and position is clamped to it as a last resort.
  * Gate: no horizontal tilt or acceleration until the ship is GATE_HEIGHT above the local wave (blends in over GATE_BLEND). While landing, tilt and speed limits drop (LAND_TILT_SCALE, LAND_SPEED_SCALE) and shrink further close to the water.
  * Lookahead: every LOOK_INTERVAL the wave is sampled along position + velocity * t (wave at server time + t). If the climb needed exceeds LOOK_RATE_FRACTION of MAX_CLIMB_RATE, horizontal speed and tilt limits drop (fast attack, slow release). The clearance target is smoothed and its rate of change is capped (TARGET_RISE_RATE / TARGET_FALL_RATE).
  * Ceiling: MAX_ALTITUDE above sea level (absolute, not relative to the wave) so the giant wave can't be flown over. If the wave rises above the ceiling the ship is swept (back to Water, no takeoff for SWEPT_LOCKOUT_SECONDS).
  * Server (ServerBoat/Handler + BoatDrive.Validate): grants/denies takeoff, promotes Takeoff > Flight and Landing > Water from its own wave samples, and every VALIDATE_INTERVAL checks the replicated pilot's state: ceiling, clearance, horizontal speed, horizontal acceleration, vertical speed, and flying while in Water mode. After STRIKES_TO_ENFORCE violations in a row it takes the ship over (client suspended, ship auto-lands) and locks takeoff for LOCKOUT_SECONDS. An empty ship that was flying lands by itself.
  * Giant-wave wrap: the old "90 s" note no longer applies (Spacing / Speed is now 200 s). GetGiantWaveCenter jumps by exactly Spacing each cycle, but ComputeGiantWave reduces the distance modulo Spacing, so the height is continuous across the wrap and lookahead sampling (which just adds t) is too. The surge term is continuous as well.
  * TODO: HUD (mode, height, ceiling warning), gamepad bindings, flight sounds/effects (BoatWake already stops wake/splash while not in Water).
* v21 boat motion (Settings > BOAT_MOTION): soft heave/tilt response in calm water (heavy, rocks), visual sway, bank when turning, nose up when accelerating, constant tide drift (CURRENT_SPEED). On the giant wave the engine is off (steering only), the wave carries the ship (GIANT_LOCK) and the response goes back to the stiff values. Surface-foam particles were removed from BoatWake: the wake is only the vertex foam (WakeTracker + ParallelWorker). Door = boarding prompt and exit point.
* Improve sea foam/movement/waves (lake-like):
  * Add a few low-amplitude wave components to the existing Gerstner waves.
  * Use seeded, deterministic variation so every client sees the same motion—avoid changing wave parameters randomly each frame, which can flicker or desync.
  * CONSIDER -- Keep wavelengths large enough for the mesh to represent. The current vertex spacing is 48 studs, so very tiny waves won’t show as actual surface geometry; those are better suggested with a moving texture instead.
  * Because the ocean currently updates every vertex at full quality, adding waves does add computation. A few components should be manageable, but the result should be profiled in-game.
 
Upcoming:
* Add TARS.
