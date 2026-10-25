#!/usr/bin/env bash
# Fixture checks for the runner probe. No CPU required.
set -eu
probe=$(CDPATH= cd -- "$(dirname "$0")/../.github/actions/probe-gccarch" && pwd)/probe-gccarch.sh

run() {
  PROBE_KIND=x86 PROBE_FLAGS="$1" PROBE_VENDOR="$2" PROBE_FAMILY="$3" PROBE_MODEL="$4" PROBE_NAME="$5" bash "$probe"
}

assert_has() {
  case " $1 " in
    *" $2 "*) ;;
    *)
      echo "missing $2 in: $1" >&2
      exit 1
      ;;
  esac
}

assert_lacks() {
  case " $1 " in
    *" $2 "*)
      echo "unexpected $2 in: $1" >&2
      exit 1
      ;;
  esac
}

v4_flags="sse3 ssse3 sse4_1 sse4_2 popcnt avx avx2 fma bmi1 bmi2 avx512f avx512bw avx512cd avx512dq avx512vl aes"
v3_flags="sse3 ssse3 sse4_1 sse4_2 popcnt avx avx2 fma bmi1 bmi2 aes"

zen4=$(run "$v4_flags sse4a" AuthenticAMD 25 97 "AMD Ryzen 7 7840HS")
assert_has "$zen4" "gccarch-znver4"
assert_has "$zen4" "gccarch-skylake"
assert_has "$zen4" "gccarch-x86-64-v4"
assert_lacks "$zen4" "gccarch-rocketlake"

rocket=$(run "$v4_flags" GenuineIntel 6 167 "11th Gen Intel(R) Core(TM) i5-11400")
assert_has "$rocket" "gccarch-rocketlake"
assert_has "$rocket" "gccarch-x86-64-v4"
assert_lacks "$rocket" "gccarch-znver4"
assert_lacks "$rocket" "gccarch-skylake"

zen2=$(run "$v3_flags sse4a" AuthenticAMD 23 96 "AMD Ryzen 7 4800U")
assert_has "$zen2" "gccarch-znver2"
assert_has "$zen2" "gccarch-skylake"
assert_lacks "$zen2" "gccarch-x86-64-v4"
assert_lacks "$zen2" "gccarch-znver4"

kaby=$(run "$v3_flags" GenuineIntel 6 142 "Intel(R) Core(TM) i5-8350U CPU")
assert_has "$kaby" "gccarch-skylake"
assert_lacks "$kaby" "gccarch-x86-64-v4"

noaes=$(run "sse3 ssse3 sse4_1 sse4_2 popcnt avx avx2 fma bmi1 bmi2" GenuineIntel 6 60 "Intel Xeon")
assert_has "$noaes" "gccarch-x86-64-v3"
assert_lacks "$noaes" "gccarch-skylake"

arm=$(PROBE_KIND=arm PROBE_FLAGS="aes pmull sha1 sha2 asimddp fphp asimd" bash "$probe")
assert_has "$arm" "gccarch-armv8.2-a+crypto+dotprod+fp16"
assert_lacks "$arm" "gccarch-znver4"

echo "probe-gccarch: ok"
