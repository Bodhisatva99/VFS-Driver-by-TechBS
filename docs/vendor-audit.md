# SP84530 vendor audit and implementation boundaries

## Provenance

The supplied SP84530 archive contains the HP/Synaptics Validity Sensor Setup 4.5-136.0 x86_64 RPM. The `libvfsFprintWrapper.so` in that RPM has the same SHA-256 as `vendor/original/libvfsFprintWrapper.so` in this project. The service and VFS491 firmware also match the original files previously imported into the project. This archive adds no newer service or wrapper build.

The RPM additionally contains `validity-sensor`, `ValiditySensorEventHandler`, a historical udev rule, init script and suspend/resume hooks. Its README documents first-use provisioning with `validity-sensor setowner -doinit`; it states that `vcsFPService` must be stopped, the operation takes about 2–5 minutes and already-secured sensors are left unchanged when the command fails. The current sensor ownership state has not been queried, so provisioning is not yet justified.

## Wrapper API and current worker

The v0.3.2 C worker links `libvfsFprintWrapper.so` as a direct ELF `NEEDED` dependency with eager binding (`BIND_NOW`). It calls:

1. `vfs_wait_for_service()`
2. `vfs_set_matcher_type(VFS_FPRINT_MATCHER)`
3. `vfs_dev_init()`
4. `vfs_capture(&device, 1)`
5. `vfs_get_img_data()` and image metadata getters
6. `vfs_free_img_data()`, `vfs_clean_handles()` and `vfs_dev_exit()`

This mirrors the call sequence and loader model in the preserved legacy helper binary. Do not describe the current worker as using runtime `dlopen()`; that was an earlier prototype design.

## OpenSSL boundary

The original service, wrapper and `validity-sensor` declare `libcrypto.so.0.9.8` and `libssl.so.0.9.8` dependencies. The project compatibility copies for the service and wrapper remove only these old `DT_NEEDED` declarations; their machine code is not rebuilt. The driver does not replace system OpenSSL and must not symlink OpenSSL 3 libraries to legacy sonames. The `validity-sensor` binary has no direct undefined OpenSSL API imports in its dynamic symbol table, but its actual runtime behavior after any private compatibility adjustment remains untested. Preserve the RPM original and test only a project-local copy if required.

## Legacy package details

- `ValiditySensorEventHandler` is a small standalone ELF executable with only a libc runtime dependency. Its strings show old diagnostic logging and a `/tmp/NP2` FIFO; the package does not establish that it provides the swipe event consumed by `vfs_capture()`.
- The bundled udev rule calls `/usr/sbin/UsbPlugged` and `/usr/bin/test.sh`, which are absent from the supplied RPM payload. Do not install this historical rule as-is.
- Historical suspend/resume scripts send `SIGUSR1` and `SIGUSR2` to `vcsFPService`. Do not add those hooks until behavior is verified with the actual service build.
- The service hard-codes `/usr/sbin/HPUsbVFS491.img` and `/var/run/ValidityService.pid`. The development launcher exposes these paths in a private mount namespace while sharing `/tmp` for the vendor IPC objects.

## Evidence boundary and Transaction 7 update

A successful plugin load, USB open or `vfs_dev_init()` is not proof of swipe acquisition. The 2026-11-04 v0.3.2 log reached `vfs_capture()` and timed out after 60 seconds without image metadata; the preserved reference helper remains the capture baseline. Transaction 7 does not replace that helper with a new persistent-worker architecture. It separates the lifetime of `vcsFPService` from the lifetime of an fprintd claim because the Transaction 6 physical log recorded USB disconnect/re-enumeration after the transient claim-scoped service stopped. Whether the resident-service design eliminates that reset and remains stable after timeout/cancellation is still a required physical acceptance test. Sensor ownership/provisioning remains unverified; Transaction 7 does not run the historical ownership utility.
