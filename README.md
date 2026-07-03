# strongSwan Binary Releases

This repository builds the public strongSwan runtime rootfs artifact consumed by
Cadence container builds.

The artifact is a deterministic `linux/arm64` tarball containing the Debian
Trixie package closure for the Cadence MLLP strongSwan runtime. It is intended
to replace the Cadence monorepo Bazel apt flat layer:

```text
@trixie_strongswan//:flat
```

The current output names are:

```text
dist/strongswan-trixie-arm64-rootfs.tar
dist/strongswan-trixie-arm64-package-manifest.tsv
dist/SHA256SUMS
```

## Artifact Contract

The rootfs tar is built from pinned Debian snapshot repositories:

```text
deb [arch=arm64] https://snapshot.debian.org/archive/debian/20260501T205709Z trixie main
deb [arch=arm64] https://snapshot.debian.org/archive/debian/20260501T205709Z trixie-updates main
deb [arch=arm64] https://snapshot.debian.org/archive/debian-security/20260629T000000Z trixie-security main
```

The root package set is in [config/packages.txt](config/packages.txt). The
build resolves that package set with recommends and suggests disabled, downloads
the complete package closure for `arm64`, extracts each `.deb` into a staging
rootfs, adds deterministic dpkg status metadata, materializes the `base-passwd`
master passwd/group files, adds direct-extraction runtime metadata such as the
`tcpdump` user and `ld.so.cache`, applies the runtime symlinks in
[config/runtime-symlinks.tsv](config/runtime-symlinks.tsv), and emits a
deterministic tar with a fixed build umask.

Before downloading the runtime package set, the builder seeds every package
marked `Essential: yes` in the pinned apt metadata for the target architecture.
That keeps the extracted rootfs compatible with Debian package assumptions even
though maintainer scripts are not run.

The manifest records every downloaded `.deb` with package name, version,
architecture, SHA256, and filename.

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
require `apt-get`, `dpkg-deb`, `sha256sum`, and GNU tar.

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
uses only public Debian snapshot inputs and the repository `GITHUB_TOKEN`.

## Later Cadence Monorepo Consumption

The monorepo should consume a released tar by SHA256, then layer it where
`@trixie_strongswan//:flat` is currently used. Keep the SHA from `SHA256SUMS`
near the Bazel repository declaration so future snapshot/package refreshes are
reviewable.
