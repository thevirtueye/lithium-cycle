# Live test checklist (real laptop)

This is the manual procedure to validate the full system on your real Fedora
installation, after `sudo ./install.sh`. The dry-run test suite
(`tests/test-dryrun.sh`) already validates the script's logic; this checklist
validates the **integration**: that udev fires the service, that systemd's
sandboxing does not break anything, that the state file persists, that the
real `/sys` writes work.

Run each section in order. Each section is self-contained and includes the
exact commands to copy-paste, the expected output, and how to recover.

> **Useful aliases (paste in your shell once)**
>
> ```
> alias cm-status='systemctl status lithium-cycle.service lithium-cycle.timer'
> alias cm-log='journalctl -t lithium-cycle --since "1 hour ago"'
> alias cm-thr='cat /sys/class/power_supply/BAT0/charge_control_end_threshold'
> alias cm-cap='cat /sys/class/power_supply/BAT0/capacity'
> alias cm-state='cat /var/lib/lithium-cycle/state 2>/dev/null || echo "(no state)"'
> alias cm-show='echo "thr=$(cm-thr) cap=$(cm-cap) state=$(cm-state)"'
> alias cm-run='sudo systemctl start lithium-cycle.service && sleep 1 && cm-show'
> ```

---

## 0. Pre-flight (no installation yet)

Verify the hardware exposes a writable threshold:

```bash
ls -l /sys/class/power_supply/BAT0/charge_control_end_threshold
cat /sys/class/power_supply/BAT0/charge_control_end_threshold
```

You should see the file exists and the current value (probably `80` since you
keep it there). Note this number — at the end of testing you'll restore it.

Run the dry-run suite to confirm the logic is sound:

```bash
cd lithium-cycle
./tests/test-dryrun.sh
```

Expected: `All scenarios passed.` Do not proceed if anything fails.

---

## 1. Installation

```bash
sudo ./install.sh
```

Expected output ends with `Done. Check status with:`. No errors.

**Verify:**

```bash
cm-status
cm-thr        # should still be 80 (today is not the 1st)
cm-state      # should NOT exist yet (no full charge ever recorded)
```

The timer must be `active (waiting)`. The service must be `inactive (dead)`
with `status=0/SUCCESS` (it ran once, succeeded, exited — that's correct
for `Type=oneshot`).

---

## 2. udev trigger test (cable plug/unplug)

This is the critical one — it proves the udev rule actually fires the service
when you connect or disconnect the charger.

```bash
# Watch live
journalctl -t lithium-cycle -f
```

In another terminal, **physically unplug the charger**, wait 2 seconds,
**plug it back in**. You should see one or two log lines per event. If today
is not the 1st of the month and the threshold was already 80, the script
will exit silently without changing anything (idempotent — that's correct
behaviour). To prove the rule fires anyway, add a temporary verbose line:

```bash
# Force a visible log entry to confirm udev triggers
sudo journalctl --rotate
sudo journalctl --vacuum-time=1s

# Trigger by hand and confirm:
sudo udevadm trigger --subsystem-match=power_supply --action=change
journalctl -t lithium-cycle --since "30 seconds ago"
```

Expected: at least one journal entry showing the script ran. If you see
nothing, the udev rule is not loading. Debug with:

```bash
sudo udevadm test $(udevadm info -q path -n /sys/class/power_supply/BAT0) 2>&1 | grep -i charge
```

Press `Ctrl-C` on the `journalctl -f` watcher when done.

---

## 3. Manual evaluation works

```bash
sudo systemctl start lithium-cycle.service
echo "exit=$?"           # must be 0
cm-show
```

Expected: today is not the 1st, no state file, threshold stays at 80.

---

## 4. Simulate "today is the 1st of the month"

This is where it gets interesting. We use the config knob `FULL_CHARGE_DAY`
to lie to the script about which day matters. We tell it "today is the
target day" by setting `FULL_CHARGE_DAY` to today's day number.

```bash
TODAY=$(date +%-d)
echo "Today is day $TODAY"

# Backup current config
sudo cp /etc/lithium-cycle/lithium-cycle.conf{,.bak}

# Set today as the target day
sudo sed -i "s/^FULL_CHARGE_DAY=.*/FULL_CHARGE_DAY=${TODAY}/" \
    /etc/lithium-cycle/lithium-cycle.conf

# Trigger
cm-run
```

**Expected:**
- `thr=100` (threshold raised because today is the "target day")
- `cap=` whatever your battery is at right now
- `state=(no state)` (full charge not yet completed)
- `journalctl -t lithium-cycle --since "1 minute ago"` shows
  `Threshold changed: 80 -> 100`

Let the battery charge to 100% (or, to skip waiting, see the next section
which fakes the capacity). When it reaches 100%, udev will fire automatically
and you should see:
- `thr=80`
- `state=last_full_charge=YYYY-MM` (current month)
- log line: `Full charge completed for YYYY-MM (capacity=100%)`

---

## 5. Simulate completion without waiting for charging

If you do not want to actually charge to 100% during the test, you can fake
it: stop the service, manually write a state, and re-run.

```bash
# Mark this month as "completed" without actually charging
MONTH=$(date +%Y-%m)
echo "last_full_charge=${MONTH}" | sudo tee /var/lib/lithium-cycle/state

cm-run
```

**Expected:**
- `thr=80` (the script saw the month is done and reverted)
- `state=last_full_charge=YYYY-MM`
- No log line about threshold change if it was already 80, OR a
  `Threshold changed: 100 -> 80` line if you ran section 4 just before.

---

## 6. Simulate "I plug in the cable on day 1, charge starts"

With section 4 still in effect (today set as target day) and section 5 not
yet run (no state):

```bash
# Reset to "no completion yet"
sudo rm -f /var/lib/lithium-cycle/state
cm-run
```

**Expected:** `thr=100`. Now physically unplug the charger and plug it back
in. Each event triggers the udev rule, which calls the script, which sees
"month not done, target day, capacity < 100" → keeps `thr=100`. No state
file is created. Verify:

```bash
cm-show
journalctl -t lithium-cycle --since "1 minute ago"
```

This is the scenario from your original message: leave home, come back,
plug in again — the system continues toward 100%.

---

## 7. Simulate "I unplug after reaching 100%"

```bash
# Pretend month is done
MONTH=$(date +%Y-%m)
echo "last_full_charge=${MONTH}" | sudo tee /var/lib/lithium-cycle/state

cm-run
```

**Expected:** `thr=80`. Now unplug and plug back in. udev fires the script,
the script sees "month done", keeps `thr=80`. Even though
`FULL_CHARGE_DAY=$TODAY` is still set, the state file overrides it. No more
charging beyond 80% until next month.

---

## 8. Simulate the daily timer rollover

The timer fires at 00:01 every day. We can trigger it on demand:

```bash
sudo systemctl start lithium-cycle.service
journalctl -t lithium-cycle --since "30 seconds ago"
systemctl list-timers lithium-cycle.timer
```

The `list-timers` output should show the next trigger at tomorrow 00:01.

To verify the `Persistent=true` behaviour (catch-up after the laptop was off),
the cleanest test is: shut down before midnight, boot after. But you can also
inspect the systemd state file:

```bash
sudo ls -la /var/lib/systemd/timers/ | grep charge
```

If you see a stamp file there, persistence is enabled correctly.

---

## 9. Reboot test

This validates that the service runs at boot too.

```bash
# Note the current state
cm-show
sudo reboot
```

After reboot:

```bash
cm-status
journalctl -t lithium-cycle --boot
cm-show
```

The service should have run during boot, exited cleanly, and the threshold
should match what the logic dictates given today's date and the saved state.

---

## 10. Failure injection: what if /sys writes fail?

The systemd unit has aggressive sandboxing. Confirm the script can still
write to `/sys`:

```bash
sudo systemctl start lithium-cycle.service
echo "exit=$?"
journalctl -t lithium-cycle --since "30 seconds ago" | grep -i error
```

No errors expected. If you see `Permission denied` or `Read-only file system`,
the sandbox is too tight and `ReadWritePaths=/sys/class/power_supply` in
`lithium-cycle.service` needs to be checked.

Also verify with `systemd-analyze`:

```bash
systemd-analyze security lithium-cycle.service
```

This gives a security score (lower = more locked down). It should show
roughly 1.5–2.5. The `ReadWritePaths=` exposure on `/sys/class/power_supply`
is intentional and not a real concern (it's the only way to write the
threshold).

---

## 11. Cleanup after testing

Restore the real config and clean state:

```bash
sudo mv /etc/lithium-cycle/lithium-cycle.conf.bak \
        /etc/lithium-cycle/lithium-cycle.conf

# Delete test state so next month works normally
sudo rm -f /var/lib/lithium-cycle/state

# Run once to apply real config
sudo systemctl start lithium-cycle.service
cm-show
```

`cm-thr` should be back to `80` (today is not actually the 1st).
`cm-state` should report `(no state)` until the next real 1st of the month.

---

## 12. Final check before pushing to GitHub

```bash
cd lithium-cycle
./tests/test-dryrun.sh                # 27/27 passed
shellcheck src/*.sh install.sh uninstall.sh tests/*.sh   # silent
bash -n src/*.sh install.sh uninstall.sh tests/*.sh      # silent
systemd-analyze verify systemd/lithium-cycle.service systemd/lithium-cycle.timer
```

If all four are clean, you're ready to push.

---

## Recovery commands (if anything goes wrong)

```bash
# Forget about everything and reset to "always 100%"
sudo ./uninstall.sh
echo 100 | sudo tee /sys/class/power_supply/BAT0/charge_control_end_threshold

# Or reset to "always 80%"
sudo ./uninstall.sh
echo 80 | sudo tee /sys/class/power_supply/BAT0/charge_control_end_threshold
```
