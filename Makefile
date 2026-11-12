.PHONY: bootstrap check build package test isolation-test hardware-test clean

bootstrap:
	./scripts/bootstrap-private-sysroot.sh

check:
	./scripts/check-source.sh

build:
	./scripts/build.sh

package:
	./scripts/build-system-deb.sh

test:
	./tests/test-bridge.sh
	./tests/test-transaction-static.sh
	./tests/test-readfull.sh
	python3 ./tests/test-persistent-broker.py
	python3 ./tests/test-systemd-readiness.py
	python3 ./tests/test-image-diagnostics.py

isolation-test:
	./scripts/check-systemd-isolation.sh

hardware-test:
	sudo systemctl start vfs491d.service
	sudo python3 ./scripts/test-capture-session.py --captures 2 --claims 2

clean:
	rm -rf build/* debs/*
	@touch build/.gitkeep
