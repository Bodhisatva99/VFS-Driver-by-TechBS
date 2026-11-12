# VFS-Driver-by-TechBS
VFS Driver
Driver mainly devoloped for HP EliteBook 8470p VFS491 (138a:003d) on Linux Mint 22.x / Ubuntu 24.04 base,but compatible with others.
 
 This project is originally devoloped for vfs491 to work on a hp elitebook 8470p,but alongside i included older vfs sensors support like
 
 Validity VFS491
 
 Validity VFS495
 
 Validity VFS471
 
  but vfs491 is tested and stable under this driver while tests are not perfomed on other sensors,
 
 This driver has namespace-isolated HP service and root-only broker. It adds non-image frame telemetry in the TOD backend and an optional local image-diagnostics utility. The archived Validity driver’s one-stage enrollment and image polarity/orientation convention are retained; the Bozorth3 threshold is explicitly kept at libfprint's documented default of 40 rather than weakened to mask false rejects.
 
 Build against the target machine's exact installed libfprint 1.94.7+tod1 runtime
make bootstrap
make check
make build
make test
make isolation-test
make package
 Install the Generated package
sudo apt install ./debs/vfs491-fprintd-tod_1.0.0~transaction9-1_amd64.deb
