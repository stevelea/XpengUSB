# xpeng-settings

A single-page settings form for the car Pi, and the retirement of nginx on it.

## Why

The archive viewer used to run on the Pi. It wedged a 430 MB Zero W once, because
serving video from a CIFS mount is not a job for that board. The viewer now lives
on the Frigate host as the `xpeng-viewer` container (`http://192.168.1.202:8090`),
reading the same NAS archive over NFS.

What is left for the Pi is the thing only the Pi can do: **change its own
settings**. Hence this page, on port 8081, stdlib Python, no nginx.

## What it can change

Only a whitelist, each value validated against its own type before it is written:

| Key | Kind |
|---|---|
| `XPENG_EMERGENCY_SYNC` / `XPENG_NORMAL_SYNC` | `always` / `home` / `off` |
| `XPENG_RETENTION_DAYS` | integer 0..3650 (0 = keep forever) |
| `XPENG_DELETE_AFTER_UPLOAD` | `1` / `0` |
| `XPENG_VIEWS` | "front only" or "all views" (shown with what each costs) |
| `XPENG_DRIVE_RETENTION_DAYS` | integer 0..3650 — days a clip stays **on the car's drive** after being archived (default 14) |
| `XPENG_MIN_AGE`, `XPENG_EMERGENCY_INTERVAL`, `XPENG_NORMAL_INTERVAL` | integers |
| `XPENG_EXTRA_DIRS` | letters/digits/space/underscore/dot/dash |

Everything else in the config file - comments, unrelated keys - is preserved
verbatim. The write is a temp file plus rename, so a crash cannot leave a
half-written config.

## Security

HTTP Basic auth, credentials in `/etc/xpeng-settings.env` (mode 600, generated on
install). The comparison is constant-time. It listens on the LAN, which was the
explicit choice for this installation; on a shared network put it behind
Tailscale instead by setting `XPENG_SETTINGS_BIND` to the tailnet address.

There is no shell anywhere: no `eval`, no `system()`, and the text field is
restricted to `[A-Za-z0-9_.- ]`. A value like `$(reboot)` is rejected, which the
test suite demonstrates.

## Install

```bash
sudo bash install.sh      # on the Pi
```
