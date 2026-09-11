#!/usr/bin/env bash
# Shared identifier patterns for public-hygiene leak scans.
#
# This file is tracked and public, so it carries only GENERIC CLASSES of
# identifier that apply to any home-stack deployment -- never the owner's own
# handle, domain, IP, name, or email. (It used to; that was itself a leak.
# See docs/PUBLIC_RELEASE.md §4 A3.) If you fork home-stack, these classes
# already cover you -- add your own specific identifiers to a PRIVATE file
# instead of here; see home_stack_hygiene_load_private below.
#
# Sourced by tests/public-hygiene.test.sh (the enforcement, over tracked
# files) and tests/profile-portability.test.sh (its own leak-scan of
# generated artifacts) so the pattern logic lives in exactly one file.

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "tests/lib/hygiene-patterns.sh must be sourced from bash, not another shell" >&2
  return 1 2>/dev/null || exit 1
fi

if [[ -n "${HOME_STACK_HYGIENE_PATTERNS_SH_LOADED:-}" ]]; then
  return 0
fi
HOME_STACK_HYGIENE_PATTERNS_SH_LOADED=1

# Generic-class identifier patterns (extended-regex fragments, grep -E):
#
#   - any Tailscale CGNAT address (100.64.0.0/10) EXCEPT 100.64.0.0/24, which
#     is this repo's documented example block -- README, ONBOARDING,
#     bootstrap.sh's placeholder, templates/profile.env.example, and every
#     test fixture under tests/fixtures/ use 100.64.0.x on purpose. The five
#     fragments below are the CGNAT range with that block carved out (POSIX
#     ERE has no negative lookahead, so the exception is expressed by
#     excluding it from the alternation rather than by a single "except"
#     clause).
#   - any *.ts.net Tailscale hostname.
#   - the literal string "settings.local" (per-machine Claude settings that
#     must never be tracked; see .claude/settings.local.json).
#   - a /Users/<name> path and an email address, both broad on purpose --
#     home_stack_hygiene_strip_allowed() below removes the documented
#     placeholder occurrences of each (alice, <owner>, example.com, an
#     admin@acme.test fixture email, ...) before a match is treated as a
#     real violation, since those appear throughout the docs and fixtures on
#     purpose.
HOME_STACK_HYGIENE_PATTERNS=(
  '100\.6[5-9]\.[0-9]{1,3}\.[0-9]{1,3}'
  '100\.[7-9][0-9]\.[0-9]{1,3}\.[0-9]{1,3}'
  '100\.1[01][0-9]\.[0-9]{1,3}\.[0-9]{1,3}'
  '100\.12[0-7]\.[0-9]{1,3}\.[0-9]{1,3}'
  '100\.64\.[1-9][0-9]{0,2}\.[0-9]{1,3}'
  '[A-Za-z0-9.-]+\.ts\.net'
  'settings\.local'
  '/Users/[A-Za-z0-9_.-]+'
  '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
)

# Placeholder /Users/<name> segments that are documented examples, not a
# leak -- keep in sync with every doc that uses one of these as an example
# home directory (RUNBOOK, PLAN, REMOTE_ACCESS, PUBLIC_RELEASE, ...).
HOME_STACK_HYGIENE_ALLOWED_USER_PATHS=(
  'REPLACE_ME' '<owner>' 'owner' 'example' 'alice' 'jane' 'test'
)

# home_stack_hygiene_regex
#
# Prints the patterns joined into one alternation, for callers that want a
# single `grep -E` pattern instead of looping the array. Includes the
# private patterns (if home_stack_hygiene_load_private has been called and
# found a file) so callers get one regex covering both.
home_stack_hygiene_regex() {
  local IFS='|'
  local all=("${HOME_STACK_HYGIENE_PATTERNS[@]}")
  if [[ ${#HOME_STACK_HYGIENE_PRIVATE_PATTERNS[@]} -gt 0 ]]; then
    all+=("${HOME_STACK_HYGIENE_PRIVATE_PATTERNS[@]}")
  fi
  echo "${all[*]}"
}

# home_stack_hygiene_load_private
#
# Loads the owner's own, untracked identifier patterns (handle, domain, IP,
# name, email, personal-project names -- whatever is specific to one
# deployment) from $HOME_STACK_HYGIENE_PATTERNS_FILE if set, else
# $HOME/.config/home-stack/hygiene-patterns.sh if it exists. The file is
# expected to declare a HOME_STACK_HYGIENE_PRIVATE_PATTERNS bash array. The
# owner keeps this file in their dotfiles overlay and links it into
# ~/.config/home-stack/, the same way their profile is linked in -- see
# docs/PUBLIC_RELEASE.md §4 A3/A4. Always prints one line saying whether a
# private file was loaded, so a test run's output says which mode it ran in.
HOME_STACK_HYGIENE_PRIVATE_PATTERNS=()
home_stack_hygiene_load_private() {
  local f="${HOME_STACK_HYGIENE_PATTERNS_FILE:-}"
  if [[ -z "$f" && -f "$HOME/.config/home-stack/hygiene-patterns.sh" ]]; then
    f="$HOME/.config/home-stack/hygiene-patterns.sh"
  fi
  if [[ -n "$f" && -f "$f" ]]; then
    # shellcheck disable=SC1090
    . "$f"
    echo "hygiene-patterns: loaded private pattern file: $f (${#HOME_STACK_HYGIENE_PRIVATE_PATTERNS[@]} pattern(s))"
  else
    echo "hygiene-patterns: no private pattern file loaded (set HOME_STACK_HYGIENE_PATTERNS_FILE, or place one at \$HOME/.config/home-stack/hygiene-patterns.sh)"
  fi
}

# home_stack_hygiene_strip_allowed <line>
#
# Prints $1 with every documented-placeholder occurrence removed: allowed
# /Users/<name> paths, email addresses on an allowed domain/TLD
# (example.com, example.local, any .test TLD), noreply-style addresses, and
# mentions of the "settings.local" filename itself. That last one is not an
# owner identifier at all -- it is the per-machine Claude settings file's own
# name, which this repository's docs, .gitignore, and CHANGELOG legitimately
# have to say out loud to document and enforce the "never track it" rule
# (tests/public-hygiene.test.sh's tracked-path check is what actually
# enforces that; this text scan would otherwise flag its own policy prose).
# A line that matches the regex above only because of one of these is not a
# real leak once stripped -- callers re-test the stripped line against the
# regex to decide.
home_stack_hygiene_strip_allowed() {
  local line="$1"
  local name
  for name in "${HOME_STACK_HYGIENE_ALLOWED_USER_PATHS[@]}"; do
    line="${line//\/Users\/$name/}"
  done
  line="${line//settings.local/}"
  line="$(printf '%s' "$line" | sed -E \
    -e 's/[A-Za-z0-9._%+-]+@(example\.com|example\.local)/ /g' \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.test/ /g' \
    -e 's/noreply[A-Za-z0-9._%+-]*@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/ /g')"
  printf '%s' "$line"
}

# home_stack_hygiene_scan_file <file>
#
# Prints "<lineno>:<original line>" for every line in <file> that still
# matches the hygiene regex after home_stack_hygiene_strip_allowed. Empty
# output means the file is clean. Callers should check output, not a
# `grep -q`-style exit code, since the stripping pass runs per line.
home_stack_hygiene_scan_file() {
  local f="$1" lineno=0 line stripped regex
  regex="$(home_stack_hygiene_regex)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    stripped="$(home_stack_hygiene_strip_allowed "$line")"
    if printf '%s' "$stripped" | grep -qE "$regex"; then
      printf '%s:%s\n' "$lineno" "$line"
    fi
  done < "$f"
}
