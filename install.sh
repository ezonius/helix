#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Helix setup installer (Debian / Ubuntu, apt based)
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/ezonius/helix/master/install.sh | bash
#
# Environment variables:
#   HELIX_REPO=https://github.com/ezonius/helix.git   git remote to install
#   HELIX_BRANCH=<default>                            branch or tag (default: remote HEAD)
#   HELIX_CONFIG=~/.config/helix                      target config directory
#   HELIX_FONT=FiraCode                               Nerd Font family to install
#   NO_FONT=1                                         skip the Nerd Font
#   SKIP_EDITOR=1                                     do not install/upgrade the hx binary
#   SKIP_DEPS=1                                       do not run apt-get at all
#   HELIX_MIN_VERSION=24.07                           minimum acceptable hx version
#   DRY_RUN=1                                         show what would happen only
# ---------------------------------------------------------------------------
set -euo pipefail

REPO="${HELIX_REPO:-https://github.com/ezonius/helix.git}"
BRANCH="${HELIX_BRANCH:-}"
MIN_VERSION="${HELIX_MIN_VERSION:-24.07}"
FONT_FAMILY="${HELIX_FONT:-FiraCode}"
NO_FONT="${NO_FONT:-0}"
SKIP_EDITOR="${SKIP_EDITOR:-0}"
SKIP_DEPS="${SKIP_DEPS:-0}"
DRY_RUN="${DRY_RUN:-0}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
  exit 1
}
# run COMMAND... : execute, or just print when DRY_RUN=1
run() {
  if [ "$DRY_RUN" = 1 ]; then note "[dry-run] $*"; else "$@"; fi
}

version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

# --- who are we installing for? --------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
    TARGET_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  else
    TARGET_USER=""
    TARGET_HOME="$HOME"
  fi
else
  command -v sudo >/dev/null 2>&1 || die "sudo is required (or run as root)"
  SUDO="sudo"
  TARGET_USER=""
  TARGET_HOME="$HOME"
fi

CONFIG_DIR="${HELIX_CONFIG:-${XDG_CONFIG_HOME:-$TARGET_HOME/.config}/helix}"

# --- prerequisites ----------------------------------------------------------
if [ "$SKIP_DEPS" = 1 ]; then
  note "skipping apt (SKIP_DEPS=1)"
else
  command -v apt-get >/dev/null 2>&1 || die "this installer targets apt (Debian/Ubuntu); install git/curl/xz/unzip manually"

  missing=()
  for pkg in git curl ca-certificates tar xz-utils unzip fontconfig; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
      missing+=("$pkg")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    log "apt: installing ${missing[*]}"
    run $SUDO apt-get update -qq
    run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}"
  else
    log "apt: prerequisites already installed"
  fi
fi

# --- helix ----------------------------------------------------------------
# apt's helix is stale on most releases, so the official tarball is preferred.
have_hx=0
if command -v hx >/dev/null 2>&1; then
  current="$(hx --version 2>/dev/null | head -n1 | sed -E 's/^helix[[:space:]]+([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/')"
  if [ -n "$current" ] && version_ge "$current" "$MIN_VERSION"; then
    have_hx=1
    log "helix $current (ok)"
  else
    warn "helix ${current:-?} is older than $MIN_VERSION; installing the official release"
  fi
fi

if [ "$SKIP_EDITOR" = 1 ]; then
  note "keeping the current hx binary (SKIP_EDITOR=1)"
elif [ "$have_hx" -eq 0 ]; then
  case "$(uname -m)" in
    x86_64 | amd64) arch="x86_64" ;;
    aarch64 | arm64) arch="aarch64" ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac

  tag="$(curl -fsSL https://api.github.com/repos/helix-editor/helix/releases/latest \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  [ -n "$tag" ] || die "could not determine the latest Helix release (network or GitHub API rate limit?)"

  asset="helix-${tag}-${arch}-linux.tar.xz"
  log "installing helix ${tag} from ${asset} into /opt/helix"
  tmp="$(mktemp -d)"
  run curl -fsSL "https://github.com/helix-editor/helix/releases/download/${tag}/${asset}" -o "$tmp/helix.tar.xz"
  if [ "$DRY_RUN" = 1 ]; then
    note "[dry-run] extract to /opt/helix, link /usr/local/bin/hx"
  else
    $SUDO rm -rf /opt/helix
    $SUDO mkdir -p /opt
    $SUDO tar -xJf "$tmp/helix.tar.xz" -C /opt
    $SUDO mv "/opt/helix-${tag}-${arch}-linux" /opt/helix
    $SUDO ln -sf /opt/helix/hx /usr/local/bin/hx
  fi
  rm -rf "$tmp"
fi

# --- nerd font -------------------------------------------------------------
if [ "$NO_FONT" = 1 ]; then
  note "skipping Nerd Font ($FONT_FAMILY)"
else
  font_dir="$TARGET_HOME/.local/share/fonts"
  log "installing Nerd Font '$FONT_FAMILY' -> $font_dir"
  tmp="$(mktemp -d)"
  run curl -fsSL "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/${FONT_FAMILY}.zip" -o "$tmp/font.zip"
  if [ "$DRY_RUN" = 1 ]; then
    note "[dry-run] extract *.ttf to $font_dir and run fc-cache -f"
  else
    mkdir -p "$font_dir"
    unzip -o -q "$tmp/font.zip" -d "$tmp/font"
    count=0
    while IFS= read -r -d '' file; do
      cp -f "$file" "$font_dir/"
      count=$((count + 1))
    done < <(find "$tmp/font" -type f \( -iname '*.ttf' -o -iname '*.otf' \) -print0)
    [ "$count" -gt 0 ] || warn "no font files found in ${FONT_FAMILY}.zip"
    if [ -n "$TARGET_USER" ]; then
      chown -R "$TARGET_USER:$TARGET_USER" "$font_dir"
    fi
    if command -v fc-cache >/dev/null 2>&1; then
      fc-cache -f "$font_dir" >/dev/null 2>&1 || warn "fc-cache failed"
    else
      warn "fontconfig not found - run 'fc-cache -f' yourself"
    fi
    log "$count font files installed - pick '${FONT_FAMILY} Nerd Font' in your terminal"
  fi
  rm -rf "$tmp"
fi

# --- configuration ---------------------------------------------------------
if [ -z "$BRANCH" ]; then
  log "detecting the default branch of $REPO"
  BRANCH="$(git ls-remote --symref "$REPO" HEAD 2>/dev/null | sed -n 's|^ref: refs/heads/\([^[:space:]]*\).*|\1|p' | head -n1)"
  [ -n "$BRANCH" ] || BRANCH="master"
fi
log "branch: $BRANCH"

if [ -d "$CONFIG_DIR/.git" ]; then
  log "updating existing clone in $CONFIG_DIR"
  if [ "$DRY_RUN" = 1 ]; then
    note "[dry-run] git pull --ff-only origin $BRANCH"
  else
    if ! git -C "$CONFIG_DIR" pull --ff-only --quiet origin "$BRANCH"; then
      warn "could not fast-forward $CONFIG_DIR - leaving it untouched"
    fi
  fi
else
  if [ -e "$CONFIG_DIR" ]; then
    backup="${CONFIG_DIR}.bak.$(date +%Y%m%d-%H%M%S)"
    log "backing up existing config -> $backup"
    run mv "$CONFIG_DIR" "$backup"
  fi

  log "cloning $REPO ($BRANCH) -> $CONFIG_DIR"
  run mkdir -p "$(dirname "$CONFIG_DIR")"
  run git clone --quiet --depth 1 --branch "$BRANCH" "$REPO" "$CONFIG_DIR"
fi

# config.toml is generated, not hand-edited: rebuild it for this platform so
# the right keys/99-local-*.toml fragment is used.
if [ "$DRY_RUN" = 1 ]; then
  log "generating config.toml from keys/*.toml"
  note "[dry-run] bash $CONFIG_DIR/build-config.sh"
elif [ -f "$CONFIG_DIR/build-config.sh" ]; then
  log "generating config.toml from keys/*.toml"
  chmod +x "$CONFIG_DIR/build-config.sh" 2>/dev/null || true
  if ! bash "$CONFIG_DIR/build-config.sh"; then
    warn "build-config.sh failed - config.toml may be stale"
  fi
else
  warn "no build-config.sh in $CONFIG_DIR - leaving config.toml as committed"
fi

if [ -n "$TARGET_USER" ]; then
  run chown -R "$TARGET_USER:$TARGET_USER" "$CONFIG_DIR"
fi

log "done"
note "config:  $CONFIG_DIR"
note "start:   hx"
note "edit keys/*.toml, then <space>B inside Helix to rebuild and reload"
