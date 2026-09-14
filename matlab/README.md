# WATAPAC — MATLAB / Simscape Multibody

3-D geometry model of the cascade turbine, for Mechanics Explorer.

This models **shape and kinematics only**. Hydraulic torque, the generator,
and the measured sensor data are not coupled to it yet — that is the step
that turns this into a digital twin, and pretending otherwise would make the
model look more finished than it is.

## Files

| File | What it does |
|---|---|
| `watapac_check_env.m` | Reports what your MATLAB release calls the blocks and parameters. **Run this first.** |
| `watapac_params.m` | Every dimension, in one place. Validates itself. |
| `watapac_build_turbine_3d.m` | Builds and saves `WATAPAC_3D_Simscape_Turbine.slx`. |
| `watapac_load_log.m` | Reads logged telemetry from the Pi into a table. |
| `legacy/` | The first draft builder, kept for reference. See "Why it was rewritten". |

## Running it

```matlab
cd matlab
watapac_check_env          % 1. what does this install actually have?
watapac_build_turbine_3d   % 2. build it
```

Then **Simulation → Run**, and open **Mechanics Explorer**.

Options:

```matlab
watapac_build_turbine_3d('Open', false, 'Save', false)   % dry run
watapac_build_turbine_3d('Params', watapac_params('n_blades', 12))
```

## Reading the logged data

The Pi writes a daily CSV and serves it back at `/api/history`. Either source
gives the same table:

```matlab
T = watapac_load_log();                                    % ../pi/logs
T = watapac_load_log('Hours', 72);
T = watapac_load_log('Url', 'http://192.168.1.42:5000');   % a live Pi

plot(T.timestamp, T.flowRate); ylabel('L/min'); grid on
```

Missing measurements come back as `NaN`, never `0`: the server writes an empty
cell for a sensor it did not hear from, so an unplugged sensor cannot be
averaged in as a real zero. Times are UTC `datetime`.

This is the link that makes model-against-measurement comparison possible.
The comparison itself is not written yet.

## If the build fails

It is written to fail loudly and usefully rather than produce a wrong model.
An error will name the block or parameter it could not resolve and list what
the block actually exposes. Send that message together with the full
`watapac_check_env` output and the exact spelling can be pinned down.

On success the builder prints a **parameter names this release used** summary.
That list is worth keeping: it is what to hardcode once the target release is
settled, and the first thing to compare against if a later rebuild misbehaves.

## Why the parameter names are resolved at runtime

Simscape Multibody has moved its blocks between sublibraries and renamed
dialog parameters across releases. Rather than hardcode one release's
spelling, every `set_param` goes through a resolver that tries the known
names, and reports what the block really has when none of them match.
Structural settings (shape, dimensions, transforms) stop the build if they
cannot be applied; cosmetic ones (colour) warn and carry on.

## Why the first draft was rewritten

`legacy/WATAPAC_3D_Simscape_Turbine_Builder.m` cannot produce the model its
comments describe. The problems are structural, not typos:

- **No Rigid Transform blocks.** In Simscape Multibody a Solid sits exactly
  at the frame it is connected to. Without transforms the hub and shaft are
  coincident, and both turbines sit on top of each other at the origin.
- **`Position` is canvas coordinates.** `[500+(k-1)*5 ...]` moves blocks
  around the *diagram*. It has no effect on where anything is in space.
- **`ang` is computed and never used** — the blades are never placed at an
  angle.
- **The 16 blade Solids are never connected** to anything.
- **Mechanism Configuration is never wired**, so the model cannot compile.
- **The Goto blocks have no input**, which fails on update before
  `save_system` is ever reached. They are also described as annotations,
  which they are not; they route signals, and there are no signals here.

The rewrite fixes all of these. Each blade is placed by three single-purpose
transforms — rotate about the shaft axis, translate out past the hub, twist
for pitch — rather than one combined transform, because a combined one would
depend on whether Simscape applies its translation before or after its
rotation. Split apart, the result is the same either way.

## Known-unverified assumptions

These are guesses, flagged so they are not mistaken for measurements:

- **`stage_offset_axis = 'X'`** — stages side by side along the channel,
  each on its own vertical shaft (a cross-flow cascade). Set it to `'Z'` for
  stages stacked on one common axis (an axial turbine). This is the single
  biggest architectural assumption in the model.
- **Blade orientation** — X radial, Y tangential (thickness), Z along the
  shaft (width). That makes a flat paddle facing the flow at zero pitch.
- **All dimensions** are carried over from the first draft and are not
  measured from the prototype.
- **Blades nearly touch at the defaults.** 8 blades of 35 mm width around a
  45 mm hub leaves 35.3 mm of arc each — about 0.3 mm of clearance.
  `watapac_params` warns as soon as any change tips that negative.

## Still to build

- Couple hydraulic torque and the generator, so the shafts are driven
- Feed logged sensor data in, to compare model against measurement
- Export geometry for the web dashboard's 3D panel
