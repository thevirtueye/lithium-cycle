# lithium-cycle

**Monthly full-charge automation for Linux laptops.**

Lithium-ion batteries last longer when kept around 80 %, but they should
still be cycled to 100 % occasionally so that the firmware fuel gauge stays
calibrated. This project keeps your charge threshold at 80 % every day,
except for one day per month (the 1st by default), when it raises the
threshold to 100 %, lets the battery fill at your own pace, and then drops
back to 80 % the moment a full charge is complete.

No timers tied to specific times of day. No polling loops. The system reacts
to real events: AC plug/unplug, battery capacity change, daily rollover at
midnight, and system boot.

---

## Quick start

```bash
git clone https://github.com/thevirtueye/lithium-cycle
cd lithium-cycle
./tests/test-dryrun.sh         # sanity-check the logic (no install yet)
sudo ./install.sh              # install
sudo lithium-cycle status     # see the current state
```

That's it. From now on the system runs itself.

---

## Will this work on my laptop?

Two requirements: your **operating system** must be a modern Linux distro,
and your **laptop firmware** must expose a writable charge threshold to the
kernel.

### Operating system

Any Linux distribution that uses **systemd** as init and **udev** as the
device manager. That covers practically every mainstream distro:

| Distro                        | Status         |
| ----------------------------- | -------------- |
| Fedora (any recent)           | Tested         |
| Ubuntu / Kubuntu / Lubuntu    | Should work \* |
| Debian (recent)               | Should work \* |
| Arch / Manjaro / EndeavourOS  | Should work \* |
| openSUSE Tumbleweed / Leap    | Should work \* |
| Pop!_OS, Linux Mint, Zorin    | Should work \* |
| **Devuan, Artix, Void, MX**   | Not supported  |
| **Alpine Linux**              | Not supported  |

\* Should work means: it uses the same systemd + udev + bash stack as
Fedora, but the maintainer hasn't personally tested it. Feedback welcome
via GitHub Issues.

The four "Not supported" rows above either don't use systemd by default
or use musl/busybox in ways that break the install scripts.

### Hardware

Your laptop must expose this file:

```
/sys/class/power_supply/BAT0/charge_control_end_threshold
```

Quick check:

```bash
ls /sys/class/power_supply/BAT*/charge_control_end_threshold
```

If the file exists, you're good. If it doesn't, the installer will print a
list of things to try (loading the right kernel module for your laptop
brand). Rough vendor compatibility:

| Vendor             | Support                                        |
| ------------------ | ---------------------------------------------- |
| Lenovo ThinkPad    | Yes (`thinkpad_acpi`)                          |
| Lenovo IdeaPad     | Yes on most recent models (`ideapad_laptop`)   |
| ASUS ROG / ZenBook | Yes on recent models (`asus_wmi`)              |
| Huawei MateBook    | Yes (`huawei_wmi`)                             |
| Framework          | Yes (native kernel support)                    |
| System76           | Generally yes                                  |
| Dell               | Hit-or-miss, depends on model                  |
| HP                 | Almost never (firmware doesn't expose it)      |
| Acer / MSI         | Case by case                                   |
| Apple Mac          | No                                             |

Single-battery laptops only. Dual-battery setups (some ThinkPad business
models) work for whichever battery you configure as `BATTERY=BAT0` (or
`BAT1`); the other is left at firmware defaults.

---

## How it works

Three different things can trigger the script. They all converge on the
same idempotent function:

1. **udev** fires on every `power_supply` event (cable plugged/unplugged,
   capacity tick).
2. A **systemd timer** fires every day at 00:01 to handle the date
   rolling over to a new month. `Persistent=true` covers the case where
   the laptop was off at that exact minute — the missed run is caught up
   at the next boot.
3. The **service unit** runs once at boot, so the system is always in a
   correct state regardless of when you turn the laptop on.

Each trigger calls the same logic:

- Has this month already been marked as "full charge done"?
  → Set threshold to **80 %**. Done.
- Otherwise, if we're on or past day 1 of the current month:
  - If capacity is already ≥ 100 % → mark this month as done, drop
    threshold back to **80 %**.
  - Else → set threshold to **100 %** and let the battery fill.

State is persisted in `/var/lib/lithium-cycle/state` as
`last_full_charge=YYYY-MM`. The full-charge window stays open across days
until 100 % is actually reached — so if you forget to plug in on the 1st,
the system picks up on the 2nd, 3rd, etc.

---

## Configuration

Edit `/etc/lithium-cycle/lithium-cycle.conf`:

| Variable              | Default | Meaning                                                   |
| --------------------- | ------- | --------------------------------------------------------- |
| `BATTERY`             | `BAT0`  | Battery device under `/sys/class/power_supply/`           |
| `NORMAL_THRESHOLD`    | `80`    | Daily charge cap                                          |
| `FULL_THRESHOLD`      | `100`   | Cap during the monthly full-charge window                 |
| `FULL_CHARGE_DAY`     | `1`     | Day of the month to open the window (1–28)                |
| `COMPLETION_CAPACITY` | `100`   | Capacity at which the full charge counts as done (1–100)  |

After editing, apply changes with:

```bash
sudo systemctl restart lithium-cycle.service
```

The config file is **never overwritten** by reinstalling — your edits
survive `sudo ./install.sh` being run again.

---

## Inspecting the system

```bash
sudo lithium-cycle status         # one-shot, human-readable summary
journalctl -t lithium-cycle       # all script log lines
journalctl -t lithium-cycle -f    # follow logs live
systemctl list-timers lithium-cycle.timer
cat /sys/class/power_supply/BAT0/charge_control_end_threshold
cat /var/lib/lithium-cycle/state
```

You can also force an evaluation manually at any time:

```bash
sudo systemctl start lithium-cycle.service
```

---

## Testing

Two test layers ship with the project.

**Logic test (no installation required).** Runs the script against a fake
`/sys` sandbox and replays 27 scenarios in a couple of seconds:

```bash
./tests/test-dryrun.sh
./tests/test-dryrun.sh -v          # verbose
```

**Live integration checklist.** Validates udev, systemd, real `/sys`
writes, state persistence, and reboot behaviour on your actual laptop
after `sudo ./install.sh`. See `tests/LIVE-TESTING.md`.

---

## Uninstall

```bash
sudo ./uninstall.sh
```

The uninstaller asks before removing `/etc/lithium-cycle` (config) and
`/var/lib/lithium-cycle` (state). The kernel keeps whatever charge
threshold value was last written until reboot or another tool changes it,
so if you want to reset to "always 100 %" or "always 80 %", do:

```bash
echo 100 | sudo tee /sys/class/power_supply/BAT0/charge_control_end_threshold
# or
echo 80  | sudo tee /sys/class/power_supply/BAT0/charge_control_end_threshold
```

---

## Troubleshooting

**`charge_control_end_threshold` doesn't exist.**
The installer prints diagnostic suggestions. The most common fix is
loading the right kernel module: `sudo modprobe thinkpad_acpi` for
ThinkPads, `asus_wmi` for ASUS, `ideapad_laptop` for IdeaPads, etc. If
none work, your firmware probably doesn't expose this API.

**Threshold doesn't change after I plug in the cable.**
Check the udev rule is loaded: `sudo udevadm control --reload-rules`,
then trigger manually with
`sudo udevadm trigger --subsystem-match=power_supply --action=change`
and inspect `journalctl -t lithium-cycle`.

**`lithium-cycle status` says timer is inactive.**
Re-enable: `sudo systemctl enable --now lithium-cycle.timer`.

**KDE Plasma's "Charge limit" panel shows a different value.**
Plasma stores its own preference and does not always reflect the live
`/sys` value. The live value (what the firmware actually enforces) is
the authoritative one. Plasma typically does not re-apply its preference
in real time, so this mismatch is cosmetic.

**Logs don't persist across reboots.**
Some distros set the journal to volatile by default. Make it persistent:
`sudo mkdir -p /var/log/journal && sudo systemctl restart systemd-journald`.

**"Read-only file system" or permission errors writing to `/sys`.**
The systemd unit has aggressive sandboxing. The `ReadWritePaths=` line
in `/etc/systemd/system/lithium-cycle.service` must include
`/sys/class/power_supply`.

---

## Security notes

The service runs as **root**, because writing to
`/sys/class/power_supply/.../charge_control_end_threshold` requires it.
The systemd unit applies aggressive sandboxing:

- `ProtectSystem=strict` with explicit `ReadWritePaths`
- `PrivateNetwork=true`, `IPAddressDeny=any` — no network at all
- `CapabilityBoundingSet=` empty, `NoNewPrivileges=true`
- `MemoryDenyWriteExecute=true`
- `SystemCallFilter=@system-service` (no privileged syscalls)

The script itself validates every config value before touching `/sys`,
uses atomic writes for the state file, and never interpolates user input
into paths.

You can audit the sandbox profile with:

```bash
systemd-analyze security lithium-cycle.service
```

---

## Contributing

Issues and pull requests welcome. Please:

- Run `./tests/test-dryrun.sh` and `shellcheck src/*.sh install.sh
  uninstall.sh tests/*.sh` before submitting.
- For hardware compatibility reports, include `uname -r`, the laptop
  vendor/model, and the output of `ls /sys/class/power_supply/`.

See `CONTRIBUTING.md` for details.

---

## License

This project is released under the **MIT License**.  
Free to use for educational and research purposes. Please credit the author where applicable.


## Author

Created by **Alberto Cirillo** — 2026
