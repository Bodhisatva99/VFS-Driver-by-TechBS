# VFS491 1.0.0 — Transaction 9 architecture

## Supported target

- HP EliteBook 8470p with Validity VFS491 USB sensor `138a:003d`
- Linux Mint 22.x / Ubuntu 24.04 base
- Existing `libfprint 1.94.7+tod1` runtime; build rejects a different core/TOD ABI
- x86_64

No other VFS model is enabled by this release. Firmware inclusion alone does not establish compatibility.

## Service lifecycle

1. `vfs491d.service` is boot-enabled and uses `Type=exec`.
2. Systemd runs the launcher, then runs `vfs491-wait-ready` as `ExecStartPost`. The readiness program opens the actual Unix socket, checks the broker's `READY` greeting, sends `QUIT` to close its temporary client, and exits. Systemd completes the start job only after this succeeds.
3. This avoids a `NOTIFY_SOCKET` dependency. The launcher intentionally mounts a private tmpfs over `/run`, which hid the pathname notification socket from Transaction 7's Python broker. That failure caused systemd to terminate a broker that had already created its socket.
4. The launcher validates private mount and IPC namespaces before mounting, holds a host-visible exclusive lock, waits for stable USB `138a:003d`, stages the vendor-required `pidof` path, sets up private `/run` and `/usr/sbin`, and starts `vcsFPService` once.
5. The launcher starts the broker in the foreground. The broker binds `/var/lib/vfs491/control.sock`, a root-only socket outside the private `/run` and `/tmp` overlays.
6. The systemd service remains active for the machine lifetime. A short-lived client proxy exists per fprintd claim; closing a proxy does not stop the persistent broker or HP vendor service.
7. Each `CAPTURE` runs a fresh invocation of the preserved 0.3.2 helper through `vfs491-bridge`. The bridge uses the CH_EVENT full-read compatibility shim and returns a framed image.
8. The broker validates the VFS1 frame's magic, version, width, height, maximum size and exact payload length before forwarding it.
9. Service stop, package removal or system shutdown ends the resident service. Cleanup is scoped to the service's private mount/IPC namespaces.

## Startup and readiness contract

- `Type=exec` avoids `Type=notify`'s dependency on the systemd notification socket.
- `ExecStartPost` is the readiness barrier. It cannot return success until the broker accepts a Unix-socket client and emits `READY`.
- `TimeoutStartSec=150s` covers USB stability checks, vendor startup and socket readiness. The readiness probe itself is bounded.
- `systemctl start vfs491d.service` and the TOD client's idempotent start request therefore wait until the broker is actually accepting clients.
- The daemon does not attempt systemd notification calls.
- Debian `postinst` does not suppress service-start failures. A failed start is a failed package configuration, not a false successful install.

## Capture and claim behavior

- Root-only `SO_PEERCRED` validation gates the local socket.
- Client `QUIT` or disconnect closes only the client connection. If a capture is active, its bridge/helper process group is terminated; the vendor service remains resident.
- The proprietary HP service lifecycle is independent of fprintd's device claim lifecycle.
- No-swipe timeout remains terminal for the active TOD claim. The driver does not restart the vendor service behind an open FpDevice.
- A service restart can reset/re-enumerate USB and is not part of ordinary authentication.

## Package boundary

- The package contains the native TOD module, service, broker, client, bridge, vendor payload and CH_EVENT shim.
- It pins the exact installed matching `libfprint-2-2` / `libfprint-2-tod1` versions.
- It does not change PAM, LightDM, fprintd enrollment data or libfprint core.

## Hardware acceptance required

1. Service starts at boot, `systemctl is-active` reports active, and the broker socket is mode 0600.
2. `vcsFPService` PID stays constant across two captures in each of two independent fprintd claims.
3. Kernel log shows no USB disconnect/re-enumeration between captures or claims.
4. Enrollment accepts multiple swipes and finishes; same-finger verify matches and different-finger verify rejects.
5. Repeated sudo authentication, close/reopen, no-swipe timeout, cancellation, daemon restart, suspend/resume, unplug/replug and reboot are tested.
6. PAM/LightDM integration is enabled only in a separate later package/change after the CLI lifecycle is stable.


## Transaction 9 recognition contract

The TOD image handoff keeps the archived VFS proprietary driver's one-stage enrollment and `COLORS_INVERTED | V_FLIPPED` image flags. The image-device matcher threshold is explicitly 40, the libfprint 1.94.7 default. No threshold weakening or unmeasured pixel transformations are used. See `RECOGNITION-PIPELINE.md` for diagnostic procedures and evidence boundaries.
