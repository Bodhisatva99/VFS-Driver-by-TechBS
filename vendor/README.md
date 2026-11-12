# Local SP84530 payload

This HP-local bundle contains the Synaptics/Validity SP84530 service and VFS491 firmware supplied by the user. It is retained for local testing and is not part of the public GitHub source export.

`compat/libvfsFprintWrapper.so` is the user's already validated 0.3.2 compatibility copy. Keep `original/` separate and unchanged. The package builder verifies the vendor hashes in `vendor-sha256.txt` and does not edit the binaries.

For public source publication, remove `vendor/compat/`, `vendor/original/`, and `vendor/vendor-sha256.txt`; users must provide their own licensed SP84530 payload and their known-compatible wrapper. Never replace system OpenSSL or create legacy-soname symlinks.
