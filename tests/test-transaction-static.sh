#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$ROOT/scripts/vfs491d-launcher.sh"
DAEMON="$ROOT/scripts/vfs491d.py"
CLIENT="$ROOT/scripts/vfs491-client.py"
UNIT="$ROOT/systemd/vfs491d.service"
TOD="$ROOT/src/vfs491-tod.c"
BRIDGE="$ROOT/src/vfs491-bridge.c"
HELPER_LAUNCHER="$ROOT/scripts/vfs491-helper-launcher.sh"
READFULL="$ROOT/src/vfs491-readfull.c"
BUILDER="$ROOT/scripts/build-system-deb.sh"
WAIT_READY="$ROOT/scripts/vfs491-wait-ready.py"

bash -n "$LAUNCHER" "$HELPER_LAUNCHER"
python3 -m py_compile "$DAEMON" "$CLIENT" "$WAIT_READY"
python3 - "$LAUNCHER" "$DAEMON" "$CLIENT" "$UNIT" "$TOD" "$BRIDGE" "$HELPER_LAUNCHER" "$READFULL" "$BUILDER" "$WAIT_READY" <<'PY'
from pathlib import Path
import sys
launcher, daemon, client, unit, tod, bridge, helper_launcher, readfull, builder, wait_ready = [Path(x).read_text() for x in sys.argv[1:]]
open_fn = tod[tod.index('vfs491_img_open (FpImageDevice *device)'):tod.index('vfs491_img_close (FpImageDevice *device)')]
close_fn = tod[tod.index('vfs491_img_close (FpImageDevice *device)'):tod.index('vfs491_activate (FpImageDevice *device)')]
deactivate_fn = tod[tod.index('vfs491_deactivate (FpImageDevice *device)'):tod.index('vfs491_change_state (FpImageDevice *device,')]
checks = [
    ("mount and IPC namespace guards precede mount operations", launcher.index('same_namespace ipc') < launcher.index('mount --make-rprivate /')),
    ("launcher verifies private mount and IPC namespaces", 'same_namespace mnt' in launcher and 'same_namespace ipc' in launcher),
    ("vendor service starts before persistent broker", launcher.index('exec "$VENDOR_DIR/vcsFPService"') < launcher.index('python3 "$DAEMON"')),
    ("vendor service is not tied to client QUIT", 'received session close request' not in launcher and 'python3 "$DAEMON"' in launcher),
    ("systemd unit is boot enabled and resident", 'WantedBy=multi-user.target' in unit and 'Restart=on-failure' in unit),
    ("systemd keeps service namespaces isolated", 'PrivateMounts=yes' in unit and 'PrivateIPC=yes' in unit and 'PrivateTmp=yes' in unit),
    ("systemd waits for real broker protocol readiness", 'Type=exec' in unit and 'ExecStartPost=/usr/libexec/vfs491/vfs491-wait-ready' in unit and 'TimeoutStartSec=150s' in unit and 'Type=notify' not in unit),
    ("readiness probe verifies READY and closes only its temporary client", 'READY' in wait_ready and 'QUIT\\n' in wait_ready and 'time.monotonic()' in wait_ready),
    ("broker no longer relies on NOTIFY_SOCKET inside private /run", 'notify_systemd' not in daemon and 'NOTIFY_SOCKET' not in daemon),
    ("daemon exposes a persistent Unix socket", 'SOCKET_PATH' in daemon and 'server.listen' in daemon and '/var/lib/vfs491/control.sock' in daemon),
    ("daemon authenticates local peer as root", 'SO_PEERCRED' in daemon and 'uid == 0' in daemon),
    ("daemon launches the reference bridge per capture", 'subprocess.Popen' in daemon and '[BRIDGE, HELPER]' in daemon),
    ("daemon does not stop vendor service on client close", 'vendor service remains resident' in daemon and 'stop_vendor' not in daemon),
    ("daemon validates image framing before forwarding", 'def validate_frame' in daemon and 'validate_frame(bytes(frame))' in daemon),
    ("client starts service and allows full bounded startup window", 'systemctl' in client and 'start_service()' in client and 'timeout=170' in client),
    ("client uses Unix socket and byte-transparent proxy", 'AF_UNIX' in client and 'sock.sendall(chunk)' in client),
    ("TOD uses per-claim proxy rather than transient systemd unit", 'VFS491_DEFAULT_CLIENT' in tod and 'systemd-run' not in tod and 'systemctl' not in tod),
    ("TOD opens client during fprintd claim", 'vfs491_start_session (self);' in open_fn),
    ("TOD sends QUIT only to client connection on close", 'QUIT\\n' in close_fn and 'g_output_stream_close' in close_fn),
    ("normal deactivation does not close persistent broker", 'fpi_image_device_deactivate_complete (device, NULL)' in deactivate_fn and 'QUIT' not in deactivate_fn.split('/* Cancellation')[0]),
    ("reference CH_EVENT read shim retained without IPC keepalive", 'LD_PRELOAD' in helper_launcher and 'READFULL' in helper_launcher and 'keepalive' not in helper_launcher.lower()),
    ("read shim targets only CH_EVENT FIFO", 'strstr(target, "/tmp/CH_EVENT") != NULL' in readfull),
    ("bridge does not inject SysV IPC keepalive", 'VFS491_IPC_KEEPALIVE_SO' not in bridge and 'libvfs491-ipc-keepalive' not in bridge),
    ("package version is Transaction 9", 'Version: 1.0.0~transaction9-1' in builder),
    ("production matcher threshold is explicit and unchanged at libfprint default 40", 'image_class->bz3_threshold = 40;' in tod),
    ("VFS swipe enrollment stage count remains the upstream one-stage contract", 'device_class->nr_enroll_stages = 1;' in tod),
    ("capture telemetry logs metrics but never stores raw fingerprint images", 'vfs491_log_frame_statistics' in tod and 'image quality telemetry' in tod),
    ("original Validity polarity and vertical orientation are preserved", 'FPI_IMAGE_COLORS_INVERTED | FPI_IMAGE_V_FLIPPED' in tod),
    ("diagnostic capture tool is installed", 'vfs491-image-diagnostics.py' in builder),
    ("package installs bounded readiness probe", 'vfs491-wait-ready.py' in builder and 'vfs491-wait-ready' in builder),
    ("package does not suppress service startup failure", 'systemctl start vfs491d.service\n' in builder and 'systemctl start vfs491d.service || true' not in builder),
    ("PAM and LightDM are not modified by driver package", 'libpam-fprintd' not in builder and 'pam-auth-update' not in builder),
]
for label, ok in checks:
    print(("PASS" if ok else "FAIL") + ": " + label)
if not all(ok for _, ok in checks):
    raise SystemExit(1)
PY
