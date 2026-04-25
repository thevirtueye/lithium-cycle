# Contributing

Thanks for your interest in improving lithium-cycle.

## Bug reports and hardware compatibility

For **bugs**, please open an Issue with:

- Distribution and version (`cat /etc/os-release | head -3`)
- Kernel version (`uname -r`)
- Laptop vendor and model
- The exact command that triggered the bug
- Relevant log output (`journalctl -t lithium-cycle --since "1 hour ago"`)
- Output of `sudo lithium-cycle status` if installed

For **hardware compatibility reports** (works / doesn't work on your
laptop), please include:

- Vendor and model
- `uname -r`
- Output of `ls /sys/class/power_supply/`
- Whether `charge_control_end_threshold` is present, and which kernel
  module(s) you had to load (if any) for it to appear

These reports help build a real-world compatibility matrix.

## Pull requests

Before submitting a PR:

1. **Run the dry-run test suite.** It must pass.

   ```bash
   ./tests/test-dryrun.sh
   ```

2. **Run shellcheck.** It must be silent.

   ```bash
   shellcheck src/*.sh install.sh uninstall.sh tests/*.sh
   ```

3. **If you add a new behaviour or fix a bug, add a test case** to
   `tests/test-dryrun.sh` that fails before your change and passes
   after.

4. **Verify the systemd units still parse.**

   ```bash
   systemd-analyze verify systemd/lithium-cycle.service \
                          systemd/lithium-cycle.timer
   ```

5. **Update `CHANGELOG.md`** under an `[Unreleased]` section.

## Style

- Bash with `set -euo pipefail`.
- 4-space indentation.
- Comments explain *why*, not *what*.
- Validate all config values before touching `/sys`. Never interpolate
  user input into paths.
- Prefer atomic file writes (`mktemp` + `mv -f`) for state.
- Keep the systemd unit's sandbox tight: any new `ReadWritePaths` or
  capability addition must be justified in the PR description.

## Scope

This project does **one thing**: monthly full-charge automation for
laptop batteries. PRs that expand scope (broader power management,
fan control, CPU governors, etc.) will likely be redirected to other
projects like `tlp` or `auto-cpufreq`. That's not a value judgement,
just keeping things small.
