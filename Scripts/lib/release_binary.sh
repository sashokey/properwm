# Sourced by package_release.sh and install_local_release.sh; defines functions only.
#
# A Release build must not carry code-coverage instrumentation or a symbol table, and
# neither shows up in the build log: the scheme's test action turns coverage on for
# every `xcodebuild build` of the scheme, and `xcodebuild build` skips install
# post-processing, so STRIP_INSTALLED_PRODUCT never runs. Both shipped silently in
# every release up to 0.13.1. Callers build with CLANG_COVERAGE_MAPPING=NO, strip the
# staged copy before signing, and refuse to go on unless verify_release_binary passes.
#
# Every command's status is checked explicitly: callers invoke these as
# `fn || die`, and `set -e` does not apply inside a function called that way.

# Strips debug-map stabs (-S), local symbols (-x) and Swift symbols (-T). LC_UUID is
# untouched, so the dSYM produced by the build still symbolicates the result. strip
# invalidates any existing signature; the caller re-signs with --force afterwards.
strip_release_binary() {
  local binary="$1" log status=0
  log="$(mktemp "${TMPDIR:-/tmp}/tungsten-strip.XXXXXX")" || return 1
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
  if [[ " $archs " != *' arm64 '* || " $archs " != *' x86_64 '* ]]; then
    printf 'release binary must contain arm64 and x86_64, has: %s\n' "${archs:-<none>}" >&2
    return 1
  fi

  for arch in $archs; do
    sizes="$(size -m -arch "$arch" "$binary")" || { printf 'size failed on %s (%s)\n' "$binary" "$arch" >&2; return 1; }
    # An unreadable listing must fail, not pass as "no coverage segment found".
    [[ "$sizes" == *'Segment __TEXT'* ]] || { printf 'unexpected size output for %s\n' "$arch" >&2; return 1; }
    if [[ "$sizes" == *'__LLVM_COV'* || "$sizes" == *'__llvm_prf_'* ]]; then
      printf '%s carries code-coverage instrumentation - build with CLANG_COVERAGE_MAPPING=NO\n' "$arch" >&2
      return 1
    fi

    # One nm pass feeds every symbol check. Each line must be a stab ("value - sect desc
    # type name"), a defined symbol ("value type name") or an undefined one ("U name");
    # anything else fails, so a change in nm's format cannot turn every count into 0.
    # strip itself leaves one OPT stab. What -T -x -S leaves among local symbols is
    # <redacted ...> placeholders, Objective-C method names and Objective-C runtime
    # metadata; any other named local means -x is gone.
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

  bytes="$(stat -f %z "$binary")" || return 1
  printf '    release binary: %s bytes, archs=%s, no coverage instrumentation, symbols stripped\n' "$bytes" "$archs"
}
