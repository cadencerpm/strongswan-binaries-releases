SHELL := /usr/bin/env bash

.PHONY: build test clean

build:
	./scripts/build-rootfs.sh

test:
	./scripts/test-rootfs.sh

clean:
	rm -rf build dist
