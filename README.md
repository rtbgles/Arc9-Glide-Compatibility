# Glide x ARC9 – Weapons in Vehicles

A Garry's Mod addon that lets players draw and fire their **ARC9** weapons while
seated in a **Glide** vehicle.

**Double-tap C** while seated to enter **weapon mode**. You can change the key
with `cl_glide_arc9_toggle_key`.
Double-tap again to holster.

## Installing / updating

Copy the whole repository folder into `garrysmod/addons/` (for example as
`garrysmod/addons/arc9glide/`). When updating, **delete the old folder first**
and copy the new one in, so no files are missing or left over. On map load the
console prints `[Glide x ARC9] Loaded version ...` for the client and server.

## Requirements

- [Glide // Styled's Vehicle Base](https://github.com/StyledStrike/gmod-glide)
- [ARC9 Weapon Base](https://github.com/HaodongMo/ARC-9) (plus some ARC9 weapons)

Both are loaded lazily, so addon load order does not matter.

## What happens in weapon mode

- Your last-used ARC9 weapon is drawn. If you don't have one, it falls back to
  the weapon you held before getting in, then to any ARC9 weapon you own.
- Glide inputs that use the same keys as your gun are ignored while in weapon
  mode (by default: vehicle `attack`, `attack_alt`, `switch_weapon` and `horn`).
  You can still drive.
- Scroll wheel and number keys switch between your allowed weapons.
- Your weapon aims and shoots wherever Glide's camera is looking, in first
  and third person.
- Bullets ignore the vehicle you're sitting in, and ARC9's "too close to a
  wall" check is off, so you can shoot from inside enclosed cars.
- Weapons fired by anyone riding in a vehicle never damage that vehicle,
  including grenades and rockets from their weapons. Shots from outside
  still damage it.
- The camera switches to first person so iron sights and scopes line up. ADS
  zoom, recoil kick and scoped mouse sensitivity come from the weapon. Your
  previous camera view comes back when you holster.
- In third person, every seat (including car drivers) uses a seated pose that
  holds the weapon. Every frame, each player's game measures where the drawn gun
  actually points, twists the spine (left/right) and raises or lowers the arms
  (up/down) until it's on your aim, so the gun follows your crosshair on any
  player model, seated or leaning out. The spine only twists, never folds, and
  only so far; past that the gun stays at the edge.
- Where you can aim and fire is limited to what your body can reach: up to
  `glide_arc9_aim_arc` left/right (110° by default) and about 50° up / 40° down
  when seated. Outside that the gun stops, firing is blocked and the HUD shows
  "CAN'T AIM THERE".
- If something else takes over your view (looking through a GMod camera, for
  example), you keep aiming where you last aimed, so you can film yourself and
  see what other players see.
- When you get out of the vehicle you keep holding the weapon you were using.

## Leaning out of the window

As a **passenger in weapon mode**, double-tap the move key toward your window to
lean out of it, and again to lean back in: **A** in a left-side seat (e.g. the
rear left), **D** in a right-side seat (e.g. the front passenger).

- You're raised up in your seat and lean far (45°) out of the window, tilting
  around your hips, so your hips and legs stay inside the vehicle. Your upper
  body turns to aim. You really are out of the window, so where you shoot from
  and where you can be hit match what other players see.
- While leaning you can aim forward and back on your side of the car (up to
  `glide_arc9_lean_aim_back`, 150° from forward), a little across the front,
  and about 70° up / 60° down. You can't fire into your own vehicle (down
  through the roof or bonnet).
- You pull back in automatically when the window gets blocked (walls, other
  cars), and when you holster, get out or die.
- Leaning players take explosion damage (Glide normally blocks it for people in
  vehicles).
- Not available to drivers, on motorcycles, or on seats that don't face forward.

## Server convars

| Convar | Default | Description |
| --- | --- | --- |
| `glide_arc9_enabled` | `1` | Turns the feature on or off. Turning it off kicks everyone out of weapon mode. |
| `glide_arc9_allow_driver` | `1` | Lets drivers/pilots (seat 1) use weapon mode. |
| `glide_arc9_allow_passengers` | `1` | Lets passengers use weapon mode. |
| `glide_arc9_arc9_only` | `1` | Only ARC9 weapons can be held in weapon mode. Set to `0` to allow any weapon. |
| `glide_arc9_protect_own_vehicle` | `1` | Weapons fired from inside a Glide vehicle don't damage that vehicle (body, wheels, turrets). Shots from outside still do. |
| `glide_arc9_debug` | `0` | Prints aim, bullet and vehicle angles to the console when firing in weapon mode. With `developer 1` it also draws each shot's path (red = server, blue = client) and Glide's aim point (green cross). Use this when reporting aim bugs. |
| `glide_arc9_aim_arc` | `110` | How far left/right of the seat's forward you can aim and fire. Past it the gun stops and firing is blocked, so bullets never leave where the gun isn't pointing. |
| `glide_arc9_lean_enabled` | `1` | Lets passengers in weapon mode lean out of their window. |
| `glide_arc9_lean_aim_back` | `150` | While leaning out, how far back (degrees from forward) you can aim and fire on your side. |
| `glide_arc9_blocked_actions` | `attack,attack_alt,switch_weapon,horn` | Comma-separated Glide actions that are ignored while in weapon mode. |

## Client convars / commands

| Convar | Default | Description |
| --- | --- | --- |
| `cl_glide_arc9_toggle_key` | `c` | Key to double-tap for weapon mode (a key name such as `c`, `g`, `mouse3`). |
| `cl_glide_arc9_doubletap` | `1` | Turns double-tap detection on or off. |
| `cl_glide_arc9_lean_doubletap` | `1` | Turns double-tap A / D (lean out) on or off. |
| `cl_glide_arc9_doubletap_window` | `0.3` | Max seconds between the two taps. |
| `cl_glide_arc9_firstperson` | `1` | Switch to first person while in weapon mode. |
| `cl_glide_arc9_weapon_view` | `1` | Lets the weapon adjust the camera (ADS zoom, recoil). |
| `cl_glide_arc9_hud` | `1` | Shows the "WEAPON MODE" indicator. |
| `glide_arc9_lean` | – | Console command to lean out / back in. Bindable, e.g. `bind x glide_arc9_lean`. |
| `glide_arc9_toggle` | – | Console command to toggle weapon mode. You can bind it to a key, e.g. `bind x glide_arc9_toggle`. |

## Hooks for developers

```lua
-- SERVER: return false to stop a player from entering weapon mode
hook.Add( "GlideArc9_CanEnterWeaponMode", "MyAddon", function( ply, vehicle, seatIndex ) end )

-- SERVER: called after weapon mode starts or ends
hook.Add( "GlideArc9_OnWeaponModeChanged", "MyAddon", function( ply, isEnabled ) end )

-- CLIENT: called when the local player's weapon mode changes
hook.Add( "GlideArc9_OnLocalWeaponModeChanged", "MyAddon", function( isEnabled ) end )

-- CLIENT: return false to hide the weapon mode indicator
hook.Add( "GlideArc9_CanDrawHUD", "MyAddon", function() end )
```

`GlideArc9.IsInWeaponMode( ply )` works on both realms.

## Known limitations

- While seated, C (the context menu key, and ARC9's customize/peek key) reacts
  0.3 seconds late: a first press is held back to see if a second one follows.
  Holding C still works, and ARC9 peeking while aiming is unaffected.
- If Glide's mouse steering is set to **Aim**, aiming your gun also steers the
  car. Set mouse steering to "Disabled" in Glide's settings if you'll be
  driving and shooting at the same time.
- Bullets pass through your own vehicle's windows and doors without
  breaking them.
- The scroll wheel also cycles the vehicle's own weapons for drivers of
  armed vehicles (Glide reads the scroll wheel directly).
- **Singleplayer:** shots have been seen going backwards in singleplayer
  (still being looked into). Multiplayer, including a local listen server,
  works.
- The spine turn that points the gun is drawn on each player's screen only.
  The server's hit boxes for a turned player's arms can be a little off from
  what others see (head and chest barely move).
- Bullets can hit other people riding in the same vehicle.
