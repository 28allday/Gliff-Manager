#!/bin/sh
# Single-quoted strings here are scripts for the remote shell or filters for
# jq, both meant to expand later, never now.
# shellcheck disable=SC2016

# Gliff-Manager helper. The panel calls this for everything that touches the
# system, so each step can also be run by hand when something looks wrong.
#
#   gliff-manager.sh status fast|full   JSON for the panel (full adds ssh checks)
#   gliff-manager.sh live               JSON: running gliff windows only
#   gliff-manager.sh probe TARGET       JSON: check one machine over ssh
#   gliff-manager.sh connect TARGET     open a gliff window for TARGET
#   gliff-manager.sh disconnect TARGET  close the gliff window(s) for TARGET
#   gliff-manager.sh add TARGET         remember TARGET
#   gliff-manager.sh forget TARGET      hide TARGET from the list
#   gliff-manager.sh set-mode TARGET auto|headless|mirror|output:NAME
#   gliff-manager.sh set-video auto|cpu|gpu
#   gliff-manager.sh hide-peer DNSNAME  stop offering a tailnet machine
#   gliff-manager.sh show-peers         offer every tailnet machine again
#   gliff-manager.sh show-machines      list every hidden machine again
#   gliff-manager.sh short-names on|off show machines in gliff's tabs by short
#                                       name (adds one Include to ~/.ssh/config)
#   gliff-manager.sh fix-session TARGET open a terminal that installs the
#                                       gliff-server session wrapper
#   gliff-manager.sh install TARGET     open a terminal that installs gliff
#   gliff-manager.sh trust TARGET       open a terminal for a first ssh login
#   gliff-manager.sh signin TARGET      open a terminal that logs in once and
#                                       opens Tailscale's sign-in page
#   gliff-manager.sh check TARGET       open a terminal running gliff-probe
#   gliff-manager.sh rescue TARGET [headless|mirror]
#                                       bring back windows stranded by an
#                                       earlier gliff session (run on connect)
#
# TARGET is user@host, as gliff takes it.

set -u

CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
CACHE_HOME=${XDG_CACHE_HOME:-$HOME/.cache}
PREFS=$CONFIG_HOME/gliff-manager/machines.json
PROBES=$CACHE_HOME/gliff-manager/probes
GLIFF_CONFIG=$CONFIG_HOME/gliff/config.toml
NAMES_CONF=$CONFIG_HOME/gliff-manager/ssh_config
NAMES_MAP=$CONFIG_HOME/gliff-manager/names.json
NAMES_SESSIONS=$CACHE_HOME/gliff-manager/name-sessions.json
SSH_CONFIG=$HOME/.ssh/config
SSH_SYSTEM_CONFIG=/etc/ssh/ssh_config
INCLUDE_MARK='# Added by Gliff-Manager: short machine names for gliff tabs'

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=6 -o ServerAliveInterval=5 -o ServerAliveCountMax=2"
# What Tailscale SSH prints when its policy is in "check" mode and the last
# browser sign-in has run out. The login then waits, with no prompt, until
# someone approves it in a browser.
TS_CHECK_TEXT='Tailscale SSH requires an additional check'

# Ceilings. The panel runs inside the desktop shell, so nothing it reads or
# lists may grow without bound.
PREFS_CAP=262144        # bytes: machines.json, names.json, name-sessions.json
PROBE_CAP=16384         # bytes: one machine's check, as sent and as cached
TEXT_CAP=1048576        # bytes: gliff's config.toml and ~/.ssh/config
MAX_MACHINES=64         # machines listed and checked
MAX_PEERS=32            # tailnet suggestions
MAX_HIDDEN_PEERS=256    # tailnet machines remembered as hidden
PROBE_PARALLEL=8        # ssh checks running at once

die() { printf 'gliff-manager: %s\n' "$*" >&2; exit 1; }

# One bounded read of a JSON object: prints it compacted, or fails if the file
# is missing, larger than the cap, not JSON, or not an object. Never check a
# file and then read it again; what is printed is what was checked.
read_small_json() { # <path> <max-bytes>
  [ -f "$1" ] || return 1
  _data=$(head -c "$(($2 + 1))" "$1" 2>/dev/null) || return 1
  [ "$(printf '%s' "$_data" | wc -c)" -le "$2" ] || return 1
  printf '%s' "$_data" | jq -ce 'if type == "object" then . else error("not an object") end' 2>/dev/null
}

# Copy a text file the user owns into one of ours, failing (rather than
# truncating) if it is larger than the cap. Later steps read only the copy.
bounded_copy() { # <src> <dst> <max-bytes>
  head -c "$(($3 + 1))" "$1" >"$2" 2>/dev/null || return 1
  [ "$(wc -c <"$2")" -le "$3" ]
}

# user@host only, and never starting with "-", so a target can't smuggle an
# ssh option or a shell word into any command below.
valid_target() {
  printf '%s' "$1" | grep -Eqx '([A-Za-z0-9._-]+@)?[A-Za-z0-9][A-Za-z0-9._-]*'
}

need_target() {
  [ $# -ge 1 ] || die "missing user@host"
  valid_target "$1" || die "not a user@host: $1"
}

slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._@-' '_'; }

# --------------------------------------------------------------- preferences

prefs_read() {
  read_small_json "$PREFS" "$PREFS_CAP" || printf '{}'
}

# Apply a jq filter to the prefs file and replace it atomically. A settings
# file that exists but cannot be read is an error, never a fresh start: that
# would silently throw away every saved machine.
prefs_update() {
  if [ -e "$PREFS" ]; then
    current=$(read_small_json "$PREFS" "$PREFS_CAP") ||
      die "$PREFS is unreadable or larger than $PREFS_CAP bytes; fix or remove it"
  else
    current='{}'
  fi
  mkdir -p "${PREFS%/*}" || die "cannot create ${PREFS%/*}"
  tmp=$(mktemp "${PREFS%/*}/.machines.XXXXXX") || die "cannot write prefs"
  if printf '%s' "$current" | jq "$@" >"$tmp"; then
    mv -f "$tmp" "$PREFS"
  else
    rm -f "$tmp"
    die "could not update prefs"
  fi
}

# The machines gliff itself remembers: the `machines` array of its config,
# which may be written on one line or spread over several.
gliff_machines() {
  [ -r "$GLIFF_CONFIG" ] || return 0
  head -c "$TEXT_CAP" "$GLIFF_CONFIG" | awk '
    /^[[:space:]]*(machines|recent_machines)[[:space:]]*=/ { on = 1 }
    on { print; if (index($0, "]")) on = 0 }
  ' | grep -o '"[^"]*"' | tr -d '"'
}

# gliff reconnects every machine in `open` when it starts, with the flags of
# the launch that started it. That is how a window gets several tabs, so the
# list is written to exactly the machines the next window should hold.
gliff_set_open() { gliff_set_list open "$@"; }

# Replace one string array in gliff's config.toml, or add it.
gliff_set_list() {
  key=$1
  shift
  list=$(for t in "$@"; do printf '"%s", ' "$t"; done)
  line="$key = [${list%, }]"
  mkdir -p "${GLIFF_CONFIG%/*}" || return 1
  tmp=$(mktemp "${GLIFF_CONFIG%/*}/.config.XXXXXX") || return 1
  if [ -r "$GLIFF_CONFIG" ]; then
    bounded_copy "$GLIFF_CONFIG" "$tmp.src" "$TEXT_CAP" &&
    awk -v key="$key" -v line="$line" '
      !skip && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
        print line; done = 1
        if (!index($0, "]")) skip = 1
        next
      }
      skip { if (index($0, "]")) skip = 0; next }
      { print }
      END { if (!done) print line }
    ' "$tmp.src" >"$tmp"
  else
    printf '%s\n' "$line" >"$tmp"
  fi || { rm -f "$tmp" "$tmp.src"; return 1; }
  rm -f "$tmp.src"
  mv -f "$tmp" "$GLIFF_CONFIG"
}

# --------------------------------------------------------------- short names
#
# gliff names a tab after exactly what it connects to, so me@studio.example.net
# shows in full. With short names on, each machine gets an ssh Host alias
# (studio → HostName studio.example.net, User me) in a file of our own, which one
# Include line at the top of ~/.ssh/config brings in. gliff is then given the
# alias, and the tab reads "studio". Being in ssh's own config, the alias works
# for a gliff opened from the launcher, and for plain `ssh studio`, too.

short_names_on() { prefs_read | jq -e '.shortNames == true' >/dev/null 2>&1; }

# {alias: target} for the aliases in use, or {} with short names off.
names_map() {
  if short_names_on; then
    read_small_json "$NAMES_MAP" "$PREFS_CAP" || printf '{}'
  else
    printf '{}'
  fi
}

# What gliff is given for a target: its alias, or the target itself.
display_name() {
  names_map | jq -r --arg t "$1" '[ to_entries[] | select(.value == $t) | .key ] | first // $t'
}

# Copy ~/.ssh/config to <dst> (empty if there is none). A config over the cap
# is refused rather than truncated: the copy may be written back.
ssh_config_copy() { # <dst>
  if [ -e "$SSH_CONFIG" ]; then
    bounded_copy "$SSH_CONFIG" "$1" "$TEXT_CAP" ||
      die "$SSH_CONFIG is unreadable or larger than $TEXT_CAP bytes"
  else
    : >"$1"
  fi
}

# Strip just our managed Include from a copy of the ssh config.
ssh_config_without_names() { # <copy>
  awk -v mark="$INCLUDE_MARK" '
    $0 == mark { drop = 2; next }
    drop == 2 && /^Include / { drop = 1; next }
    drop == 1 && /^[[:space:]]*$/ { drop = 0; next }
    { drop = 0; print }
  ' "$1"
}

# Ask OpenSSH itself to follow Includes, globs, quoting and Host patterns.
# A specific matching Host block belongs to the user, even without HostName.
# Match rules can depend on runtime state, so leave those names alone too.
user_has_host() {
  LC_ALL=C timeout 5 ssh -G -vv -- "$1" >"$2/alias" 2>"$2/debug" || return 0
  awk -v managed="$NAMES_CONF line " '
    /Applying options for / {
      if (index($0, managed)) next
      sub(/^.*Applying options for /, "")
      sub(/[[:space:]]+$/, "")
      if ($0 != "*") owned = 1
    }
    /checking match for/ { owned = 1 }
    END { exit !owned }
  ' "$2/debug"
}

# A cosmetic name must not change ports, keys, proxies, or any other SSH
# option. Fall back to the full target when the effective configs differ.
alias_compatible() (
  alias=$1 target=$2 dir=$3
  {
    printf 'Host %s\n  HostName %s\n' "$alias" "${target#*@}"
    case $target in *@*) printf '  User %s\n' "${target%%@*}" ;; esac
    printf 'Host *\nInclude "%s/user"\n' "$dir"
  } >"$dir/candidate"
  LC_ALL=C timeout 5 ssh -G -vv -- "$target" >"$dir/target" 2>"$dir/target-debug" || exit 1
  LC_ALL=C timeout 5 ssh -G -vv -F "$dir/candidate" -- "$alias" >"$dir/alias" 2>"$dir/alias-debug" || exit 1
  # These tokens depend on the original command-line name, even when -G
  # prints identical unexpanded values. Dynamic Match rules are also unsafe.
  grep -Eq '%[nk]' "$dir/target" "$dir/alias" && exit 1
  grep -q 'checking match for' "$dir/target-debug" "$dir/alias-debug" && exit 1
  sed '/^host /d' "$dir/target" >"$dir/target-options"
  sed '/^host /d' "$dir/alias" >"$dir/alias-options"
  cmp -s "$dir/target-options" "$dir/alias-options"
)

# Keep identities for windows already launched with an alias. The process
# start time prevents a later process reusing the PID from inheriting it.
process_key() {
  [ -r "/proc/$1/stat" ] || return 1
  awk -v pid="$1" '{ sub(/^.*\) /, ""); print pid ":" $20 }' "/proc/$1/stat"
}

names_sessions() {
  read_small_json "$NAMES_SESSIONS" "$PREFS_CAP" || printf '{}'
}

names_identity_map() {
  names_sessions | jq --argjson map "$(names_map)" '[.[]] | add // {} | . + $map'
}

names_capture_live() (
  mkdir -p "${NAMES_SESSIONS%/*}" || exit 1
  tmp=$(mktemp "${NAMES_SESSIONS%/*}/.names.XXXXXX") || exit 1
  gliff_procs | jq -r '.[].pid' | while read -r pid; do process_key "$pid"; done |
    jq -R -s --argjson previous "$(names_sessions)" --argjson map "$(names_map)" '
      split("\n") | map(select(length > 0))
      | map(. as $key | {($key): ($map + ($previous[$key] // {}))}) | add // {}' >"$tmp" &&
    mv -f "$tmp" "$NAMES_SESSIONS"
)

# Work out an alias per machine (the host's first label) and write the ssh
# config and the map. A name two machines would share, or one the user's own
# config defines, is left out, and that machine keeps its full name.
names_build() (
  mkdir -p "${NAMES_MAP%/*}" || die "cannot create ${NAMES_MAP%/*}"
  old=$(names_identity_map)
  names_capture_live || die "cannot save active window identities"
  gliff_rewrite_names "$old" '{}' || die "cannot preserve gliff's machine names"
  dir=$(mktemp -d "${NAMES_MAP%/*}/.names.XXXXXX") || die "mktemp failed"
  trap 'rm -rf "$dir"' EXIT HUP INT TERM
  ssh_config_copy "$dir/current"
  ssh_config_without_names "$dir/current" >"$dir/user"
  # -F replaces both default config files, so include system defaults too.
  printf '\nHost *\nInclude "%s"\n' "$SSH_SYSTEM_CONFIG" >>"$dir/user"
  reserved=$(names_identity_map)
  hidden=$(prefs_read | jq -r '.machines // {} | to_entries[] | select(.value.hidden == true) | .key')
  pairs=$(machine_targets | head -n "$MAX_MACHINES" | while IFS= read -r t; do
      printf '%s\n' "$hidden" | grep -qxF -- "$t" && continue
      host=${t#*@}
      alias=$(printf '%s' "${host%%.*}" | tr '[:upper:]' '[:lower:]')
      printf '%s' "$alias" | grep -Eqx '[a-z0-9][a-z0-9-]*' || continue
      [ "$alias" = "$t" ] && continue
      printf '%s\t%s\n' "$alias" "$t"
    done | awk -F'\t' '{ n[$1]++; line[NR] = $0; a[NR] = $1 } END { for (i = 1; i <= NR; i++) if (n[a[i]] == 1) print line[i] }' |
    while IFS="$(printf '\t')" read -r alias t; do
      # Do not reuse an alias still identifying a different live session.
      printf '%s' "$reserved" | jq -e --arg a "$alias" --arg t "$t" \
        '.[$a] != null and .[$a] != $t' >/dev/null && continue
      user_has_host "$alias" "$dir" && continue
      alias_compatible "$alias" "$t" "$dir" || continue
      printf '%s\t%s\n' "$alias" "$t"
    done)
  map=$(printf '%s\n' "$pairs" | jq -R -s '
    split("\n") | map(select(length > 0) | split("\t") | { (.[0]): .[1] }) | add // {}')
  tmp=$dir/ssh_config
  {
    echo "# Written by Gliff-Manager from its machine list; changes here are"
    echo "# overwritten. Turn short names off in Gliff-Manager to remove it."
    printf '%s\n' "$pairs" | while IFS="$(printf '\t')" read -r alias t; do
      [ -n "$alias" ] || continue
      echo
      echo "Host $alias"
      echo "  HostName ${t#*@}"
      case $t in *@*) echo "  User ${t%%@*}" ;; esac
    done
  } >"$tmp" || { rm -f "$tmp"; die "cannot write $NAMES_CONF"; }
  mv -f "$tmp" "$NAMES_CONF" || die "cannot write $NAMES_CONF"
  if ! { printf '%s' "$map" | jq '.' >"$dir/map" && mv -f "$dir/map" "$NAMES_MAP"; }; then
    die "cannot write $NAMES_MAP"
  fi
  gliff_rewrite_names '{}' "$map" || die "cannot update gliff's machine names"
)

names_sync() {
  if short_names_on; then names_build; fi
}

# Migrate every saved reference together, including the reopen list and the
# selected tab. First resolve old aliases, then apply the new display names.
gliff_rewrite_names() (
  [ -r "$GLIFF_CONFIG" ] || return 0
  dir=$(mktemp -d "${GLIFF_CONFIG%/*}/.rename.XXXXXX") || exit 1
  trap 'rm -rf "$dir"' EXIT HUP INT TERM
  bounded_copy "$GLIFF_CONFIG" "$dir/src" "$TEXT_CAP" || exit 1
  jq -n -r --argjson old "$1" --argjson new "$2" '
    ($new | to_entries | map({(.value): .key}) | add // {}) as $display
    | ($old + ($display | with_entries(.value = .key))) | to_entries[]
    | [.key, ($display[.value] // .value)] | @tsv' >"$dir/map" || exit 1
  awk -F'\t' '
    FILENAME == ARGV[1] { names[$1] = $2; next }
    function rename(value) { return value in names ? names[value] : value }
    function array(    value, result, sep, seen) {
      while (match(buffer, /"[^"]*"/)) {
        value = rename(substr(buffer, RSTART + 1, RLENGTH - 2))
        buffer = substr(buffer, RSTART + RLENGTH)
        if (!seen[value]++) { result = result sep "\"" value "\""; sep = ", " }
      }
      print key " = [" result "]"
    }
    /^[[:space:]]*(machines|recent_machines|open)[[:space:]]*=/ {
      key = $0; sub(/=.*/, "", key); gsub(/[[:space:]]/, "", key)
      buffer = ""; collecting = 1
    }
    collecting {
      buffer = buffer $0
      if (index($0, "]")) { array(); collecting = 0 }
      next
    }
    /^[[:space:]]*shown[[:space:]]*=/ {
      if (match($0, /"[^"]*"/)) {
        print "shown = \"" rename(substr($0, RSTART + 1, RLENGTH - 2)) "\""
        next
      }
    }
    { print }
    END { if (collecting) exit 1 }
  ' "$dir/map" "$dir/src" >"$dir/config" && mv -f "$dir/config" "$GLIFF_CONFIG"
)

# Replace the ssh config atomically, so a failure never leaves it half
# written. A symlinked config (dotfiles) stays a symlink: the file it points
# to is replaced, keeping its permissions.
ssh_config_write() { # <content-file>
  real=$SSH_CONFIG
  if [ -L "$SSH_CONFIG" ]; then real=$(readlink -f -- "$SSH_CONFIG") || return 1; fi
  wtmp=$(mktemp "${real%/*}/.config.gliff-manager.XXXXXX") || return 1
  if { if [ -e "$real" ]; then chmod --reference="$real" "$wtmp"; else chmod 600 "$wtmp"; fi; } &&
    cat "$1" >"$wtmp" && mv -f "$wtmp" "$real"; then
    return 0
  fi
  rm -f "$wtmp"
  return 1
}

short_names_enable() {
  prefs_update '.shortNames = true'
  if ! names_build; then
    prefs_update '.shortNames = false'
    die "cannot build short names"
  fi
  if [ ! -d "${SSH_CONFIG%/*}" ]; then
    mkdir -p "${SSH_CONFIG%/*}" || die "cannot create ${SSH_CONFIG%/*}"
    chmod 700 "${SSH_CONFIG%/*}"
  fi
  if ! grep -qxF "$INCLUDE_MARK" "$SSH_CONFIG" 2>/dev/null; then
    # At the very top: an Include after a Host block would only apply inside
    # that block.
    tmp=$(mktemp -d) || die "mktemp failed"
    ssh_config_copy "$tmp/current"
    if ! { { printf '%s\nInclude "%s"\n\n' "$INCLUDE_MARK" "$NAMES_CONF"
             cat "$tmp/current"; } >"$tmp/new" && ssh_config_write "$tmp/new"; }; then
      rm -rf "$tmp"; die "cannot write $SSH_CONFIG"
    fi
    rm -rf "$tmp"
  fi
  # Check ssh reads it, and back out rather than leave ssh broken.
  map=$(names_map)
  alias=$(printf '%s' "$map" | jq -r 'keys[0] // empty')
  if [ -n "$alias" ]; then
    want=$(printf '%s' "$map" | jq -r --arg a "$alias" '.[$a] | sub("^[^@]*@"; "")')
    got=$(timeout 5 ssh -G -- "$alias" 2>/dev/null | awk '$1 == "hostname" { print $2; exit }')
    if [ "$got" != "$want" ]; then
      short_names_disable
      die "ssh did not pick up the short names, so they are switched off again"
    fi
  fi
}

short_names_disable() (
  map=$(names_identity_map)
  names_capture_live || die "cannot save active window identities"
  gliff_rewrite_names "$map" '{}' || die "cannot preserve gliff's machine names"
  if [ -r "$SSH_CONFIG" ] && grep -qxF "$INCLUDE_MARK" "$SSH_CONFIG"; then
    tmp=$(mktemp -d) || die "mktemp failed"
    ssh_config_copy "$tmp/current"
    if ! { ssh_config_without_names "$tmp/current" >"$tmp/new" && ssh_config_write "$tmp/new"; }; then
      rm -rf "$tmp"; die "cannot write $SSH_CONFIG"
    fi
    rm -rf "$tmp"
  fi
  rm -f "$NAMES_CONF" "$NAMES_MAP"
  prefs_update '.shortNames = false'
)

# ------------------------------------------------------------ this computer

# Display controllers by PCI vendor id. NVIDIA alongside anything else means
# gliff's GPU decode can land on the other chip while NVIDIA draws the
# desktop, and the hand-off between them shows a black picture.
gpu_vendors() {
  command -v lspci >/dev/null 2>&1 || return 0
  { lspci -mm -n -d ::0300; lspci -mm -n -d ::0302; } 2>/dev/null |
    awk -F'"' '{ print $4 }' | sort -u
}

gpu_names() {
  command -v lspci >/dev/null 2>&1 || return 0
  { lspci -mm -d ::0300; lspci -mm -d ::0302; } 2>/dev/null |
    awk -F'"' '{ print $4 }' |
    sed -e 's/^Advanced Micro Devices.*/AMD/' -e 's/^NVIDIA.*/NVIDIA/' \
        -e 's/^Intel.*/Intel/' -e 's/^Apple.*/Apple/' | sort -u
}

local_json() {
  vendors=$(gpu_vendors)
  hybrid=false
  if printf '%s\n' "$vendors" | grep -qx 10de && [ "$(printf '%s\n' "$vendors" | grep -c .)" -gt 1 ]; then
    hybrid=true
  fi
  ver=$(pacman -Q gliff 2>/dev/null | awk '{ print $2 }')
  pref=$(prefs_read | jq -r '.video // "auto"')
  jq -n \
    --arg version "$ver" \
    --argjson hybrid "$hybrid" \
    --arg gpus "$(gpu_names | paste -sd '+' | sed 's/+/ + /g')" \
    --arg pref "$pref" \
    --arg env "${GLIFF_VIDEO:-}" \
    --argjson short "$(prefs_read | jq '.shortNames == true')" \
    '{ installed: ($version != ""), version: $version, hybrid: $hybrid,
       gpus: $gpus, video: $pref, envVideo: $env, shortNames: $short,
       effectiveVideo: (if $pref != "auto" then $pref
                        elif $hybrid then "cpu"
                        elif $env != "" then $env
                        else "gpu" end) }'
}

# The video flag a launch needs, or nothing to leave gliff's own choice.
video_flag() {
  pref=$(prefs_read | jq -r '.video // "auto"')
  case $pref in
    cpu|gpu) printf -- '--video %s' "$pref" ;;
    *)
      v=$(gpu_vendors)
      if printf '%s\n' "$v" | grep -qx 10de && [ "$(printf '%s\n' "$v" | grep -c .)" -gt 1 ]; then
        printf -- '--video cpu'
      fi
      ;;
  esac
}

# Running gliff processes as [{pid, host, mode}], read from /proc so arguments
# with spaces (a --server-bin command) stay intact. `host` is the machine named
# on the command line, which gliff shows first.
gliff_procs() {
  for pid in $(pgrep -u "$(id -u)" -x gliff 2>/dev/null); do
    [ -r "/proc/$pid/cmdline" ] || continue
    tr '\0' '\n' <"/proc/$pid/cmdline" | awk -v pid="$pid" '
      NR == 1 { next }
      skip { skip = 0; if (prev == "--output") out = $0; next }
      /^--(server-bin|output|release-hotkey|video|connect)$/ { skip = 1; prev = $0; next }
      /^--headless$/ { headless = 1; next }
      /^-/ { next }
      { host = $0 }
      END {
        mode = headless ? "headless" : (out != "" && out != "auto" ? "output:" out : "mirror")
        printf "%s\t%s\t%s\n", pid, host, mode
      }'
  done | jq -R -s '
    split("\n") | map(select(length > 0) | split("\t")
      | { pid: (.[0] | tonumber), host: .[1], mode: .[2] })'
}

# The machine an ssh command line connects to: the first argument that is not
# an option or an option's value.
ssh_host() {
  tr '\0' '\n' <"/proc/$1/cmdline" 2>/dev/null | awk '
    NR == 1 { next }
    skip { skip = 0; next }
    /^-[BbcDEeFIiJLlmOoPpQRSWw]$/ { skip = 1; next }
    /^-/ { next }
    { print; exit }'
}

# Connected machines as [{pid, target, mode}]: one entry per ssh session a
# gliff window is running, which is exactly its live tabs. A tab stopped by
# hand inside gliff ends its ssh, so it drops out here too.
live_json() {
  procs=$(gliff_procs)
  printf '%s' "$procs" | jq -r '.[] | "\(.pid)\t\(.mode)"' |
    while IFS="$(printf '\t')" read -r pid mode; do
      identity=$(process_key "$pid") || continue
      for child in $(pgrep -P "$pid" -x ssh 2>/dev/null); do
        host=$(ssh_host "$child")
        [ -n "$host" ] && printf '%s\t%s\t%s\t%s\n' "$pid" "$host" "$mode" "$identity"
      done
    done | jq -R -s --argjson map "$(names_map)" --argjson sessions "$(names_sessions)" '
      split("\n") | map(select(length > 0) | split("\t")
        | { pid: (.[0] | tonumber), target: ($sessions[.[3]][.[1]] // $map[.[1]] // .[1]), mode: .[2] }) | unique'
}

# ------------------------------------------------------------------- probing

# Runs on the remote machine under `sh -s`, in the same kind of session gliff
# gets: a non-interactive ssh login. Output is key=value lines.
REMOTE_PROBE='
uid=$(id -u)
echo "user=$(id -un)"
echo "uid=$uid"
echo "arch=$(uname -m)"
case " $(id -nG) " in *" wheel "*) echo admin=1 ;; *) echo admin=0 ;; esac
if command -v omarchy >/dev/null 2>&1; then
  echo "omarchy=$(omarchy version 2>/dev/null | head -n 1)"
fi
if command -v pacman-conf >/dev/null 2>&1; then
  srv=$(pacman-conf --repo omarchy Server 2>/dev/null | head -n 1)
  if [ -n "$srv" ]; then
    echo "channel=$(basename "$(dirname "$srv")")"
    echo "repo_usage=$(pacman-conf --repo omarchy Usage 2>/dev/null | tr "\n" " ")"
  fi
fi
v=$(pacman -Q gliff 2>/dev/null) && echo "gliff=${v#gliff }"
srvbin=$(command -v gliff-server 2>/dev/null)
echo "server=$srvbin"
wrapped=0
if [ -n "$srvbin" ] && [ "$srvbin" != /usr/bin/gliff-server ] &&
   head -c 4096 "$srvbin" 2>/dev/null | grep -q XDG_RUNTIME_DIR; then
  wrapped=1
fi
echo "wrapped=$wrapped"
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then echo xdg=1; else echo xdg=0; fi
echo "hypr_owner=$(ps -o user= -C Hyprland 2>/dev/null | head -n 1 | tr -d " ")"
if [ -d "/run/user/$uid/hypr" ]; then echo session=1; else echo session=0; fi
n=0
outs=""
for s in /sys/class/drm/card*-*/status; do
  [ -r "$s" ] || continue
  [ "$(cat "$s")" = connected ] || continue
  c=${s%/status}
  c=${c##*/}
  c=${c#card*-}
  outs="$outs $c"
  n=$((n + 1))
done
echo "displays=$n"
echo "outputs=${outs# }"
'

probe_one() {
  target=$1
  pdir=$(mktemp -d) || die "mktemp failed"
  # Both streams from the remote are capped: stdout in the pipe, stderr
  # through a fifo, whose reader must be started first (opening a fifo for
  # writing waits for one). The ssh status is kept apart from the cap's.
  mkfifo "$pdir/err" || { rm -rf "$pdir"; die "mkfifo failed"; }
  tail -c 4096 <"$pdir/err" >"$pdir/reason" &
  tailpid=$!
  # shellcheck disable=SC2086
  out=$( { printf '%s' "$REMOTE_PROBE" | timeout 15 ssh $SSH_OPTS -- "$target" sh -s 2>"$pdir/err"
           echo $? >"$pdir/rc"; } | head -c "$PROBE_CAP")
  wait "$tailpid"
  rc=$(cat "$pdir/rc" 2>/dev/null)
  case $rc in ''|*[!0-9]*) rc=1 ;; esac
  reason=$(head -c 2000 "$pdir/reason" | tr '\n' ' ')
  rm -rf "$pdir"

  reach=ok
  if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    case $reason in
      *"$TS_CHECK_TEXT"*) reach=tailscale-check ;;
      *"tailnet policy does not permit"*|*"Permission denied"*) reach=denied ;;
      *"REMOTE HOST IDENTIFICATION HAS CHANGED"*) reach=hostkey-changed ;;
      *"Host key verification failed"*|*"No ED25519 host key"*|*"host key"*) reach=hostkey ;;
      *) reach=offline ;;
    esac
  fi

  printf '%s\n' "$out" | jq -R -s \
    --arg target "$target" --arg reach "$reach" --arg reason "$reason" \
    --arg checked "$(date +%s)" '
    (split("\n") | map(select(test("^[a-z_]+=")) | capture("^(?<k>[a-z_]+)=(?<v>.*)$"))
      | map({ (.k): (.v | .[0:200]) }) | add // {}) as $r
    | { target: $target, reach: $reach,
        reason: (if $reach == "ok" then "" else ($reason | .[0:300]) end),
        checked: ($checked | tonumber),
        user: ($r.user // ""), uid: ($r.uid // ""), arch: ($r.arch // ""),
        admin: (($r.admin // "0") == "1"),
        omarchy: ($r.omarchy // ""), channel: ($r.channel // ""),
        repoNoInstall: (($r.repo_usage // "All") | test("All|Install") | not),
        gliff: ($r.gliff // ""), server: ($r.server // ""),
        wrapped: (($r.wrapped // "0") == "1"),
        xdg: (($r.xdg // "0") == "1"),
        hyprOwner: ($r.hypr_owner // ""),
        session: (($r.session // "0") == "1"),
        displays: (($r.displays // "0") | tonumber? // 0),
        outputs: (($r.outputs // "") | split(" ") | map(select(length > 0)) | .[0:16]) }'
}

# The last check of a machine, from the cache.
probe_read() { read_small_json "$PROBES/$(slug "$1").json" "$PROBE_CAP"; }

probe_cached() {
  mkdir -p "$PROBES" || die "cannot create $PROBES"
  f=$PROBES/$(slug "$1").json
  tmp=$(mktemp "$PROBES/.probe.XXXXXX") || die "mktemp failed"
  if probe_one "$1" >"$tmp" && result=$(read_small_json "$tmp" "$PROBE_CAP"); then
    mv -f "$tmp" "$f"
    printf '%s\n' "$result"
  else
    rm -f "$tmp"
    return 1
  fi
}

# ---------------------------------------------------------------- the list

machine_targets() {
  map=$(names_identity_map)
  { gliff_machines | jq -R -r --argjson map "$map" '$map[.] // .'
    prefs_read | jq -r '.machines // {} | keys[]'; } |
    while IFS= read -r t; do
      valid_target "$t" && printf '%s\n' "$t"
    done | awk '!seen[$0]++'
}

# Online Linux peers on the tailnet, by their full MagicDNS name: a bare short
# name can resolve somewhere else entirely through the DNS search path.
suggestions_json() {
  if ! command -v tailscale >/dev/null 2>&1; then printf '[]'; return; fi
  # A tailnet can be large: the answer is size-capped, and anything cut short
  # fails to parse and counts as no suggestions.
  suggestions=$(timeout 5 tailscale status --json 2>/dev/null | head -c "$TEXT_CAP" | jq -ce '
    [ (.Peer // {})[]
      | select(.Online == true and ((.OS // "") | ascii_downcase) == "linux")
      | { name: (.HostName // "" | .[0:100]), dns: ((.DNSName // "") | rtrimstr(".") | .[0:253]),
          tailscaleSsh: (.sshHostKeys != null) }
      | select(.dns != "") ] | sort_by(.dns)' 2>/dev/null) || suggestions='[]'
  printf '%s' "$suggestions"
}

status_json() {
  depth=$1
  all=$(machine_targets)
  targets=$(printf '%s\n' "$all" | head -n "$MAX_MACHINES")
  total=$(printf '%s\n' "$all" | grep -c .)
  probes='[]'
  if [ "$depth" = full ] && [ -n "$targets" ]; then
    dir=$(mktemp -d) || die "mktemp failed"
    i=0
    for t in $targets; do
      i=$((i + 1))
      probe_cached "$t" >"$dir/$i.json" 2>/dev/null &
      [ $((i % PROBE_PARALLEL)) -eq 0 ] && wait
    done
    wait
    probes=$(cat "$dir"/*.json 2>/dev/null | jq -s '.')
    rm -rf "$dir"
  elif [ -n "$targets" ]; then
    # The fast pass reuses earlier probes so rows paint with real detail.
    probes=$(for t in $targets; do probe_read "$t"; done | jq -s '.')
  fi
  printf '%s\n' "$targets" | jq -R -s \
    --argjson total "$total" \
    --argjson maxPeers "$MAX_PEERS" \
    --argjson prefs "$(prefs_read)" \
    --argjson probes "${probes:-[]}" \
    --argjson live "$(live_json)" \
    --argjson local "$(local_json)" \
    --argjson suggestions "$(suggestions_json)" \
    --arg depth "$depth" '
    (split("\n") | map(select(length > 0))) as $targets
    | ($probes | map({ (.target): . }) | add // {}) as $byTarget
    | { depth: $depth, local: $local,
        machines: [ $targets[]
          | . as $t
          | select(($prefs.machines[$t].hidden // false) | not)
          | { target: $t,
              mode: ($prefs.machines[$t].mode // "auto"),
              probe: ($byTarget[$t] // null),
              live: [ $live[] | select(.target == $t) ] } ],
        moreMachines: ($total - ($targets | length) | if . < 0 then 0 else . end),
        others: [ $live[] | select(.target as $x | $targets | index($x) | not) ],
        suggestions: ([ $suggestions[]
          | .dns as $d
          | select([ $targets[] | sub("^[^@]*@"; "") ] | index($d) | not)
          | select(($prefs.hiddenPeers // []) | index($d) | not) ] | .[0:$maxPeers]),
        hiddenPeers: (($prefs.hiddenPeers // []) | length),
        hiddenMachines: ([ $targets[] | select($prefs.machines[.].hidden // false) ] | length) }'
}

# ------------------------------------------------------------------ actions

# Pick the remote session mode for a launch: headless when the machine has no
# display attached, mirror when it has one.
resolve_mode() {
  target=$1
  mode=$(prefs_read | jq -r --arg t "$target" '.machines[$t].mode // "auto"')
  if [ "$mode" = auto ]; then
    probe=$(probe_read "$target" || probe_cached "$target" 2>/dev/null)
    displays=$(printf '%s' "$probe" | jq -r '.displays // 0 | floor' 2>/dev/null)
    case $displays in ''|*[!0-9]*) displays=0 ;; esac
    if [ "$displays" -gt 0 ]; then mode=mirror; else mode=headless; fi
  fi
  printf '%s' "$mode"
}

# Works on any remote whatever its user id: fills in XDG_RUNTIME_DIR when the
# ssh session has none, then runs the server. ssh hands it to the remote login
# shell, and the single quotes keep that shell from reading the script itself.
ENV_SERVER_BIN='sh -c '"'"': "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"; export XDG_RUNTIME_DIR; exec gliff-server "$@"'"'"' gliff-server'

needs_env_server() {
  probe_read "$1" | jq -e '.reach == "ok" and (.xdg | not) and (.wrapped | not)' >/dev/null 2>&1
}

# Close a gliff window and wait for it to go, so its sessions are down before
# a new window reconnects them.
close_window() {
  kill "$1" 2>/dev/null || return 0
  i=0
  while kill -0 "$1" 2>/dev/null && [ $i -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
}

# Open one gliff window holding every target given, the last one shown first,
# all in one mode.
launch_window() {
  mode=$1
  shift
  command -v gliff >/dev/null 2>&1 || die "gliff is not installed on this computer"
  [ $# -gt 0 ] || return 0
  # Everything but the last target goes in gliff's reopen list; the last is
  # named on the command line, which gliff shows.
  last=""
  rest=""
  env_server=0
  names_sync || die "cannot update short names"
  all="$*"
  case $mode in headless) rescue_mode=headless ;; *) rescue_mode=mirror ;; esac
  for t in "$@"; do
    [ -n "$last" ] && rest="$rest $last"
    last=$(display_name "$t")
    needs_env_server "$t" && env_server=1
  done
  # shellcheck disable=SC2086
  gliff_set_open $rest || die "cannot write gliff's config"

  set -- --release-hotkey shift+escape
  case $mode in
    headless) set -- "$@" --headless ;;
    output:*)
      name=${mode#output:}
      printf '%s' "$name" | grep -Eqx '[A-Za-z0-9._-]+' || die "bad output name: $name"
      set -- "$@" --output "$name"
      ;;
  esac
  # shellcheck disable=SC2046
  set -- "$@" $(video_flag)
  [ $env_server -eq 1 ] && set -- "$@" --server-bin "$ENV_SERVER_BIN"
  setsid -f uwsm-app -- gliff "$@" "$last" >/dev/null 2>&1 </dev/null
  for t in $all; do
    setsid -f sh "$0" rescue "$t" "$rescue_mode" >/dev/null 2>&1 </dev/null
  done

  # Wait for the window's process, so a caller that looks right away sees it.
  i=0
  while [ $i -lt 50 ]; do
    gliff_procs | jq -e --arg h "$last" 'any(.[]; .host == $h)' >/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  die "gliff did not start"
}

# True when Tailscale SSH holds a login to TARGET for a browser sign-in. gliff
# shows nothing while it waits, so its window would just sit there frozen.
# Gives up after 8 s; anything else that goes wrong is left to gliff.
tailscale_signin_needed() {
  err=$(mktemp) || die "mktemp failed"
  # shellcheck disable=SC2086
  ssh $SSH_OPTS -- "$1" true </dev/null >/dev/null 2>"$err" &
  spid=$!
  i=0
  while [ $i -lt 80 ] && kill -0 "$spid" 2>/dev/null &&
        ! head -c 4096 "$err" | grep -qF "$TS_CHECK_TEXT"; do
    sleep 0.1
    i=$((i + 1))
  done
  kill "$spid" 2>/dev/null
  wait "$spid" 2>/dev/null
  needed=1
  head -c 4096 "$err" | grep -qF "$TS_CHECK_TEXT" && needed=0
  rm -f "$err"
  return $needed
}

# Mark TARGET's last check as waiting for a Tailscale sign-in, keeping the rest
# of what is known about it, so the panel offers the sign-in fix.
probe_mark_signin() {
  mkdir -p "$PROBES" || return 1
  old=$(probe_read "$1" 2>/dev/null) || old=''
  [ -n "$old" ] || old='{}'
  tmp=$(mktemp "$PROBES/.probe.XXXXXX") || return 1
  if printf '%s' "$old" | jq --arg t "$1" --arg r "$TS_CHECK_TEXT" --arg c "$(date +%s)" '
      { outputs: [], displays: 0 } + . +
      { target: $t, reach: "tailscale-check", reason: $r, checked: ($c | tonumber) }' >"$tmp"; then
    mv -f "$tmp" "$PROBES/$(slug "$1").json"
  else
    rm -f "$tmp"
    return 1
  fi
}

# Connect a machine. If a window of the same mode is already open, it is
# reopened with this machine as one more tab: gliff cannot be told to add a tab
# to a running window, so the machines already in it reconnect.
connect() {
  target=$1
  if live_json | jq -e --arg t "$target" 'any(.[]; .target == $t)' >/dev/null; then
    echo "already connected"
    return 0
  fi
  if tailscale_signin_needed "$target"; then
    probe_mark_signin "$target"
    die "Tailscale wants you to sign in before it lets ssh into $(printf '%s' "$target" | sed 's/^.*@//'). Use the fix button (F) on its row."
  fi
  mode=$(resolve_mode "$target")
  live=$(live_json)
  wpid=$(gliff_procs | jq -r --arg m "$mode" '[ .[] | select(.mode == $m) | .pid ] | first // empty')
  if [ -n "$wpid" ]; then
    keep=$(printf '%s' "$live" | jq -r --argjson pid "$wpid" '.[] | select(.pid == $pid) | .target')
    close_window "$wpid"
    # shellcheck disable=SC2086
    launch_window "$mode" $keep "$target"
    echo "added $target to the $mode window"
  else
    launch_window "$mode" "$target"
    echo "connecting $target ($mode)"
  fi
}

# Disconnect a machine. Other tabs in its window reopen without it.
disconnect() {
  target=$1
  live=$(live_json)
  printf '%s' "$live" | jq -c --arg t "$target" '[ .[] | select(.target == $t) ] | unique_by(.pid) | .[]' |
    while IFS= read -r entry; do
      wpid=$(printf '%s' "$entry" | jq -r '.pid')
      case $wpid in *[!0-9]*|'') continue ;; esac
      mode=$(printf '%s' "$entry" | jq -r '.mode')
      keep=$(printf '%s' "$live" | jq -r --argjson pid "$wpid" --arg t "$target" \
        '.[] | select(.pid == $pid and .target != $t) | .target')
      close_window "$wpid"
      if [ -n "$keep" ]; then
        # shellcheck disable=SC2086
        launch_window "$mode" $keep
      fi
    done
}

# When gliff's private headless screen goes away (a disconnect, or a window
# reopened to add a tab), Hyprland keeps the windows that were on it, on
# workspaces with no screen at all. A floating window also keeps its old
# position, which can be off the next screen entirely. Such windows are
# invisible, and an app that focuses its existing window instead of opening a
# new one (Omarchy's About) seems not to launch. Run on the remote machine
# once a session is up: hand screenless workspaces to the session's screen,
# pull floating windows back into view, and show the rescued workspace if the
# screen is empty.
REMOTE_RESCUE='
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
sig=$(ls -t "$XDG_RUNTIME_DIR/hypr/" 2>/dev/null | head -n 1)
[ -n "$sig" ] || exit 0
export HYPRLAND_INSTANCE_SIGNATURE="$sig"
mode=${1:-headless}

# The session screen: the private one gliff creates, or the focused one when
# mirroring. Give a headless session time to connect.
mon=""
i=0
while [ $i -lt 40 ]; do
  if [ "$mode" = headless ]; then
    mon=$(hyprctl monitors -j | jq -r "[ .[] | select(.name | startswith(\"gliff-\")) ] | last | .name // empty")
  else
    mon=$(hyprctl monitors -j | jq -r "[ .[] | select(.focused) ] | first | .name // empty")
  fi
  [ -n "$mon" ] && break
  sleep 0.5
  i=$((i + 1))
done
# Names below go into Lua dispatch strings; take only plain ones.
case $mon in ""|*[!A-Za-z0-9._-]*) exit 0 ;; esac
sleep 1

for ws in $(hyprctl workspaces -j | jq -r ".[] | select(.monitorID == null or .monitorID < 0) | .id"); do
  case $ws in ""|-|*[!0-9-]*) continue ;; esac
  hyprctl dispatch "hl.dsp.workspace.move({ workspace = \"$ws\", monitor = \"$mon\" })" >/dev/null
done

# Floating windows wholly outside their screen go back to its middle.
hyprctl clients -j | jq -r --argjson mons "$(hyprctl monitors -j)" "
  .[] | select(.floating) | . as \$c
  | (\$mons[] | select(.id == \$c.monitor)) as \$m
  | (\$m.width / \$m.scale) as \$w | (\$m.height / \$m.scale) as \$h
  | select(\$c.at[0] + \$c.size[0] <= \$m.x or \$c.at[0] >= \$m.x + \$w
        or \$c.at[1] + \$c.size[1] <= \$m.y or \$c.at[1] >= \$m.y + \$h)
  | .address" | while read -r addr; do
  case $addr in 0x*) ;; *) continue ;; esac
  case ${addr#0x} in ""|*[!0-9a-fA-F]*) continue ;; esac
  hyprctl dispatch "hl.dsp.window.center({ window = \"address:$addr\" })" >/dev/null
done

# A new private screen opens on an empty workspace, while the windows from
# the last session sit on another one; show those instead. (Hyprland often
# hands the old workspaces to the new screen by itself, so this does not
# depend on the move above having done anything.)
if [ "$mode" = headless ]; then
  empty=$(hyprctl monitors -j | jq -r --arg m "$mon" ".[] | select(.name == \$m) | .activeWorkspace.id" |
    while read -r id; do hyprctl workspaces -j | jq -r --argjson id "$id" ".[] | select(.id == \$id) | .windows"; done)
  if [ "${empty:-0}" = 0 ]; then
    first=$(hyprctl workspaces -j | jq -r --arg m "$mon" "[ .[] | select(.monitor == \$m and .windows > 0) | .id ] | min // empty")
    case $first in ""|*[!0-9]*) first="" ;; esac
    [ -n "$first" ] && hyprctl dispatch "hl.dsp.focus({ workspace = \"$first\" })" >/dev/null
  fi
fi
exit 0
'

rescue() {
  # shellcheck disable=SC2086
  printf '%s' "$REMOTE_RESCUE" | timeout 60 ssh $SSH_OPTS -- "$1" sh -s "$2" >/dev/null 2>&1
}

# A terminal that stays open on failure, so an error can be read rather than
# flashing past. The script arrives as an argument; $1.. follow it.
in_terminal() {
  script=$1
  shift
  setsid -f uwsm-app -- xdg-terminal-exec -e sh -c "
$script
rc=\$?
if [ \$rc -ne 0 ]; then printf '\n[exited %s] ' \"\$rc\"; else printf '\nDone. '; fi
printf 'Press Enter to close. '
read -r _" gliff-manager "$@" >/dev/null 2>&1 </dev/null
}

WRAPPER='#!/bin/sh
# Installed by Gliff-Manager. ssh sessions on some machines arrive without
# XDG_RUNTIME_DIR, so gliff-server cannot find the Hyprland session; fill it
# in from the user id, then run the real server.
: "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
export XDG_RUNTIME_DIR
exec /usr/bin/gliff-server "$@"
'

fix_session() {
  target=$1
  # Staged in the remote user's own cache rather than /tmp, where another
  # user could have planted the path first.
  stage "$target" "$WRAPPER" gliff-server
  in_terminal '
echo "Installing the gliff-server session wrapper on $1."
echo "sudo will ask for the password of the user on that machine."
echo
ssh -t -- "$1" "sudo install -m755 \"\$HOME/.cache/gliff-manager/gliff-server\" /usr/local/bin/gliff-server"' "$target"
}

REMOTE_INSTALL='
if pacman -Sp gliff >/dev/null 2>&1; then
  sudo pacman -S --needed gliff
  exit $?
fi
srv=$(pacman-conf --repo omarchy Server 2>/dev/null | head -n 1)
file=$(bsdtar -xOf /var/lib/pacman/sync/omarchy.db "*/desc" 2>/dev/null | awk "
  /^%FILENAME%/ { getline; f = \$0; next }
  /^%NAME%/ { getline; if (\$0 == \"gliff\") { print f; exit } }")
if [ -n "$srv" ] && [ -n "$file" ]; then
  echo "This machine lists gliff but will not install from that repo directly;"
  echo "installing the package file instead: $file"
  sudo pacman -U "$srv/$file"
else
  echo "gliff is not in this machine'"'"'s package lists yet."
  echo "Run omarchy update on it, then try again."
  exit 1
fi
'

# ssh joins its command words with spaces for the remote shell to re-read, so
# a script can't travel as an argument; stage it beside the wrapper instead.
stage() {
  # shellcheck disable=SC2086
  printf '%s' "$2" | timeout 30 ssh $SSH_OPTS -- "$1" \
    'mkdir -p "$HOME/.cache/gliff-manager" && cat > "$HOME/.cache/gliff-manager/'"$3"'"' ||
    die "could not reach $1"
}

install_gliff() {
  stage "$1" "$REMOTE_INSTALL" install.sh
  in_terminal '
echo "Installing gliff on $1."
echo "sudo will ask for the password of the user on that machine."
echo
ssh -t -- "$1" "sh \"\$HOME/.cache/gliff-manager/install.sh\""' "$1"
}

trust() {
  in_terminal '
echo "Logging in to $1 once so ssh can record its host key."
echo "Check the fingerprint before you accept it."
echo
ssh -t -- "$1" true && echo "Logged in to $1; its host key is saved."' "$1"
}

# Tailscale SSH in "check" mode prints a sign-in link and holds the login
# until it is approved. Open that link in the browser and wait here, so the
# approval lands on a login that is still waiting for it.
signin() {
  in_terminal '
echo "Tailscale SSH on $1 wants you to confirm it is you."
echo "Your browser opens the Tailscale sign-in page: approve the login there."
echo "If no browser opens, open the link below yourself."
echo
rcf=$(mktemp) || exit 1
{ ssh -o ConnectTimeout=10 -- "$1" true; echo $? >"$rcf"; } 2>&1 |
  while IFS= read -r line; do
    line=$(printf "%s" "$line" | tr -d "\r")
    printf "%s\n" "$line"
    case $line in
      *"To authenticate, visit:"*)
        url=$(printf "%s" "$line" | grep -Eo "https://[A-Za-z0-9./?=&_%~:#@+-]+" | head -n 1)
        [ -n "$url" ] && setsid -f xdg-open "$url" >/dev/null 2>&1 </dev/null
        ;;
    esac
  done
rc=$(cat "$rcf" 2>/dev/null)
rm -f "$rcf"
if [ "$rc" = 0 ]; then
  echo "Signed in: $1 lets you log in again. Connect from the panel."
  sh "$2" probe "$1" >/dev/null 2>&1
else
  echo "Not signed in yet. Run the fix again for a fresh link."
  exit 1
fi' "$1" "$(readlink -f "$0")"
}

check() {
  uid=$(probe_read "$1" | jq -r '.uid // ""' 2>/dev/null)
  case $uid in *[!0-9]*|'') die "check $1 from the panel first" ;; esac
  in_terminal '
ssh -t -- "$1" env "XDG_RUNTIME_DIR=/run/user/$2" gliff-probe all' "$1" "$uid"
}

# ------------------------------------------------------------------- main

command -v jq >/dev/null 2>&1 || die "jq is required"

cmd=${1:-}
[ $# -gt 0 ] && shift
case $cmd in
  status)
    case ${1:-fast} in fast|full) status_json "${1:-fast}" ;; *) die "status fast|full" ;; esac
    ;;
  live) live_json ;;
  probe) need_target "$@"; probe_cached "$1" ;;
  connect) need_target "$@"; connect "$1" ;;
  disconnect) need_target "$@"; disconnect "$1" ;;
  add)
    need_target "$@"
    prefs_update --arg t "$1" '.machines[$t] = ((.machines[$t] // {}) | del(.hidden))'
    names_sync
    ;;
  forget)
    need_target "$@"
    prefs_update --arg t "$1" '.machines[$t] = ((.machines[$t] // {}) + { hidden: true })'
    rm -f "$PROBES/$(slug "$1").json"
    names_sync
    ;;
  set-mode)
    need_target "$@"
    mode=${2:-}
    case $mode in
      auto|headless|mirror) ;;
      output:*) printf '%s' "${mode#output:}" | grep -Eqx '[A-Za-z0-9._-]+' || die "bad output name" ;;
      *) die "mode must be auto, headless, mirror or output:NAME" ;;
    esac
    prefs_update --arg t "$1" --arg m "$mode" '.machines[$t] = ((.machines[$t] // {}) + { mode: $m })'
    ;;
  set-video)
    case ${1:-} in auto|cpu|gpu) ;; *) die "video must be auto, cpu or gpu" ;; esac
    prefs_update --arg v "$1" '.video = $v'
    ;;
  hide-peer)
    printf '%s' "${1:-}" | grep -Eqx '[A-Za-z0-9][A-Za-z0-9.-]*' || die "not a host name: ${1:-}"
    prefs_update --arg d "$1" --argjson max "$MAX_HIDDEN_PEERS" \
      '.hiddenPeers = ((.hiddenPeers // []) - [$d] + [$d] | .[-$max:])'
    ;;
  show-peers) prefs_update 'del(.hiddenPeers)' ;;
  show-machines)
    prefs_update '.machines = ((.machines // {}) | map_values(del(.hidden)))'
    names_sync
    ;;
  short-names)
    case ${1:-} in
      on) short_names_enable ;;
      off) short_names_disable ;;
      *) die "short-names on|off" ;;
    esac
    ;;
  fix-session) need_target "$@"; fix_session "$1" ;;
  install) need_target "$@"; install_gliff "$1" ;;
  trust) need_target "$@"; trust "$1" ;;
  signin) need_target "$@"; signin "$1" ;;
  check) need_target "$@"; check "$1" ;;
  rescue)
    need_target "$@"
    case ${2:-headless} in headless|mirror) ;; *) die "rescue TARGET headless|mirror" ;; esac
    rescue "$1" "${2:-headless}"
    ;;
  *) awk '/^# Gliff-Manager helper/ { on = 1 } on && /^[^#]/ { exit } on { sub(/^# ?/, ""); print }' "$0"; [ -z "$cmd" ] || exit 1 ;;
esac
