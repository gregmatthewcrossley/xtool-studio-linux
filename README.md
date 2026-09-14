# xTool Studio on Linux

Scripted setup for running **xTool Studio** (the Windows build) on Linux under Wine.

xTool ships xTool Studio and xTool Creative Space for Windows and macOS only.
There is no Linux build, and there cannot easily be a community one — see
[Why not just repackage it?](#why-not-just-repackage-it).

The short version of the interesting part: **stock distro Wine is not new enough.**
On anything older than Wine 11.5 the app starts, spawns its processes, prints no
error, and then hangs forever with no window. The cause is a stack overflow
inside Wine's builtin `DWrite.dll`. Details in
[Why stock Wine fails](#why-stock-wine-fails).

---

## Status

Tested on Fedora 44 (KDE, Wayland/XWayland, NVIDIA proprietary driver) with
xTool Studio 1.9.11 (Electron 36.2.0), under both Wine 11.5 (wine-tkg) and Wine
11.17 (Kron4ek staging — the build `install.sh` fetches by default).

| | |
|---|---|
| Application launches | ✅ verified |
| Full UI renders, fonts correct | ✅ verified |
| Projects, workspace, material settings | ✅ verified |
| Network device-discovery routine runs | ✅ verified (no machine attached to find) |
| Actually connecting to a machine | ⚠️ **untested** |
| Running a job / engraving | ⚠️ **untested** |
| Camera / auto-positioning features | ⚠️ **untested** |

The unverified rows are unverified because no machine was connected when this
was written — not because they are known broken. **If you try any of them,
please open an issue and say what happened.** That is the single most useful
contribution to this repo.

---

## Requirements

- A 64-bit Linux system with a working X11 or XWayland session.
- Wine **11.5 or newer**. If your distro's Wine is older, `install.sh` offers to
  download a self-contained build; nothing is installed system-wide.
- About **4 GB** of free disk space (1.3 GB app, ~1.5 GB Wine prefix, plus the
  installer and a downloaded Wine build if needed).
- The official Windows installer, `xTool-Studio-x64-<version>.exe`, from
  <https://www.xtool.com/pages/software>. This repo does not redistribute it.

Packages:

```bash
# Fedora
sudo dnf install p7zip winetricks cabextract icoutils curl

# Debian / Ubuntu
sudo apt install p7zip-full winetricks cabextract icoutils curl

# Arch
sudo pacman -S p7zip winetricks cabextract icoutils curl
```

`icoutils` is optional — without it you get a generic icon instead of xTool's.

---

## Install

```bash
git clone https://github.com/gregmatthewcrossley/xtool-studio-linux
cd xtool-studio-linux
./install.sh
```

It picks up the newest `xTool-Studio-x64-*.exe` in `~/Downloads` automatically.
Otherwise point at it:

```bash
./install.sh --exe ~/somewhere/xTool-Studio-x64-1.9.11.exe
```

Useful flags:

| Flag | Effect |
|---|---|
| `--wine PATH` | Use a specific Wine build (a binary or a tree containing `bin/wine`). Skips the version check. |
| `--prefix PATH` | Put the Wine prefix somewhere other than `~/.local/share/wineprefixes/xtool-studio`. |
| `--no-download` | Never fetch Wine; fail if the system one is too old. |

Re-running `install.sh` is safe. It reuses the existing prefix, fonts and
downloaded Wine, and replaces only the application — which is how you upgrade to
a newer xTool Studio release.

## Usage

Launch **xTool Studio** from your application menu, or:

```bash
xtool-studio
```

On first launch it prompts to install **CH340** and **RNDIS** drivers.
**Dismiss both.** Those are Windows USB drivers; Linux has `ch341` and
`rndis_host` in-kernel already, and installing the Windows ones inside Wine
accomplishes nothing. Tick "No more reminders".

You do **not** need to add yourself to the `dialout` group on a modern systemd
distro — your desktop session is granted access to `/dev/ttyUSB*` and
`/dev/ttyACM*` through a uaccess ACL. Check with `getfacl /dev/ttyACM0`. Wine
maps those devices to COM ports automatically at startup; no manual mapping is
needed.

## Uninstall

```bash
./uninstall.sh              # removes everything
./uninstall.sh --keep-wine  # keeps the downloaded Wine build
```

Your projects live inside the Wine prefix under
`~/.local/share/wineprefixes/xtool-studio/drive_c/users/$USER/`. Back them up
first.

---

## Why stock Wine fails

This is the part worth writing down, because the symptom gives you nothing to
search for.

Under Wine 11.0, xTool Studio starts normally. The main process runs, the
crashpad handler and GPU process spawn, the log shows extensions installing and
language packs decompressing, and it reaches:

```
PROD loadURL atomm://renderer/shell
```

…and then stops. No window, no crash dialog, no error, no exit. The process sits
there forever. The only clue is a single line on stderr:

```
0024:err:virtual:virtual_setup_exception stack overflow 1856 bytes addr 0x6fffffc0a9c2 stack 0x1208c0 (0x120000-0x121000-0x920000)
```

Running with `WINEDEBUG=+seh,+loaddll` and mapping the faulting address against
the module load addresses puts it in Wine's builtin `DWrite.dll`, and
disassembling that offset lands on a `call` instruction inside
`localizedstrings_GetString` — the 8 MB main-thread stack was already exhausted
by then, so that is where it hit the guard page rather than the cause. The
browser process recurses to death through DirectWrite while setting up fonts for
the renderer.

There are **two** separate contributing problems, and fixing only one is not enough:

1. **No fonts in the prefix.** A fresh prefix on a distro that splits Wine's
   fonts into a separate package (Fedora is one) has *zero* fonts in
   `drive_c/windows/Fonts`. Chromium's font fallback has nothing to fall back
   to. `install.sh` runs `winetricks corefonts`.

2. **Wine's DirectWrite implementation.** Installing fonts alone does **not**
   fix it on 11.0 — the app gets further, spawns more processes, and still dies
   the same way. Wine 11.5 fixes it.

Verified: **11.0 broken; 11.5 and 11.17 working.** 11.1 through 11.4 were not
tested, so `install.sh` requires 11.5 as its floor and downloads 11.17 when the
system Wine is older. If you establish that an earlier release works, please
open an issue.

Fedora 44 ships only Wine 11.0, so on Fedora this is guaranteed to bite you.

### The installer also does not work

`xTool-Studio-x64-<version>.exe` is an NSIS installer, and it exits silently
under Wine within a few seconds having installed nothing — no error, exit code 0.
This is the NSIS UAC-elevation plugin failing quietly.

So `install.sh` does not run it. It extracts the payload directly:

```
xTool-Studio-x64-1.9.11.exe        NSIS installer
└── $PLUGINSDIR/app-64.7z          the actual application, 1.3 GB unpacked
```

and unpacks that into the prefix. The result is identical to what the installer
would have produced, minus registry entries and an uninstaller that Linux does
not need anyway.

### Flags the launcher passes

Only `--no-sandbox`, which Electron needs under Wine.

Several commonly-recommended Chromium-under-Wine flags turned out to be
unnecessary once the real problem was fixed, and one is actively harmful:
`--use-angle=gl` fails outright with `WGL_NV_DX_interop2 is required but not
present`. `--disable-gpu`, `--in-process-gpu` and
`--disable-features=CalculateNativeWinOcclusion` change nothing here. If you are
debugging, try the plain launcher before adding flags.

---

## Why not just repackage it?

xTool Studio is an Electron app, so the obvious idea is to pull `app.asar` out
and run it on native Linux Electron. That does not work.

The application ships a substantial native Windows backend that has no Linux
counterpart and no source:

```
resources/tools/algo-server/algo-server-win32-x64.exe
resources/tools/algo-server/plugins/algo-path-planning-plugin/lib_path_planning.dll
resources/tools/algo-server/plugins/algo-dq-plugin/lib_dq.dll
resources/tools/algo-server/plugins/algo-dt-plugin/lib_dt.dll
resources/tools/algo-server/plugins/algo-js-plugin/lib_js.dll
resources/tools/algo-server/plugins/algo-visual-perception-plugin/lib_visual_perception.dll
resources/tools/algo-server/plugins/algo-visual-sensing-plugin/lib_visual_sensing.dll
resources/tools/algo-server/plugins/algo-perception-3d-plugin/lib_perception_3d.dll
resources/tools/algo-server/plugins/algo-graphic-image-plugin/lib_graphic_image.dll
resources/tools/algo-server/plugins/algo-time-estimate-plugin/lib_time_estimate.dll
```

Toolpath generation, dithering and halftoning, image processing, time estimation
and the camera/perception features are all in there — roughly 150 MB of
closed-source Windows binaries. Strip the Electron shell away and you have a UI
that cannot compute a job.

This is the same wall the [`xtool-creative-space`
AUR package](https://aur.archlinux.org/packages/xtool-creative-space) hits.
Running the whole thing under Wine is the realistic option.

### Alternatives

If a Wine setup is not for you, [LightBurn](https://lightburnsoftware.com/) is
commercial, has a native Linux build, and drives many xTool machines — though
not every model, and not every feature that depends on xTool's own camera and
perception stack.

---

## Contributing

Most wanted:

- Reports of the ⚠️ rows in [Status](#status) — whether a machine actually
  connects, and whether jobs run.
- Confirmation on other distros.
- A narrower lower bound than 11.5, if one of 11.1–11.4 works.
- Whether a newer Fedora Wine, once it lands, makes the download unnecessary.

Please include your distro, `wine --version`, xTool Studio version and machine
model.

## Disclaimer

Unofficial and unaffiliated with xTool. Nothing here is endorsed or supported by
them, and using it will not win you any sympathy from their support team. You
are driving a machine with a powerful laser in it through an unsupported
compatibility layer — supervise your jobs and know where the stop button is.

## License

MIT — see [LICENSE](LICENSE). This covers the scripts in this repo only.
xTool Studio itself is proprietary and is not redistributed here.
