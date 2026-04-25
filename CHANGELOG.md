# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 25-04-26

### Added
- Initial release.
- Monthly full-charge automation driven by udev events, a daily systemd
  timer, and a one-shot service unit at boot.
- `lithium-cycle status` sub-command for read-only inspection.
- Configurable battery device, normal/full thresholds, full-charge day,
  and completion capacity via `/etc/lithium-cycle/lithium-cycle.conf`.
- Atomic state file at `/var/lib/lithium-cycle/state`.
- Hardened systemd unit: `ProtectSystem=strict`, no network, no
  capabilities, `NoNewPrivileges`, restrictive syscall filter.
- Dry-run test harness (`tests/test-dryrun.sh`) with 27 scenarios.
- Live integration checklist (`tests/LIVE-TESTING.md`).
- Pre-flight diagnostics in the installer when the laptop's firmware
  doesn't expose a writable charge threshold.
