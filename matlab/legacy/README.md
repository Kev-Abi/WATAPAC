# Superseded

`WATAPAC_3D_Simscape_Turbine_Builder.m` is the first draft, kept for
reference. **Do not run it** — it cannot compile, and the model it would
produce is not the one its comments describe (blades unconnected and never
angled, no rigid transforms, both turbines at the origin, unconnected Goto
blocks that fail on update before the save is reached).

The replacement is `../watapac_build_turbine_3d.m`. The full list of what
was wrong and how it was addressed is in [`../README.md`](../README.md).
