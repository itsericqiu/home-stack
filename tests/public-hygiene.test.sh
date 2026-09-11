#!/usr/bin/env bash
# Public-hygiene guard (docs/PUBLIC_RELEASE.md §4 A3): this repository must
# not carry the owner's specific identity literals, or tracked
# generated/per-machine artifacts, once published. Fast and static -- it only
# runs `git ls-files` and greps the result, so it runs on every tier.
#
# Two independent checks:
#
#   1. An identifier-literal scan over `git ls-files`, covering the whole
#      repository including docs (Phase B of docs/PUBLIC_RELEASE.md widened
#      this from the original code/tests/templates/schemas/tooling scope).
#      This test and its pattern data necessarily discuss the identifiers
#      themselves, so it excludes only itself and its pattern-data file --
#      including docs/PUBLIC_RELEASE.md, which describes findings using
#      placeholders rather than the real identifiers, precisely so it can
#      pass this scan like everything else.
#   2. Tracked-path checks that apply repo-wide right now, independent of the
#      docs scrub: no profile other than profiles/default/, no generated
#      artifact, no per-machine settings file, no env.local.
#
# The identifier list is data (tests/lib/hygiene-patterns.sh): generic
# classes only, tracked. The owner's own specific identifiers (handle,
# domain, IP, name, email) never live in this repo -- they go in a private,
# untracked pattern file, loaded from $HOME_STACK_HYGIENE_PATTERNS_FILE if
# set, else $HOME/.config/home-stack/hygiene-patterns.sh if present. The
# owner keeps that file in their dotfiles overlay and links it into
# ~/.config/home-stack/, the same way their profile is linked in (see
# docs/PUBLIC_RELEASE.md §4 A3/A4). This test prints one line saying whether
# a private pattern file was loaded, so its output always says which mode it
# ran in.
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="tests/$(basename "${BASH_SOURCE[0]}")"

# shellcheck source=tests/lib/hygiene-patterns.sh
. "$ROOT_DIR/tests/lib/hygiene-patterns.sh"
# Owner-specific identifiers (handle, domain, IP, name, email, ...) are never
# tracked in this repo -- they come from an optional private file. See
# docs/PUBLIC_RELEASE.md §4 A3 and the header of tests/lib/hygiene-patterns.sh.
home_stack_hygiene_load_private
HYGIENE_REGEX="$(home_stack_hygiene_regex)"

cd "$ROOT_DIR"

violations=0
fail() {
  echo "FAIL: $*" >&2
  violations=$((violations + 1))
}

# ---------------------------------------------------------------------------
# 1. Identifier-literal scan.
# ---------------------------------------------------------------------------
# Repo-wide, now that Phase B has scrubbed the docs (docs/PUBLIC_RELEASE.md
# §5). Every tracked path is scanned except the exclusions below.
SCAN_PATHS=(
  .
)

# Excluded even though they are within SCAN_PATHS: fixtures/goldens carry
# synthetic (already-clean) data, not identifiers; profiles/default/ is
# named here in case a future exclusion needs to widen. This test and its
# pattern data necessarily discuss the identifiers themselves.
EXCLUDE_REGEX='^(profiles/default/|tests/fixtures/|tests/golden/)'

# LICENSE legitimately names the copyright holder by their real name -- that
# is not a leak, it is a legal requirement, and it is the one file in the
# repository that is expected to.

# The repo's own public URL is allowed to name itself.
ALLOWED_SUBSTRING='github.com/itsericqiu/home-stack'


while IFS= read -r -d '' f; do
  [[ "$f" == "$SELF" || "$f" == "tests/lib/hygiene-patterns.sh" ]] && continue
  [[ "$f" == "LICENSE" ]] && continue
  [[ "$f" =~ $EXCLUDE_REGEX ]] && continue
  [[ -f "$f" ]] || continue

  while IFS=: read -r lineno line; do
    [[ -z "$lineno" ]] && continue
    if [[ "$line" == *"$ALLOWED_SUBSTRING"* ]]; then
      stripped="${line//$ALLOWED_SUBSTRING/}"
      echo "$stripped" | grep -qE "$HYGIENE_REGEX" || continue
    fi
    # /Users/<placeholder> paths and allowed-domain/TLD emails are documented
    # examples, not leaks -- strip them and re-check before failing.
    stripped_line="$(home_stack_hygiene_strip_allowed "$line")"
    echo "$stripped_line" | grep -qE "$HYGIENE_REGEX" || continue
    fail "$f:$lineno: matches hygiene pattern: $line"
  done < <(grep -nE "$HYGIENE_REGEX" "$f" 2>/dev/null || true)
done < <(git ls-files -z -- "${SCAN_PATHS[@]}")

# ---------------------------------------------------------------------------
# 2. Tracked-path checks (repo-wide; enforced now, independent of Phase B).
# ---------------------------------------------------------------------------

# No tracked path under profiles/ other than profiles/default/.
while IFS= read -r f; do
  case "$f" in
    profiles/default/*) ;;
    *) fail "tracked path under profiles/ other than default/: $f" ;;
  esac
done < <(git ls-files -- profiles)

# No tracked generated artifact or per-machine settings file.
for f in \
  portable/home-stack/Caddyfile \
  portable/home-stack/catalog.json \
  .claude/settings.local.json; do
  if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    fail "tracked generated/per-machine file: $f"
  fi
done

# No tracked *.plist anywhere under portable/home-stack/ (engine-generated).
while IFS= read -r f; do
  case "$f" in
    *.plist) fail "tracked plist under portable/home-stack/: $f" ;;
  esac
done < <(git ls-files -- portable/home-stack)

# No tracked env.local, anywhere.
while IFS= read -r f; do
  case "$f" in
    */env.local|env.local) fail "tracked env.local: $f" ;;
  esac
done < <(git ls-files)

if (( violations > 0 )); then
  echo "FAIL: public-hygiene found $violations violation(s) above" >&2
  exit 1
fi

echo "PASS public-hygiene.test.sh"
