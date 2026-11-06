# ⌨️ Helix (personal setup)

My [Helix](https://helix-editor.com) configuration. The interesting part is that
`config.toml` is **generated** — it is assembled from small fragments, because
Helix only reads one file and TOML forbids re-opening a table such as
`[keys.normal]`.

- `keys/*.toml` — one file per topic (`00-layout`, `10-lines`, `30-scroll`, …).
  A later file wins when two of them set the same key, and the override is
  reported every time the config is built.
- A fragment may start with `# platform: windows`, `# platform: unix`
  (`linux` + `macos`), a list (`# platform: windows linux`) or `all`. Only the
  fragments matching the current platform are merged, so
  `keys/99-local-windows.toml` and `keys/99-local-unix.toml` can both live here.
- `build-config.ps1` (Windows) and `build-config.sh` (Linux/macOS, bash 4+)
  merge the fragments into `config.toml`. Both produce byte-identical output.
- `<space>B` inside Helix rebuilds `config.toml` and reloads it
  (`:config-reload`), then reports the result in the statusline.

```bash
./build-config.sh --check        # validate, write nothing
./build-config.sh --print        # to stdout
./build-config.sh --platform macos   # what another OS would get
```

## Install

Windows (PowerShell 5.1+, works on Windows Server too — uses winget, or a
portable GitHub release when winget is missing):

```powershell
irm https://raw.githubusercontent.com/ezonius/helix/master/install.ps1 | iex
```

Linux (Debian/Ubuntu, apt; installs the official `hx` tarball since apt's
version is stale):

```bash
curl -fsSL https://raw.githubusercontent.com/ezonius/helix/master/install.sh | bash
```

Both scripts install git and Helix, install a Nerd Font, back up an existing
config directory (`%APPDATA%\helix` or `~/.config/helix`), clone this repo there
and rebuild `config.toml` for the current platform. Re-running them updates the
checkout (`git pull --ff-only`).

| Windows | Linux | Meaning |
| --- | --- | --- |
| `-DryRun` | `DRY_RUN=1` | print the steps, change nothing |
| `-NoEditor` | `SKIP_EDITOR=1` | don't install/upgrade the `hx` binary |
| `-Destination <dir>` | `HELIX_CONFIG=<dir>` | install somewhere else |
| `-Repo`, `-Branch` | `HELIX_REPO`, `HELIX_BRANCH` | install another remote/branch |
| `-FontFamily <name>` | `HELIX_FONT=<name>` | Nerd Font family (default `FiraCode`) |
| `-NoFont` | `NO_FONT=1` | skip the Nerd Font |
| — | `SKIP_DEPS=1` | don't run apt (deps already present) |

Manual install: clone this repo into `%APPDATA%\helix` (Windows) or
`~/.config/helix` (Linux/macOS), then run `build-config.ps1` /
`build-config.sh` once to generate `config.toml`.

## Requirements

- Helix 24.07+ (`install.sh` installs the latest release; the config uses
  `page_cursor_half_*`, `move_visual_line_*`, `save_selection`, `toggle_comments`)
- git
- bash 4+ for `build-config.sh` (associative arrays), PowerShell 5.1+ for
  `build-config.ps1`
- a Nerd Font if your statusline uses icons: `FiraCode Nerd Font` is installed
  by default, then select it in your terminal (Windows Terminal > Profiles >
  Defaults > Appearance > Font face)

> `config.toml` is committed so the repo works on a fresh clone, but it is
> regenerated per platform: after installing on Linux, `git status` will show it
> as modified (it now holds the unix `<space>B` binding). That is expected — it
> is build output, not something to hand-edit.
