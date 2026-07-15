# fan-noise-guard

A temperature-scaled fan speed watchdog for Dell PowerEdge R-family servers
(iDRAC7/iDRAC8-era) that are unbearably loud because of a third-party PCIe
GPU.

## The problem

If you've dropped a non-Dell-branded GPU (an NVIDIA compute/datacenter card,
for example) into a PowerEdge R-family server, you've probably noticed the
chassis fans jump to a very loud, mostly fixed high speed and stay there.

This isn't a fault — iDRAC manages cooling by reading device thermal sensors
over the backplane. It can't do that for a "not officially supported"
third-party card, so as a conservative safety fallback it stops trying to
respond to actual temperatures and just runs the fans loud and fixed
instead. This is especially relevant if the GPU is a passively-cooled
datacenter card (no fan of its own), since it depends entirely on chassis
airflow and Dell has no way to confirm that airflow is adequate for it.

## The fix

You can put iDRAC's fans into manual mode via IPMI and set a lower, quieter
fixed speed — but that also switches off iDRAC's own thermal response
*entirely*. Nothing will speed the fans back up if temperatures climb.

`fan-noise-guard` is the replacement thermal response: a small daemon that

- polls GPU temperature (`nvidia-smi`) and CPU package temperature
  (`lm-sensors`) on an interval,
- scales fan speed through configurable tiers as temperatures rise, with
  hysteresis so it doesn't chatter between two speeds at a tier boundary,
- and has hard failsafes: any failed/invalid/timed-out sensor read, or
  temperatures crossing a panic ceiling, immediately forces fans to 100%
  and hands control back to iDRAC's automatic mode — and stays there until
  the service is restarted, rather than silently retrying forever.

## Requirements

- A Dell PowerEdge R-family server with iDRAC7 or iDRAC8 (roughly the
  11th–13th generation range) — the raw IPMI OEM commands this uses
  (`0x30 0x30 ...`) are specific to that iDRAC generation. Other Dell
  generations or non-Dell BMCs will need different raw commands; check
  before relying on this.
- `ipmitool`, accessible via the local `/dev/ipmi0` device (root required).
- `nvidia-smi` for GPU temperature (adapt `read_gpu_temp` in the script if
  your GPU vendor's tooling differs, or if you don't have a GPU at all).
- `lm-sensors` (`sensors -u`) for CPU package temperature.
- `systemd`.

## Installation

```bash
sudo cp fan-noise-guard.sh /usr/local/sbin/fan-noise-guard.sh
sudo chmod 755 /usr/local/sbin/fan-noise-guard.sh
sudo cp fan-noise-guard.service /etc/systemd/system/fan-noise-guard.service
sudo systemctl daemon-reload
sudo systemctl enable --now fan-noise-guard.service
sudo systemctl status fan-noise-guard.service
```

Watch it operate:

```bash
sudo journalctl -u fan-noise-guard -f
```

Before installing the service, it's worth dry-running the script directly to
confirm it reads your sensors correctly without touching any hardware:

```bash
DRY_RUN=1 ./fan-noise-guard.sh
```

In dry-run mode every fan command is logged instead of executed.

## Tuning

All of this lives at the top of `fan-noise-guard.sh`:

| Variable | Meaning |
|---|---|
| `POLL_INTERVAL` | Seconds between temperature checks. |
| `READ_TIMEOUT` | Max seconds to wait on a sensor command before treating it as a failed read. |
| `ENTER` / `EXIT` | Per-tier temperature thresholds (°C) for stepping fan speed up / back down. The gap between them is the hysteresis band — widen it if you still see chatter, narrow it for a snappier response. |
| `SPEEDS` | Fan speed percentages corresponding to each tier. |
| `PANIC_C` | Hard ceiling — at/above this, or on any failed read, the watchdog stops trusting itself and hands control to iDRAC. |

The defaults are conservative starting points, not a guarantee of safety for
your specific hardware — check your components' actual thermal limits
(`sensors` reports `high`/`crit` values for CPU packages; GPU vendors publish
throttle/max operating temperatures) and set `PANIC_C` comfortably below
them.

## Safety notes

- **This modifies real fan control on a physical server.** Manual IPMI fan
  control disables iDRAC's own thermal safety response for as long as it's
  active. Don't run this unattended without the watchdog itself running, and
  don't lower `PANIC_C` or the speed tiers below what your hardware actually
  needs to stay cool under full load — verify under real load, not just
  idle, before trusting a configuration.
- If you have a **passively-cooled** GPU (no fan of its own), it depends
  entirely on chassis airflow. Be extra conservative with low-tier fan
  speeds and test under sustained load before leaving a configuration
  unattended.
- The systemd unit's `ExecStopPost` forces automatic control whenever the
  service stops or crashes for any reason, so a dead watchdog can't leave
  fans pinned at a low manual speed with nothing monitoring temperatures.
- The watchdog's failure/panic response is intentionally sticky: it will not
  attempt to re-arm manual control on its own after a panic. A human needs
  to check the logs and restart the service.

## How the fan speed command works

These specific raw IPMI bytes are the commonly documented Dell iDRAC7/8 OEM
extension for manual fan control:

```
ipmitool raw 0x30 0x30 0x01 0x00              # enable manual fan control
ipmitool raw 0x30 0x30 0x02 0xff 0x1e         # set all fans to 0x1e = 30%
ipmitool raw 0x30 0x30 0x01 0x01              # return to automatic control
```

## License

MIT — see [LICENSE](./LICENSE).
