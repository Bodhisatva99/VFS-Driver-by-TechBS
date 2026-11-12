# SP84530 package audit — Synaptics 4.5-136.0

## Package identity

The supplied `SP84530.zip` is an extracted payload of `Validity-Sensor-Setup-4.5-136.0.x86_64.rpm` (Synaptics Incorporated, x86_64). The files in this reference copy are retained under `reference/sp84530-payload/`; they are not installed by the build.

## Exact comparison with the current 0.3.2 vendor inputs

These three payloads are byte-identical to `vendor/original/` in the current project:

| File | SHA-256 |
|---|---|
| `vcsFPService` | `03aec6bf1fdd8bc369b7eb96f04f1f58e2b392be753a4d5e9b457add2b1a57f9` |
| `libvfsFprintWrapper.so` | `159da565b618ab1b166dfd456249f9ffe80ffc9e3984702543d1ab5a1362dc74` |
| `HPUsbVFS491.img` | `235a5376bfda24261106a59f7f0eb09825608c6cf8914513d613b5646e068c4c` |

Therefore this archive does not provide a newer VFS491 service, wrapper or VFS491 firmware. It does expose additional package components that were not copied into the runtime folder of 0.3.2.

## Newly discovered components

- `usr/sbin/validity-sensor`: vendor ownership/initialization utility. The README documents `validity-sensor setowner -doinit` for an unsecured sensor, states that the service must be stopped, and says the operation may take 2–5 minutes. If the sensor is already secure, the utility is expected to fail without changing it.
- `usr/sbin/ValiditySensorEventHandler`: legacy event handler; not yet validated as necessary for VFS491 capture.
- `etc/init.d/vcsFPServiceDaemon`: openSUSE-style SysV service script using `/etc/rc.status`, `/sbin/startproc`, and `/sbin/killproc`; not suitable for direct installation on Linux Mint.
- `etc/pm/sleep.d/ValidityServiceSuspend.sh` and `usr/lib/pm-utils/sleep.d/65ValidityServiceResume.sh`: signal `vcsFPService` with `SIGUSR1` before suspend and `SIGUSR2` after resume. The project's `config/system-sleep/vfs491` already translates these signals to systemd-sleep hooks.
- `etc/udev/rules.d/100-Validity_FingerPrint_Sensor.rules` and `usr/bin/ValidityUdevHandler.sh`: historical udev/X11 integration. The rules reference `/usr/sbin/UsbPlugged` and `/usr/bin/test.sh`, neither of which is included in this archive. One remove rule is not restricted to VID 138a. Do not install these rules as-is.
- `usr/sbin/HPUsbVFS.img`, `HPUsbVFS471.img`, and `HPUsbVFS495.img`: firmware for other sensor variants; keep `HPUsbVFS491.img` selected for USB ID `138a:003d`.

## Ownership initialization finding

The package README says ownership initialization is normally done on first boot, but the RPM's post-install scriptlet only registers the daemon init script and removes an obsolete suspend hook; it does not invoke `validity-sensor setowner -doinit`. Thus package installation alone does not prove that this sensor was provisioned.

The `validity-sensor` binary declares legacy `libusb-0.1.so.4`, `libcrypto.so.0.9.8`, and `libssl.so.0.9.8` dependencies. It has not been executed as part of this audit. Keep it as a reference tool until its runtime dependencies and a contained invocation are verified. Do not add old OpenSSL or replace system libraries.

## Driver architecture decision (historical audit, updated by Transaction 7)

The vendor package has no alternative Linux driver source and no newer capture wrapper. Keep the proprietary service, wrapper and firmware in the existing controlled runtime directories. Add the ownership utility and historical scripts only as separately audited reference/diagnostic components.

Transaction 7 changes the **vendor service lifetime**, not the proven per-swipe capture contract: `vcsFPService` remains resident in an isolated systemd service while each swipe still uses a fresh 0.3.2 reference-helper invocation through the bridge. This redesign follows the Transaction 6 hardware log, which showed USB disconnect/re-enumeration after the transient claim-scoped service was closed. No ownership/provisioning operation is added by Transaction 7; the current ownership state remains unverified and the historical `validity-sensor setowner -doinit` utility remains outside the installed package.

## Provenance and containment

All extracted files here are reference material only. The build and tests do not install them. Proprietary vendor binaries and firmware remain locally supplied assets; retain their provenance and do not redistribute them without permission.
