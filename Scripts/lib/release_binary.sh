
strip_release_binary() {
  local binary="$1" log status=0
  log="$(mktemp "${TMPDIR:-/tmp}/properwm-strip.XXXXXX")" || return 1
  xcrun strip -T -x -S "$binary" 2>"$log" || status=$?
  grep -v 'will invalidate the code signature' "$log" >&2 || true
  rm -f "$log"
  if [[ "$status" -ne 0 ]]; then
    printf 'strip failed (exit %s): %s\n' "$status" "$binary" >&2
    return 1
  fi
}

verify_release_binary() {
  local binary="$1" archs arch sizes symbols counts defined stabs swift named unknown bytes

  [[ -f "$binary" ]] || { printf 'release binary not found: %s\n' "$binary" >&2; return 1; }
  archs="$(lipo -archs "$binary")" || { printf 'lipo could not read %s\n' "$binary" >&2; return 1; }
  if [[ "$archs" != "arm64" ]]; then
    printf 'release binary must contain only arm64, has: %s\n' "${archs:-<none>}" >&2
    return 1
  fi

  for arch in $archs; do
    sizes="$(size -m -arch "$arch" "$binary")" || { printf 'size failed on %s (%s)\n' "$binary" "$arch" >&2; return 1; }
    [[ "$sizes" == *'Segment __TEXT'* ]] || { printf 'unexpected size output for %s\n' "$arch" >&2; return 1; }
    if [[ "$sizes" == *'__LLVM_COV'* || "$sizes" == *'__llvm_prf_'* ]]; then
      printf '%s carries code-coverage instrumentation - build with CLANG_COVERAGE_MAPPING=NO\n' "$arch" >&2
      return 1
    fi

    symbols="$(nm -ap -arch "$arch" "$binary")" || { printf 'nm failed on %s (%s)\n' "$binary" "$arch" >&2; return 1; }
    counts="$(awk '
      $2 == "-" && NF >= 5 { if ($5 != "OPT") stabs++; next }
      NF >= 3 && $1 ~ /^[0-9a-f]+$/ && $2 ~ /^[A-Za-z]$/ {
        defined++
        if ($3 ~ /^_\$[sS]/) swift++
        else if ($2 ~ /^[a-z]$/ && $3 !~ /^(<redacted|[-+]\[|_OBJC_)/) named++
        next
      }
      NF >= 2 && $1 == "U" { next }
      { unknown++ }
      END { print defined + 0, stabs + 0, swift + 0, named + 0, unknown + 0 }
    ' <<<"$symbols")" || { printf 'could not parse nm output for %s\n' "$arch" >&2; return 1; }
    read -r defined stabs swift named unknown <<<"$counts"
    if ! [[ "$defined" =~ ^[0-9]+$ && "$stabs" =~ ^[0-9]+$ && "$swift" =~ ^[0-9]+$ && "$named" =~ ^[0-9]+$ && "$unknown" =~ ^[0-9]+$ ]]; then
      printf 'could not parse nm output for %s\n' "$arch" >&2
      return 1
    fi
    if [[ "$unknown" -ne 0 || "$defined" -eq 0 ]]; then
      printf 'unexpected nm output for %s (%s unrecognised lines, %s defined symbols)\n' "$arch" "$unknown" "$defined" >&2
      return 1
    fi
    if [[ "$stabs" -ne 0 || "$swift" -ne 0 || "$named" -ne 0 ]]; then
      printf '%s symbol table is not stripped (debug stabs=%s, Swift symbols=%s, named locals=%s)\n' \
        "$arch" "$stabs" "$swift" "$named" >&2
      return 1
    fi
  done

  verify_release_diagnostics "$binary" || return 1

  bytes="$(stat -f %z "$binary")" || return 1
  printf '    release binary: %s bytes, archs=%s, diagnostics and coverage absent, symbols stripped\n' "$bytes" "$archs"
}

verify_release_diagnostics() {
  local binary="$1" imports literals registry debug_switches failed=0
  imports="$(nm -u "$binary")" || return 1
  literals="$(strings -a "$binary")" || return 1
  registry="$(dirname "${BASH_SOURCE[0]}")/../../Core/Support/DebugSwitch.swift"
  debug_switches="$(awk -F '"' '
    /^[[:space:]]*#if DEBUG[[:space:]]*$/ { depth = 1; next }
    depth && /^[[:space:]]*#if[[:space:]]/ { ++depth; next }
    depth && /^[[:space:]]*#endif[[:space:]]*$/ { --depth; next }
    depth == 1 && /^[[:space:]]*#else[[:space:]]*$/ { depth = 0; next }
    depth && $1 ~ /^[[:space:]]*case[[:space:]]/ && $2 ~ /^DOCK_[A-Z0-9_]+$/ {
      if (count++) printf "|"
      printf "%s", $2
    }
  ' "$registry")" || return 1
  if [[ -z "$debug_switches" ]]; then
    printf 'release diagnostic scan found no registered Debug switches\n' >&2
    return 1
  fi
  reject_release_diagnostic_matches \
    '(^|[[:space:]])_{1,2}(os_log(_[[:alnum:]_]+)?|os_signpost(_[[:alnum:]_]+)?|NSLogv?)$|\$s2os6Logger' \
    "$imports" 'imports logging or signpost APIs' || failed=1
  reject_release_diagnostic_matches \
    "window-inventory\.jsonl|click-latency\.jsonl|hover-trace\.jsonl|($debug_switches)" \
    "$literals" 'contains diagnostic settings or file journal names' || failed=1
  return "$failed"
}

reject_release_diagnostic_matches() {
  local match=0
  grep -Eq "$1" <<<"$2" || match=$?
  case "$match" in
    0) printf 'release binary %s\n' "$3" >&2; return 1 ;;
    1) return 0 ;;
    *) printf 'release diagnostic scan failed (grep exit %s)\n' "$match" >&2; return 1 ;;
  esac
}
