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
| **Digital twin** | |
| `watapac_twin_params.m` | Every constant, each tagged with where it came from. |
| `watapac_trial_data.m` | The five measured trials, Appendix G. |
| `watapac_plant.m` | Six-stage physics, plain MATLAB — the reference. |
| `watapac_simulate.m` | The same, over time (LED hold, state of charge). |
| `watapac_validate.m` | Model against measurement. **Start here.** |
| `watapac_build_twin.m` | Builds `watapac_twin.slx` in Simulink. |
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

## The digital twin

```matlab
cd matlab
watapac_validate        % model vs the five measured trials — no Simulink needed
watapac_build_twin      % then the Simulink model
```

`watapac_validate` runs without Simulink and without a toolbox, because the
physics lives in `watapac_plant` as a plain function. The Simulink model
mirrors it stage for stage; if the two ever disagree, the function is right.

### The six stages

| | Stage | What it models |
|---|---|---|
| 1 | Rainfall → runoff | Rational method against the **test** catchment, back-calculated from the measured flow |
| 2 | Filtration | Per-type capture for leaves and plastic separately, plus mesh blockage |
| 3 | Cascade turbines | T1 and T2 as separate runners sharing the head, not one lumped turbine |
| 4 | Power conversion | Alternator → 3-phase rectifier (with its diode drop and cut-in) → buck converter |
| 5 | Battery and load | LED strip, Raspberry Pi, Arduino, sensors; SOC limited inside the integrator |
| 6 | Sensor emulation | What the MAX471 and the firmware would actually *report*, not just the true value |

Stage 6 is the unusual one and the reason the twin is worth having. A model
that predicts only the true current cannot explain why the prototype
reported 0.23 A. One that also models the 1 V/A sensor, the 10-bit ADC and
the firmware's 25 mA deadband predicts the **reading** — and the reading it
predicts is `0.000 A`.

### What the twin found

Run `watapac_validate` for the full output. In summary:

| | |
|---|---|
| Flow and filtration | Model reproduces measurement (0.2840 vs 0.284 L/min; 97.36 vs 97.4 %) |
| Energy output | Model and measurement differ by **134×** |
| Charge path | **Not viable** — a buck converter cannot charge 12.6 V from a 5.8 V bus |
| System balance | Load exceeds generation by ~3900× |

**The energy gap.** At 0.284 L/min through 0.45 m of head the water carries
20.9 mW. Tables 5–7 report 2.80 W. To justify that at the measured flow you
would need 60 m of head; the prototype is 0.589 m tall. The ratio is 132–136×
in *every* trial across a 41 % spread in flow, which is the signature of a
calibration scale error rather than noise. Predicted current is 0.70 mA —
0.14 of one ADC count, and below the firmware's own deadband.

**The charge path.** Independent of the above. The XL4015 in Appendix A is a
step-down converter; it needs an input above both its 8 V minimum and the
pack voltage plus dropout, so 14.1 V for a full 3S LiPo. The turbines give
~6 V in parallel, ~12 V in series. Neither is enough. This needs a boost
stage.

Neither finding is hidden behind a fitted constant. The twin computes the
physics and prints the disagreement, which is what a twin is for.

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

## Bugs carried over from Appendix D

The manuscript's `watapac_digital_twin.m` is the starting point for
`watapac_build_twin.m`. These were fixed on the way:

- **Debris load 250 g**, ten times the 25 g the Methodology specifies
- **`StopTime` 600 s**, where a trial is 1000 s
- **The LED load was never connected to the battery.** `LedWatts` was
  computed and left dangling, so the pack could only ever charge
- **`EnergyKWh` was computed and discarded** — the paper's headline energy
  result was never logged
- **Three conflicting battery models** across the firmware (11.8–12.7 V),
  the Pi server (9.9–11.1 V) and the twin (11.8–12.7 V, 7.0 Ah), against a
  pack listed in Appendix A as 11.1 V 5000 mAh. The firmware range covers
  only the top ~20 % of a 3S pack, so the dashboard reads 0 % for most of
  the usable charge
- **No rectifier.** Omitting the 1.4 V bridge drop puts the bus voltage too
  high and makes output linear in flow down to zero, with no cut-in
- **The Pi and Arduino were absent from the energy balance** — together
  about 1000× the modelled generation
- **A 1200 m² street catchment with Froude scaling applied to it**, then
  compared against a bench measurement. That mixes a full-scale prediction
  with a model-scale result; the two are kept apart here
- **The blockage model predicted ~50 % flow loss at 25 g**, which Table 4
  explicitly refutes (t(8) = −0.339, p = .743, and WATAPAC passed slightly
  *more* water than the conventional model)

## Still to build

- Couple the twin to the logged telemetry, so it runs against live data
  rather than the five recorded trials
- Re-measure the electrical output with an instrument that can resolve
  milliamps, and recalibrate `kv_ac_per_lpm` against it
- Export geometry for the web dashboard's 3D panel
