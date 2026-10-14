# estelar

This readme file mainly works as a list for improvements ideas, future sys integrations, etc.
Also include some issues which gotta be fixed.
Currently working on Miller's planet, more places might be added, however, current objetive is developing a fully functional/interactive/bug free Miller's planet experience.

SuoundsFX:
* Quiet sea
* Wave roaming

Visuals:
* Add ship lights/sounds/others effets as gas ejection
* Improve ship's trail/splash on sea
* Add camera shaking/blur/etc depending on movement/waving

Sys:
* Fix ship's max tilt to match wave inclination.
* Add multiple cameras attached to the ship for immersion.
* Add enter driver/passenger seats prompt by the ship door:
  (Include entering, exiting sound)
* Ship's ability to fly -under consideration:
  * Keep a sampled Gerstner surface as the hover/flight reference; keep rendered ocean planes non-collidable.
  * Treat takeoff, flight, and landing as separate control states. During flight, use helicopter-like controls: pitch/roll for horizontal acceleration, yaw for heading, and collective for vertical movement.
  * Enforce minimum clearance using wave-height samples at all four buoyancy points, accounting for hull tilt. Do not allow descent commands to cross this safety limit.
  * Gate horizontal tilt and acceleration until the ship clears a configurable height above the local wave. Reduce tilt and horizontal speed while landing.
  * Sample wave height ahead along the flight path. Limit horizontal speed and tilt when the required vertical response exceeds controller limits; smooth transitions and cap changes to the clearance target.
  * Validate the flight state and forces on the server. Resolve the 90-second giant-wave wrap before relying on lookahead for safety.
  * This is a design proposal; Fly is not implemented yet.
* Improved sea foam/movement/waves (lake-like):
  * Add a few low-amplitude wave components to the existing Gerstner waves.
  * Use seeded, deterministic variation so every client sees the same motion—avoid changing wave parameters randomly each frame, which can flicker or desync.
  * Keep wavelengths large enough for the mesh to represent. The current vertex spacing is 48 studs, so very tiny waves won’t show as actual surface geometry; those are better suggested with a moving texture instead.
  * Because the ocean currently updates every vertex at full quality, adding waves does add computation. A few components should be manageable, but the result should be profiled in-game.
* Change ship's engine effects to match movie -low priority
 
Upcoming:
* Add tars
