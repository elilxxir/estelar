# estelar

This readme file mainly works as a list for improvements ideas, future sys integrations, etc and their priority.
Also include some issues which gotta be fixed.
Currently working on Miller's planet, more places might be added, however, current objetive is developing a fully functional/interactive/bug free Miller's planet experience.

Visuals:
* Add ship lights/sounds/others effets as gas ejection -low priority
* Change lighting/atmospheric settings to improve realism and match movie lighting -low priority

Sys:
* Add camera shaking/blur/etc depending on movement/waving -high priority
* Add multiple cameras attached to the ship for immersion  -low priority
* Add enter driver/passenger seats prompt by the ship door -low priority
  (Include entering, exiting sound, camera fade)
* Ship's ability to fly (? -gotta consider adding this feature
* Add ship's trail/splash on sea -high priority
  * Foam churn at the stern: Put paired Attachments near the rear corners of the boat and use lightweight ParticleEmitters for short-lived spray and foam. Scale the emission rate with boat speed; keep them off below a minimum speed.
  * The persistent wake: Draw a pair of widening, fading foam ribbons behind the boat. A Roblox Trail is a quick prototype, but it follows the boat’s attachments—not the water surface—so it can look detached when the boat bobs. For a more convincing result, render short ribbon segments locally and sample the same Gerstner water height at their positions so they sit on the waves.
  * Make it follow the boat’s actual path: Build the wake from recent boat positions/velocity, rather than just pointing it backward from the bow. That leaves a curved trail when the ship turns.
  * Keep it efficient and in sync: Generate the visual effects on each client for replicated boats; don’t replicate every particle or wake segment from the server. Use the replicated boat movement and shared server time for the water sampling, and pool/reuse ribbon segments with a short lifetime.
* Improved sea foam/movement/waves (lake-like) -high priority;
  * Add a few low-amplitude wave components to the existing Gerstner waves.
  * Use seeded, deterministic variation so every client sees the same motion—avoid changing wave parameters randomly each frame, which can flicker or desync.
  * Keep wavelengths large enough for the mesh to represent. The current vertex spacing is 48 studs, so very tiny waves won’t show as actual surface geometry; those are better suggested with a moving texture instead.
  * Because the ocean currently updates every vertex at full quality, adding waves does add computation. A few components should be manageable, but the result should be profiled in-game.
* Change ship's engine effects to match movie -low priority
* Fix big wave rendering distance/sudden appear/dissapear -high priority;
  * Wave popping: The current wave center wraps every 90 seconds. A smooth fix is to make it a repeating train of waves, spaced so a new pulse takes over as the previous one leaves—without a visible jump. The calculation can still use server time, so clients stay in sync.
  * Visible ocean edge: Increase GRID_SETTINGS.Width and Length in Settings.luau. They’re currently 40 vertices each, with 48 studs between vertices, so the main wave mesh is about 1,872 × 1,872 studs. The giant wave fades near that mesh’s edge, and the surrounding planes are flat. Widening the mesh moves that fade farther from the player.
  * For the giant wave, we can make a seamless repeating wave train driven by server time. That avoids the position jump at the loop while keeping the calculation lightweight and synchronized across clients.
  * For the visible ocean edge, the efficient fix is to extend the wave-shaped coverage around the player—using overlapping, camera-following mesh sections—rather than making one huge, dense mesh. The current surrounding planes are flat, which is why the fade at the main mesh’s edge can stand out.
 
Upcoming:
* Add tars
