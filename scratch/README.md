# scratch/

This folder is gitignored on purpose. It holds your personal, tenancy-specific
scripts (real OCIDs, subnet IDs, image IDs) that you don't want committed, but
that you're using as reference/source material while building out the
public, parameterized versions of the same ideas under `scripts/`.

Put your actual `oci_e2_retry.sh`, `oci_a1_retry.sh`, `oci_e2_launch_all.sh`,
`oci_a1_launch_all.sh`, and their systemd units here if you want them
version-controlled *locally* (e.g. via a private git remote, or just as
backup) without them ever landing in the public alpine-fleet history.

Ideas worth lifting from these into the public scripts:
- Parallel per-AD retry with exponential backoff + jitter, so you don't
  hammer a single AD and don't get rate-limited across ADs simultaneously.
- A shared flag file (e.g. /tmp/<goal>_met) that lets sibling retry loops
  notice a win and stop themselves — cheap coordination without a lock
  service.
- `wait "${PIDS[@]}"` in the launcher so the whole thing blocks cleanly
  under `Type=simple` in systemd, exiting 0 only on real success.
- Checking the *current* count against a goal before each attempt, not
  just once at start — lets independent processes converge correctly
  even if they're racing each other.
