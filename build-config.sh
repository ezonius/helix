#!/usr/bin/env bash
# build-config.sh - merge Helix config fragments (keys/*.toml) into one config.toml
#
# Helix reads exactly one config file and has no include mechanism, and TOML
# forbids defining [keys.normal] twice. This script therefore merges the
# fragments itself: every keys/*.toml is read in name order, and the result is
# written as one config.toml. A later fragment wins when two fragments set the
# same key in the same table (reported as "override").
#
# Supported fragment syntax (deliberately small, to stay dependency-free):
#   [table]           dotted and quoted segments, e.g. [keys.normal."+"]
#   key = value       one per line; values are copied verbatim
#   # comment         full-line comments only
#
# Not supported: [[array.of.tables]], multi-line arrays/strings, dotted keys,
# trailing comments after a value.
#
# Usage: ./build-config.sh [-c DIR] [-f DIR] [-n|--check] [-p|--print] [-q]
#
# Requires bash 4+ (associative arrays). No python, no toml library.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: build-config.sh [options]

  -c, --config-dir DIR   Helix config dir (default: $HELIX_CONFIG_DIR,
                         %APPDATA%/helix on Windows, else $XDG_CONFIG_HOME/helix
                         or ~/.config/helix)
  -f, --fragments DIR    fragment dir (default: <config-dir>/keys)
  -P, --platform NAME    pretend to run on windows, linux or macos (default:
                         detected). A fragment may declare `# platform: <list>`
                         and is then only merged when the list matches.
                         Tokens: windows, linux, macos (mac/osx/darwin),
                         unix (linux + macos), all/any/*.
  -n, --check            validate only, write nothing; exit 1 on error
  -p, --print            print the merged config to stdout
  -q, --quiet            only print errors and overrides
  -h, --help             this text
EOF
}

die() { echo "error: $*" >&2; exit 1; }
# diagnostics go to stderr so `--print` can be redirected to a file
note() { [[ $QUIET == 1 ]] || echo "$*" >&2; }
US=$'\x1f'   # internal separator for table paths and key lists
ROOT=$US      # sentinel table id for top-level keys (bash rejects empty subscripts)

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

detect_current_platform() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) printf 'windows' ;;
    Darwin) printf 'macos' ;;
    *) printf 'linux' ;;
  esac
}

# Prints the platforms declared by a `# platform: ...` comment (empty if none).
fragment_platforms() {
  local l
  while IFS= read -r l; do
    if [[ $l =~ ^[[:space:]]*#[[:space:]]*platform[[:space:]]*[:=][[:space:]]*(.+)$ ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
      return 0
    fi
  done < "$1"
  return 0
}

platform_matches() {  # $1 = token list, $2 = fragment name
  local tok
  for tok in ${1//,/ }; do
    tok=${tok,,}
    case $tok in
      windows) if [[ $PLATFORM == windows ]]; then return 0; fi ;;
      linux) if [[ $PLATFORM == linux ]]; then return 0; fi ;;
      macos|mac|osx|darwin) if [[ $PLATFORM == macos ]]; then return 0; fi ;;
      unix) if [[ $PLATFORM == linux || $PLATFORM == macos ]]; then return 0; fi ;;
      all|any|'*') return 0 ;;
      '') ;;
      *) die "$2 : unknown platform '$tok' (use windows, linux, macos, unix or all)" ;;
    esac
  done
  return 1
}

# Order: --config-dir > HELIX_CONFIG_DIR > the directory this script lives in
# (when it contains keys/) > the platform default. The script-dir rule makes a
# clone usable from anywhere, e.g. HELIX_CONFIG=/tmp/helix ./build-config.sh.
resolve_config_dir() {
  if [[ -n ${HELIX_CONFIG_DIR:-} ]]; then printf '%s\n' "$HELIX_CONFIG_DIR"; return; fi
  local self_dir
  self_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || self_dir=""
  if [[ -n $self_dir && -d $self_dir/keys ]]; then printf '%s\n' "$self_dir"; return; fi
  if [[ -n ${APPDATA:-} && ( ${OS:-} == Windows_NT || -n ${MSYSTEM:-} ) ]] && command -v cygpath >/dev/null 2>&1; then
    printf '%s\n' "$(cygpath -u "$APPDATA")/helix"; return
  fi
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/helix"
}

# Splits a leading dotted key (bare or "quoted" segments) off "$1".
# Sets globals _SEGS (array) and _REST.
parse_key_prefix() {
  local s=$1 i=0 n=${#1} c seg start closed
  _SEGS=()
  while :; do
    while [[ $i -lt $n && ${s:$i:1} == ' ' ]]; do i=$((i + 1)); done
    [[ $i -lt $n ]] || die "unexpected end of input while reading a key"
    c=${s:$i:1}
    if [[ $c == '"' ]]; then
      i=$((i + 1)); seg=""; closed=0
      while [[ $i -lt $n ]]; do
        c=${s:$i:1}
        if [[ $c == '\' ]]; then
          [[ $((i + 1)) -lt $n ]] || die "unterminated escape in quoted key"
          seg+=${s:$((i + 1)):1}; i=$((i + 2)); continue
        fi
        if [[ $c == '"' ]]; then i=$((i + 1)); closed=1; break; fi
        seg+=$c; i=$((i + 1))
      done
      [[ $closed == 1 ]] || die "unterminated quoted key"
      _SEGS+=("$seg")
    else
      start=$i
      while [[ $i -lt $n && ${s:$i:1} =~ [A-Za-z0-9_-] ]]; do i=$((i + 1)); done
      [[ $i -gt $start ]] || die "invalid key character '$c'"
      _SEGS+=("${s:$start:$((i - start))}")
    fi
    while [[ $i -lt $n && ${s:$i:1} == ' ' ]]; do i=$((i + 1)); done
    if [[ $i -lt $n && ${s:$i:1} == '.' ]]; then i=$((i + 1)); continue; fi
    break
  done
  _REST=${s:$i}
}

value_ok() {
  local v=$1 i=0 n=${#1} depth=0 instr=0 c
  while [[ $i -lt $n ]]; do
    c=${v:$i:1}
    if [[ $instr == 1 ]]; then
      if [[ $c == '\' ]]; then i=$((i + 2)); continue; fi
      if [[ $c == '"' ]]; then instr=0; fi
      i=$((i + 1)); continue
    fi
    case $c in
      '"') instr=1 ;;
      '[') depth=$((depth + 1)) ;;
      ']') depth=$((depth - 1)); [[ $depth -ge 0 ]] || return 1 ;;
    esac
    i=$((i + 1))
  done
  [[ $depth -eq 0 && $instr -eq 0 ]]
}

quote_key() {
  local k=$1
  if [[ $k =~ ^[A-Za-z0-9_-]+$ ]]; then printf '%s' "$k"; return; fi
  k=${k//\\/\\\\}; k=${k//\"/\\\"}
  printf '"%s"' "$k"
}

# "\x1f"-joined table path -> "a.b.c"
dotted() { printf '%s' "$1" | tr "$US" '.'; }

CONFIG_DIR=""; FRAG_DIR=""; CHECK=0; PRINT=0; QUIET=0; PLATFORM=""
while [[ $# -gt 0 ]]; do
  case $1 in
    -c|--config-dir) [[ $# -ge 2 ]] || die "$1 needs a value"; CONFIG_DIR=$2; shift 2 ;;
    -f|--fragments)  [[ $# -ge 2 ]] || die "$1 needs a value"; FRAG_DIR=$2; shift 2 ;;
    -P|--platform)   [[ $# -ge 2 ]] || die "$1 needs a value"; PLATFORM=$2; shift 2 ;;
    -n|--check)      CHECK=1; shift ;;
    -p|--print)      PRINT=1; shift ;;
    -q|--quiet)      QUIET=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "unknown argument: $1 (try --help)" ;;
  esac
done

[[ -n $CONFIG_DIR ]] || CONFIG_DIR=$(resolve_config_dir)
[[ -n $FRAG_DIR ]] || FRAG_DIR=$CONFIG_DIR/keys
OUT_FILE=$CONFIG_DIR/config.toml

[[ -d $FRAG_DIR ]] || die "fragment directory not found: $FRAG_DIR"

shopt -s nullglob
FRAGMENTS=("$FRAG_DIR"/*.toml)
shopt -u nullglob
[[ ${#FRAGMENTS[@]} -gt 0 ]] || die "no *.toml fragments in $FRAG_DIR"

[[ -n $PLATFORM ]] || PLATFORM=$(detect_current_platform)
case $PLATFORM in
  windows|linux|macos) ;;
  *) die "unknown platform '$PLATFORM' (use windows, linux or macos)" ;;
esac

declare -A TVALUES TSRC THEADER TKEYS TDEPTH TINDEX
TABLE_ORDER=()
OVERRIDES=()
SKIPPED=()

for frag in "${FRAGMENTS[@]}"; do
  frag_name=${frag##*/}
  platforms=$(fragment_platforms "$frag")
  if [[ -n $platforms ]] && ! platform_matches "$platforms" "$frag_name"; then
    SKIPPED+=("$frag_name (platform: $platforms)")
    continue
  fi
  mapfile -t flines < "$frag"
  line_no=0
  current=$ROOT
  for raw in ${flines[@]+"${flines[@]}"}; do
    line_no=$((line_no + 1))
    line=$(trim "$raw")
    [[ -z $line ]] && continue
    [[ $line == '#'* ]] && continue
    where="$frag_name:$line_no"

    if [[ $line == '['* ]]; then
      [[ $line == '[['* ]] && die "$where : [[array.of.tables]] is not supported"
      [[ $line == *']' ]] || die "$where : table header is missing its closing ']'"
      parse_key_prefix "$(trim "${line:1:${#line}-2}")"
      [[ -z $(trim "$_REST") ]] || die "$where : unexpected text after table header: '$_REST'"
      current=""
      for seg in "${_SEGS[@]}"; do current+="${current:+$US}$seg"; done
      if [[ -z ${TDEPTH[$current]+set} ]]; then
        TDEPTH[$current]=${#_SEGS[@]}
        TINDEX[$current]=${#TABLE_ORDER[@]}
        TABLE_ORDER+=("$current")
        THEADER[$current]=""
        for seg in "${_SEGS[@]}"; do THEADER[$current]+="${THEADER[$current]:+$US}$(quote_key "$seg")"; done
        TKEYS[$current]=""
      fi
      continue
    fi

    # top-level key (theme = ...) or key inside the current table
    if [[ -z ${TDEPTH[$current]+set} ]]; then
      TDEPTH[$current]=0
      TINDEX[$current]=${#TABLE_ORDER[@]}
      TABLE_ORDER+=("$current")
      THEADER[$current]=""
      TKEYS[$current]=""
    fi

    parse_key_prefix "$line"
    [[ ${#_SEGS[@]} -eq 1 ]] || die "$where : dotted keys are not supported"
    rest=$(trim "$_REST")
    [[ $rest == '='* ]] || die "$where : expected '=' after the key"
    value=$(trim "${rest:1}")
    [[ -n $value ]] || die "$where : missing value"
    [[ $value != *'"""'* ]] || die "$where : multi-line strings are not supported"
    value_ok "$value" || die "$where : unbalanced quotes or brackets (multi-line values are not supported)"

    key=${_SEGS[0]}
    id=$current$US$key
    if [[ -n ${TVALUES[$id]+set} ]]; then
      OVERRIDES+=("[$(dotted "$current")] $key : ${TSRC[$id]} -> $frag_name")
    else
      TKEYS[$current]+="${TKEYS[$current]:+$US}$key"
    fi
    TVALUES[$id]=$value
    TSRC[$id]=$frag_name
  done
done

for o in ${OVERRIDES[@]+"${OVERRIDES[@]}"}; do note "override  $o"; done
for s in ${SKIPPED[@]+"${SKIPPED[@]}"}; do note "skipped   $s"; done

# --- emit -------------------------------------------------------------------
OUT=()
OUT+=('# Helix configuration - GENERATED FILE, do not edit.')
OUT+=('# Edit the fragments in keys/*.toml, then run:')
OUT+=('#     ./build-config.sh      (Linux/macOS)')
OUT+=('#     .\build-config.ps1     (Windows)')
OUT+=('# and reload with :config-reload inside Helix.')
OUT+=("# generated for platform: $PLATFORM")
OUT+=('')

max_depth=0
for t in "${TABLE_ORDER[@]}"; do
  [[ ${TDEPTH[$t]} -gt $max_depth ]] && max_depth=${TDEPTH[$t]}
done

key_count=0
for ((depth = 0; depth <= max_depth; depth++)); do
  for t in "${TABLE_ORDER[@]}"; do
    [[ ${TDEPTH[$t]} -eq $depth ]] || continue
    [[ -n ${TKEYS[$t]} ]] || continue
    [[ ${#THEADER[$t]} -eq 0 ]] || OUT+=("[$(dotted "${THEADER[$t]}")]")
    IFS=$US read -r -a keys <<< "${TKEYS[$t]}"
    for key in "${keys[@]}"; do
      OUT+=("$(quote_key "$key") = ${TVALUES[$t$US$key]}")
      key_count=$((key_count + 1))
    done
    OUT+=('')
  done
done

# drop the trailing blank line so the output matches build-config.ps1 byte for byte
[[ ${#OUT[@]} -gt 0 && -z ${OUT[-1]} ]] && unset 'OUT[-1]'

if [[ $PRINT == 1 ]]; then
  printf '%s\n' "${OUT[@]}"
  exit 0
fi

if [[ $CHECK == 1 ]]; then
  note "ok: ${#FRAGMENTS[@]} fragments, ${#TABLE_ORDER[@]} tables, $key_count keys - nothing written"
  exit 0
fi

mkdir -p "$CONFIG_DIR"
tmp="$OUT_FILE.tmp.$$"
printf '%s\n' "${OUT[@]}" > "$tmp"
if [[ -f $OUT_FILE ]] && cmp -s "$tmp" "$OUT_FILE"; then
  rm -f "$tmp"
  note "unchanged: $OUT_FILE"
  exit 0
fi
mv -f "$tmp" "$OUT_FILE"
note "wrote $OUT_FILE (${#FRAGMENTS[@]} fragments, $key_count keys)"
