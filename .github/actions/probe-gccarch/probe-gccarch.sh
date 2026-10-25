#!/usr/bin/env bash
# Print the gccarch-* system features this machine can execute, one line,
# space-separated. Empty when nothing beyond the stock Nix baseline applies.
#
# Names match nixpkgs lib/systems/architectures.nix. A recognised microarch
# includes the arches nixpkgs treats as inferior, so one token is not enough:
# a derivation built for skylake requires gccarch-skylake exactly.
# Unknown CPUs get only the psABI level (x86-64-v2/v3/v4). That keeps a
# Zen 4 runner from advertising rocketlake, and the reverse.
set -eu

if [ -n "${PROBE_FLAGS:-}" ]; then
  FLAGS=$(printf '%s' "$PROBE_FLAGS" | tr 'A-Z' 'a-z' | tr -s '[:space:]' ' ')
  VENDOR=${PROBE_VENDOR:-}
  FAMILY=${PROBE_FAMILY:-0}
  MODEL=${PROBE_MODEL:-0}
  NAME=${PROBE_NAME:-}
  KIND=${PROBE_KIND:-x86}
elif [ "$(uname -s)" = "Darwin" ]; then
  case "$(uname -m)" in
    arm64 | aarch64) exit 0 ;;
  esac
  FLAGS=$(
    {
      sysctl -n machdep.cpu.features 2>/dev/null || true
      sysctl -n machdep.cpu.leaf7_features 2>/dev/null || true
      sysctl -n machdep.cpu.extfeatures 2>/dev/null || true
    } | tr 'A-Z' 'a-z' | tr -s '[:space:]' ' '
  )
  VENDOR=$(sysctl -n machdep.cpu.vendor 2>/dev/null || true)
  FAMILY=$(sysctl -n machdep.cpu.family 2>/dev/null || echo 0)
  MODEL=$(sysctl -n machdep.cpu.model 2>/dev/null || echo 0)
  NAME=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)
  KIND=x86
elif [ -r /proc/cpuinfo ]; then
  if grep -q '^Features' /proc/cpuinfo; then
    KIND=arm
    FLAGS=$(awk -F: '/^Features/ { print $2; exit }' /proc/cpuinfo | tr -s '[:space:]' ' ')
    VENDOR=""
    FAMILY=0
    MODEL=0
    NAME=$(awk -F: '/^CPU part/ { gsub(/^[ \t]+/, "", $2); print $2; exit }' /proc/cpuinfo)
  else
    KIND=x86
    FLAGS=$(awk -F: '/^flags/ { print $2; exit }' /proc/cpuinfo | tr -s '[:space:]' ' ')
    VENDOR=$(awk -F: '/^vendor_id/ { gsub(/^[ \t]+/, "", $2); print $2; exit }' /proc/cpuinfo)
    FAMILY=$(awk -F: '/^cpu family/ { gsub(/^[ \t]+/, "", $2); print $2; exit }' /proc/cpuinfo)
    MODEL=$(awk -F: '/^model/ && !/^model name/ { gsub(/^[ \t]+/, "", $2); print $2; exit }' /proc/cpuinfo)
    NAME=$(awk -F: '/^model name/ { gsub(/^[ \t]+/, "", $2); print $2; exit }' /proc/cpuinfo)
  fi
else
  exit 0
fi

has() {
  case " $FLAGS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

in_range() {
  # $1 value, $2 lo, $3 hi (inclusive, decimal)
  [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

tokens_for() {
  case "$1" in
    znver4)
      echo "znver4 znver3 znver2 znver1 skylake broadwell haswell ivybridge sandybridge westmere nehalem x86-64-v4 x86-64-v3 x86-64-v2 x86-64"
      ;;
    znver3)
      echo "znver3 znver2 znver1 skylake broadwell haswell ivybridge sandybridge westmere nehalem x86-64-v3 x86-64-v2 x86-64"
      ;;
    znver2)
      echo "znver2 znver1 skylake broadwell haswell ivybridge sandybridge westmere nehalem x86-64-v3 x86-64-v2 x86-64"
      ;;
    znver1)
      echo "znver1 skylake broadwell haswell ivybridge sandybridge westmere nehalem x86-64-v3 x86-64-v2 x86-64"
      ;;
    rocketlake)
      echo "rocketlake x86-64-v4 x86-64-v3 x86-64-v2 x86-64"
      ;;
    skylake)
      echo "skylake broadwell haswell ivybridge sandybridge westmere nehalem x86-64-v3 x86-64-v2 x86-64"
      ;;
    x86-64-v4)
      echo "x86-64-v4 x86-64-v3 x86-64-v2 x86-64"
      ;;
    x86-64-v3)
      echo "x86-64-v3 x86-64-v2 x86-64"
      ;;
    x86-64-v2)
      echo "x86-64-v2 x86-64"
      ;;
    x86-64)
      echo "x86-64"
      ;;
    armv8.2-a+crypto+dotprod+fp16)
      echo "armv8.2-a+crypto+dotprod+fp16"
      ;;
    *)
      echo ""
      ;;
  esac
}

prefix() {
  out=""
  for name in $1; do
    out="$out gccarch-$name"
  done
  printf '%s\n' "${out# }"
}

if [ "$KIND" = "arm" ]; then
  if has aes && has pmull && has sha1 && has sha2 && has asimddp && has fphp; then
    prefix "$(tokens_for 'armv8.2-a+crypto+dotprod+fp16')"
  fi
  exit 0
fi

v2=0
v3=0
v4=0
# Linux reports SSE3 as "pni" on AMD.
sse3=0
if has sse3 || has pni; then
  sse3=1
fi
if [ "$sse3" = 1 ] && has ssse3 && has sse4_1 && has sse4_2 && has popcnt; then
  v2=1
fi
if [ "$v2" = 1 ] && has avx && has avx2 && has fma && has bmi1 && has bmi2; then
  v3=1
fi
if [ "$v3" = 1 ] && has avx512f && has avx512bw && has avx512cd && has avx512dq && has avx512vl; then
  v4=1
fi

primary=""
if [ "$VENDOR" = "AuthenticAMD" ]; then
  if [ "$FAMILY" = 26 ]; then
    primary="znver4"
  elif [ "$FAMILY" = 25 ]; then
    if in_range "$MODEL" 16 31 || in_range "$MODEL" 96 127 || in_range "$MODEL" 144 175; then
      primary="znver4"
    elif in_range "$MODEL" 0 15 || in_range "$MODEL" 32 95; then
      primary="znver3"
    fi
  elif [ "$FAMILY" = 23 ]; then
    if in_range "$MODEL" 48 63 || in_range "$MODEL" 96 143; then
      primary="znver2"
    elif in_range "$MODEL" 0 47; then
      primary="znver1"
    fi
  fi
elif [ "$VENDOR" = "GenuineIntel" ]; then
  case "$NAME" in
    *[Rr]ocket\ [Ll]ake* | *i5-11400* | *i7-11700* | *i9-11900*)
      primary="rocketlake"
      ;;
  esac
  if [ -z "$primary" ] && [ "$FAMILY" = 6 ] && { [ "$MODEL" = 167 ] || [ "$MODEL" = 165 ]; }; then
    primary="rocketlake"
  fi
fi

if [ -z "$primary" ]; then
  if [ "$v4" = 1 ]; then
    primary="x86-64-v4"
  elif [ "$v3" = 1 ] && has aes; then
    primary="skylake"
  elif [ "$v3" = 1 ]; then
    primary="x86-64-v3"
  elif [ "$v2" = 1 ]; then
    primary="x86-64-v2"
  else
    primary="x86-64"
  fi
fi

# A recognised name still has to have the instructions it claims.
case "$primary" in
  znver4 | rocketlake | x86-64-v4)
    [ "$v4" = 1 ] || primary="x86-64-v3"
    ;;
esac
case "$primary" in
  znver1 | znver2 | znver3 | znver4 | skylake | rocketlake | x86-64-v3 | x86-64-v4)
    if [ "$v3" != 1 ]; then
      primary="x86-64-v2"
    fi
    ;;
esac

prefix "$(tokens_for "$primary")"
