# Reference capture compatibility notes

The supplied 0.3.2 reference helper path uses `libvfs491-readfull.so` to aggregate partial reads from the vendor `/tmp/CH_EVENT` FIFO. Transaction 5 restored this behavior after Transaction 4's extra IPC keepalive preload correlated with `vfs_dev_init(): ClientCreate failure` on a later helper invocation. Transaction 7 preserves the same per-swipe helper lifecycle and does not preload an IPC keepalive shim.

## Service lifetime decision

The capture helper remains a fresh process for every swipe. The proprietary `vcsFPService` is a separate, boot-resident process in Transaction 7. Individual fprintd claims connect to a persistent local broker; their `QUIT` command closes only that claim's client connection. It must not stop `vcsFPService`, tear down its IPC namespace or reset the USB sensor.

The Transaction 6 target log showed USB `138a:003d` disconnecting and re-enumerating at the same physical port during the verification/release sequence. Transaction 6 stopped the vendor service from its transient per-claim systemd unit on device close. Transaction 7 removes this normal-close teardown path. The timing is consistent with that teardown causing the observed reset, but this causal link still requires the Transaction 7 physical acceptance test: the vendor PID must remain unchanged and kernel logs must show no USB disconnect across separate claims.
