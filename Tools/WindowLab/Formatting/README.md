# WindowLab replay output

Run `window-lab <mode> <scenario>` from the repository root. Use the filename without its `.json` extension as the scenario argument. The CLI reads fixtures from `Tools/WindowLab/Scenarios`.

- `replay` prints observations, identity decisions, and whether the tracked identity stayed stable. Observation timestamps reflect the time of the run.
- `placementReplay` prints each lifecycle event and the resulting window order.
- `transitionReplay` prints each accepted window identity and lifecycle status. Observations rejected by the pipeline appear with status `discarded`.

Each bundled fixture declares the mode used by the CLI validation script in its top-level `mode` field. For an existing custom fixture without that field, pass the appropriate mode on the command line.
