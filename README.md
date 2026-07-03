# strongSwan Binary Releases

This repository builds the public strongSwan runtime rootfs artifact consumed by
Cadence container builds.

The artifact is a deterministic `linux/arm64` tarball containing a Debian
Trixie runtime package closure plus a source-built strongSwan release for the
Cadence MLLP strongSwan runtime. It is intended to replace the Cadence monorepo
Bazel apt flat layer:

```text
@trixie_strongswan//:flat
```

The current output names include the upstream strongSwan version:

```text
dist/strongswan-6.0.7-trixie-arm64-rootfs.tar
dist/strongswan-6.0.7-trixie-arm64-package-manifest.tsv
dist/SHA256SUMS
```

## Artifact Contract

The rootfs Debian package closure is built from pinned Debian snapshot
repositories:

```text
deb [arch=arm64] https://snapshot.debian.org/archive/debian/20260501T205709Z trixie main
deb [arch=arm64] https://snapshot.debian.org/archive/debian/20260501T205709Z trixie-updates main
deb [arch=arm64] https://snapshot.debian.org/archive/debian-security/20260629T000000Z trixie-security main
```

The root package set is in [config/packages.txt](config/packages.txt). The
build resolves that package set with recommends and suggests disabled, downloads
the complete package closure for `arm64`, and extracts each `.deb` into a
staging rootfs. The Debian package closure intentionally excludes Debian's
`strongswan-*` packages because trixie stable is on `6.0.1`, while Cadence needs
`6.0.7+`.

The builder downloads `strongswan-${STRONGSWAN_VERSION}.tar.bz2` from the
official strongSwan release host, verifies `STRONGSWAN_SOURCE_SHA256`, builds it
inside the arm64 trixie build container, and installs it into the staging rootfs
under Debian-compatible paths such as `/usr/sbin/ipsec` and
`/usr/lib/ipsec/charon`.

The build adds deterministic dpkg status metadata for Debian packages,
materializes the `base-passwd` master passwd/group files, adds direct-extraction
runtime metadata such as the `tcpdump` user and `ld.so.cache`, applies the
runtime symlinks in [config/runtime-symlinks.tsv](config/runtime-symlinks.tsv),
and emits a deterministic tar with a fixed build umask.

Before downloading the runtime package set, the builder seeds every package
marked `Essential: yes` in the pinned apt metadata for the target architecture.
That keeps the extracted rootfs compatible with Debian package assumptions even
though maintainer scripts are not run.

The manifest records every downloaded `.deb` with package name, version,
architecture, SHA256, and filename. It also records the source-built strongSwan
row as `strongswan-upstream`, with the upstream version and source tarball
SHA256.

The build tries `snapshot-cloudflare.debian.org` first and falls back to
`snapshot.debian.org`. Override `SNAPSHOT_HOSTS` with a space-separated host
list when retrying a release build.

## Build

The portable path uses Docker with a `linux/arm64` Debian container. On amd64
hosts, Docker must have QEMU/binfmt support enabled.

```sh
make build
make test
```

To force a native Linux build, set `STRONGSWAN_ROOTFS_NATIVE=1`. Native builds
require `apt-get`, `curl`, `dpkg-deb`, `make`, `sha256sum`, GNU tar, and the
strongSwan source build dependencies installed locally.

```sh
STRONGSWAN_ROOTFS_NATIVE=1 make build
```

Clean generated state with:

```sh
make clean
```

## Release

`.github/workflows/release.yml` builds and tests on pull requests, manual
dispatch, `main` pushes, and tags. Each `main` push publishes the tar, manifest,
and `SHA256SUMS` as GitHub Release assets under an immutable `main-<short-sha>`
tag. Tag builds also publish the same assets under the pushed tag. The workflow
uses only public Debian snapshot and official strongSwan source inputs, plus the
repository `GITHUB_TOKEN`.

## Later Cadence Monorepo Consumption

The monorepo should consume a released tar by SHA256, then layer it where
`@trixie_strongswan//:flat` is currently used. Keep the SHA from `SHA256SUMS`
near the Bazel repository declaration so future snapshot/package refreshes are
reviewable.
