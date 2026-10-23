# mpc-addin-filebrowser

[FileBrowser Quantum](https://github.com/gtsteffaniak/filebrowser) on an Akai MPC OS standalone device (MPC
Live/One/X/Key, Force; Gen1 and Gen2), beside MPC: browse the device's drives in a web browser, upload samples and
projects to them, download from them, rename, move and delete.

It's an **addin**: a small shared library that MPC loads at start through `LD_PRELOAD`. The library does one thing
inside MPC: as MPC starts, it starts `filebrowser-run.sh` from its folder as a separate process and returns. The script
runs FileBrowser Quantum (its own static binary, in the same folder), starts it again if it exits, and stops it when MPC
exits. So FileBrowser runs exactly while MPC runs, and installing, upgrading and removing it work like any other addin.

This repo holds none of FileBrowser Quantum's code or binaries: `upstream.env` names the release and the SHA-256 of its
files, and the build downloads them and refuses anything that doesn't match. A daily workflow opens a pull request when
upstream publishes a newer stable release (see [Updating FileBrowser](#updating-filebrowser)).

**Status:** offline only. The host tests and the real FileBrowser binary for both device CPUs under QEMU pass
(`tests/`), and both zips pass the catalog check. Not yet run on a device.

## Connecting

FileBrowser listens on the device only (`bind=127.0.0.1`), on port 6740. From a computer, open an SSH tunnel and leave
it running:

```sh
ssh -N -L 6740:127.0.0.1:6740 root@<device address>
```

Then open `http://localhost:6740` and log in as **admin** with the password in
`/data/mpc-addins/filebrowser/admin-password` (`ssh root@<device> cat /data/mpc-addins/filebrowser/admin-password`). The
addin makes it, 16 random characters, at the first MPC start after installing, and sets it again at every start, so
change it by editing that file, not in FileBrowser's settings.

`bind=0.0.0.0` in the settings opens it to every network the device is on instead. Unlike the other network addins it
has a login, but an admin can read, change and delete every file in the folders it shows, and the server runs as root.

## Settings

`/data/mpc-addins/filebrowser/mpc_filebrowser_addin.conf`, read at each MPC start; an upgrade keeps your edits.

| Key | Default | |
|---|---|---|
| `enabled` | `1` | `0`: start nothing |
| `bind`, `port` | `127.0.0.1`, `6740` | where FileBrowser listens |
| `sources` | `/media:/storage` | the folders it shows, split by `:`. One that doesn't exist or is empty (a mount point with nothing mounted) is skipped. `/media` holds the internal drive on Gen1 and every SD card and USB drive on both generations |
| `index` | `0` | `1`: FileBrowser's search index (a full scan of the folders at each start, then rescans). Off by default because the scan competes with MPC for the disk; browsing, uploads and downloads work without it |
| `previews` | `1` | image thumbnails |
| `nice` | `19` | FileBrowser's CPU priority (0..19, higher is gentler). It always runs in the idle disk class too |
| `memory_mb` | `192` | a soft memory limit (Go's `GOMEMLIMIT`); it also uses at most 2 CPU cores |
| `log` | empty | a file to append FileBrowser's and the script's log to |
| `config` | empty | a FileBrowser config file of your own, used instead of the one written from the keys above |

The config written from these keys is `config.yaml` in the same folder. FileBrowser's database, its thumbnail cache and
the password file live there too; uninstalling leaves them (and so the folder) in place. Delete the folder to remove them.

## Install

Download the release zip for your device: `-mpc-armv7.zip` for Gen1 (MPC Live/Live II, One, X, Key 61/37, Force) or
`-mpc-aarch64.zip` for Gen2 (Live III, One G2, Key(s) G2). Unzip it and follow its `INSTALL.md`: copy the folder to the
device over SSH and run `install.sh` there. It needs root shell access, and it restarts MPC. Uninstall with
`sh /data/mpc-addins/filebrowser/uninstall.sh`.

## Why the library starts a program

The catalog flags the library for calling `fork` and `execve`. That is how it starts the script: a double fork, so MPC
never has to wait for or reap it, with everything prepared before the first fork and only plain system calls between
fork and exec. The script runs in its own session, without `LD_PRELOAD` (so FileBrowser doesn't load the addins), with
every signal at its default, at the `nice` value and in the idle disk class. The library does nothing in a process whose
executable isn't named `MPC`.

## Building

```sh
./build.sh            # Gen1: build/
./build.sh aarch64    # Gen2: build/aarch64/
tests/test.sh         # host tests: the library and the script (sh, and BusyBox when installed)
tests/smoke.sh armv7  # the real FileBrowser binary run by the script under QEMU (and: aarch64)
```

`build.sh` compiles the library in Docker (QEMU for the target CPU; Gen1 against glibc 2.31 so it loads on older MPC OS)
and runs `tools/fetch-upstream.sh`, which downloads FileBrowser's binary and licence and checks them against
`upstream.env`. Releases come from CI: run the Release workflow with a version; it attaches both zips to a draft release.
Install that zip on a device, then publish the draft (as a prerelease while the version is 0.x).

## Updating FileBrowser

The Upstream workflow runs daily. When FileBrowser Quantum has a newer `-stable` release (its `-beta` releases are
ignored), it moves `upstream.env` to it, builds and tests both packages with it, and opens a pull request that links the
test run. Read upstream's release notes for config changes, merge, and run Release with a new version. To move to a
specific tag, run Upstream by hand with that tag, or locally: `tools/upstream-check.sh <tag>`.

## Licence

This repo: MIT. FileBrowser Quantum: Apache-2.0, by its authors; its licence ships in every zip as
`LICENSE-filebrowser`, and the binary is the unmodified upstream release.
