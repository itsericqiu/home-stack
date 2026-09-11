#!/usr/bin/env bash
# Static guard against tests that mutate the live checked-out source tree
# instead of an isolated staging directory. This is the exact bug class
# described in docs/PLAN.md P2: a test that rebuilds the production admin
# binary in place, or runs `hs sync` / stubs reload-caddy.sh against
# $ROOT_DIR, rewrites tracked files and the real generated bundle for real --
# on a developer's own checkout when the guard above it is bypassed, and even
# on a "disposable" CI runner it is needless sloppiness once staging is easy.
#
# This is a fast, pure grep/awk/perl static check -- it never builds or runs
# anything -- so it always runs, on every platform, unconditionally.
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="$(basename "${BASH_SOURCE[0]}")"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

errors=0

# --- (1) Makefile: the `test` target must never build the admin binary to
# its production path (portable/home-stack/admin/home-stack-admin). It must
# build into admin/.test-build/ instead; `make build-admin` is the one
# target allowed to write the production path.
test_recipe="$(awk '/^test:/{flag=1; next} /^[A-Za-z0-9_.-]+:/{flag=0} flag' "$ROOT_DIR/Makefile")"
if [[ -z "$test_recipe" ]]; then
  echo "FAIL: could not locate a 'test:' target recipe in Makefile" >&2
  errors=$((errors + 1))
elif grep -qE 'go build .*-o[[:space:]]+home-stack-admin([[:space:]]|$)' <<<"$test_recipe"; then
  echo "FAIL: Makefile 'test' target builds directly to the production admin" >&2
  echo "  binary path (portable/home-stack/admin/home-stack-admin) instead of" >&2
  echo "  .test-build/home-stack-admin. This overwrites the binary launchd" >&2
  echo "  runs in production with whatever branch happens to be checked out." >&2
  errors=$((errors + 1))
fi

# --- (2) and (3): scan every tests/*.test.sh (excluding this guard, which
# necessarily discusses the forbidden patterns in its own comments) for
# direct mutation of $ROOT_DIR's admin binary, hs script, or reload-caddy.sh.
while IFS= read -r -d '' f; do
  base="$(basename "$f")"
  [[ "$base" == "$SELF" ]] && continue

  # (2) Building/removing the production admin binary path. Heuristic: the
  # literal path "admin/home-stack-admin" appearing on a line with no
  # STAGE/WORK/TMP-ish staging variable earlier on that same line means the
  # test is operating on $ROOT_DIR's real copy (or some other non-isolated
  # path) rather than a staged one. Deliberately a simple substring/regex
  # match, not a parser -- allow-list nothing; if a test legitimately needs
  # an exception, restructure the test to stage its own copy instead.
  while IFS=: read -r lineno line; do
    [[ -z "$lineno" ]] && continue
    # An rsync/tar --exclude entry declares what NOT to copy into a staging
    # dir -- it is the fix, not the bug -- so it is not a mutation to flag.
    [[ "$line" == *--exclude* ]] && continue
    prefix="${line%%admin/home-stack-admin*}"
    if ! [[ "$prefix" =~ (STAGE|WORK|TMP) ]]; then
      echo "FAIL: $f:$lineno: references portable/home-stack/admin/home-stack-admin" >&2
      echo "  with no STAGE/WORK/TMP staging variable earlier on the line:" >&2
      echo "    $line" >&2
      errors=$((errors + 1))
    fi
  done < <(grep -n 'admin/home-stack-admin' "$f" || true)

  # (3) Invoking $ROOT_DIR's hs script with the mutating `sync` subcommand,
  # or overwriting $ROOT_DIR's reload-caddy.sh, rather than a staged copy of
  # each. The bug this guards against always assigns the real path to a
  # variable on one line and invokes/overwrites it via that variable on a
  # later line (see git history of identifier-prefix-flow.test.sh), so this
  # is a two-pass check: find variables assigned $ROOT_DIR's hs / reload
  # script paths, then check whether the file invokes/overwrites them.
  hits="$(perl -e '
    my $file = $ARGV[0];
    open(my $fh, "<", $file) or die "open $file: $!";
    my @lines = <$fh>;
    close $fh;
    my (%hs_vars, %reload_vars);
    for my $i (0 .. $#lines) {
      my $l = $lines[$i];
      if ($l =~ /(\w+)="\$ROOT_DIR\/portable\/home-stack\/scripts\/hs"/) {
        $hs_vars{$1} = $i + 1;
      }
      if ($l =~ /(\w+)="\$ROOT_DIR\/portable\/home-stack\/scripts\/reload-caddy\.sh"/) {
        $reload_vars{$1} = $i + 1;
      }
    }
    my $errors = 0;
    for my $i (0 .. $#lines) {
      my $l = $lines[$i];
      for my $v (keys %hs_vars) {
        if ($l =~ /"\$\Q$v\E"\s+sync\b/) {
          print "FAIL: $file:" . ($i + 1)
              . ": runs \"\$$v\" sync against \\\$ROOT_DIR (assigned line $hs_vars{$v})"
              . " -- stage a copy of portable/ and run the staged hs instead.\n";
          $errors++;
        }
      }
      for my $v (keys %reload_vars) {
        if ($l =~ /(^|[^>])>\s*"\$\Q$v\E"/) {
          print "FAIL: $file:" . ($i + 1)
              . ": overwrites \$$v (\\\$ROOT_DIR reload-caddy.sh, assigned line $reload_vars{$v})"
              . " directly -- stub it inside a staged copy of portable/ instead.\n";
          $errors++;
        }
      }
    }
    exit($errors > 0 ? 1 : 0);
  ' "$f")" && rc=0 || rc=$?
  if [[ -n "$hits" ]]; then
    echo "$hits" >&2
    errors=$((errors + $(grep -c '^FAIL:' <<<"$hits")))
  fi

  # (3, direct form) Invoking $ROOT_DIR's hs with `sync` or writing
  # reload-caddy.sh in the same expression, without an intermediate variable.
  if grep -qE '"\$ROOT_DIR/portable/home-stack/scripts/hs"[[:space:]]+sync\b' "$f"; then
    echo "FAIL: $f: runs \"\$ROOT_DIR/portable/home-stack/scripts/hs\" sync directly" >&2
    echo "  -- stage a copy of portable/ and run the staged hs instead." >&2
    errors=$((errors + 1))
  fi
  if grep -qE '>[[:space:]]*"?\$ROOT_DIR/portable/home-stack/scripts/reload-caddy\.sh"?' "$f"; then
    echo "FAIL: $f: overwrites \$ROOT_DIR's reload-caddy.sh directly" >&2
    echo "  -- stub it inside a staged copy of portable/ instead." >&2
    errors=$((errors + 1))
  fi

  # (4) A raw `rsync -a` belongs in exactly one place: tests/lib/stage.sh's
  # home_stack_stage_repo. Every darwin integration test needs the same
  # staged copy of portable/ (with the same exclude list, kept in sync in one
  # place); a test that rsyncs its own copy instead of calling the shared
  # helper is exactly how two of the three ended up missing the `bin/`
  # exclude (~300MB of built Caddy binaries staged needlessly) before this
  # helper existed. This loop already excludes this guard file itself and is
  # scoped to tests/*.test.sh (maxdepth 1), so tests/lib/stage.sh's own
  # definition is never scanned.
  if grep -qE '(^|[^A-Za-z0-9_])rsync[[:space:]]+-a\b' "$f"; then
    echo "FAIL: $f: calls 'rsync -a' directly instead of going through" >&2
    echo "  tests/lib/stage.sh's home_stack_stage_repo -- source tests/lib/stage.sh" >&2
    echo "  and call home_stack_stage_repo instead of duplicating the rsync." >&2
    errors=$((errors + 1))
  fi
done < <(find "$ROOT_DIR/tests" -maxdepth 1 -name '*.test.sh' -print0)

if [[ $errors -gt 0 ]]; then
  fail "source-tree-guard found $errors violation(s) above"
fi

echo "PASS source-tree-guard.test.sh"
