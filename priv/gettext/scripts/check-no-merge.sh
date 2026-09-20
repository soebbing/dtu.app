#!/usr/bin/env bash
#
# Guard against `mix gettext.merge` being run as part of a PR.
#
# `mix gettext.merge` is the documented way to import new msgids from
# the .pot template into the per-locale .po catalogs, but in practice
# it silently reorders entries, drops fuzzy flags, and cross-
# contaminates locale catalogs (see memory note
# `dtu-app-gettext-merge-trap` and PR #322 for the original incident
# that broke 17 dashboard snapshot tests).
#
# The project discipline is: when a new msgid needs adding, hand-
# append it to the relevant locale's .po file at the bottom and skip
# the merge step. The discipline is hard to enforce by review alone —
# this script makes the rule a CI gate.
#
# Detection strategy: `mix gettext.merge` reorders .po entries. The
# hand-append discipline preserves the existing order — every msgid
# in the .po file appears in the same relative order as in the .pot
# template (with hand-added entries tacked on at the end). The script
# extracts the msgid sequence from each touched .po file and compares
# it against the corresponding .pot sequence; any deviation is a sign
# of merge-style reordering.
#
# Touched files are detected via `git diff --name-only` against the
# merge-base with `origin/$GITHUB_BASE_REF` (i.e. the files changed in
# this PR). Unrelated .po files are not checked, so a routine hand-
# append to one locale doesn't trip the guard.
#
# Exit code: 0 if all touched .po files preserve the .pot ordering;
# 1 otherwise. The CI step that runs this script should `fail-on-
# error` to make a violation a hard build break.

set -euo pipefail

# Resolve repo root (handles being run from any CWD).
repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# Touched files relative to repo root. Use the merge-base with the
# PR's base branch so we see PR-only changes; on `pull_request` runs
# GITHUB_BASE_REF is the target branch. CI's `actions/checkout@v4`
# defaults to `fetch-depth: 1` so the base ref isn't fetched by
# default — try to fetch it, fall back to HEAD's parent commit if
# the ref isn't resolvable (e.g. a shallow clone or a `push` event
# with no base).
if [ -n "${GITHUB_BASE_REF:-}" ]; then
    base_ref="origin/${GITHUB_BASE_REF}"
    git fetch --depth=2 origin "$base_ref" >/dev/null 2>&1 || true
    if git rev-parse --verify --quiet "$base_ref" >/dev/null; then
        base_sha="$(git merge-base HEAD "$base_ref")"
    else
        base_sha="HEAD~1"
    fi
else
    base_sha="HEAD~1"
fi

touched_po_files=$(git diff --name-only "$base_sha"...HEAD -- \
    'priv/gettext/*/LC_MESSAGES/*.po' || true)

if [ -z "$touched_po_files" ]; then
    echo "no .po files changed in this PR — nothing to check"
    exit 0
fi

violations=0

for po_file in $touched_po_files; do
    # Layout: priv/gettext/<catalog>.pot is the source-of-truth
    # template, and priv/gettext/<locale>/LC_MESSAGES/<catalog>.po
    # is each locale's catalog. Derive the catalog name from the
    # basename; the .pot lives one level up from the locale dir.
    catalog="$(basename "$po_file" .po)"
    locale_dir="$(dirname "$(dirname "$po_file")")"
    gettext_root="$(dirname "$locale_dir")"
    pot_file="${gettext_root}/${catalog}.pot"

    if [ ! -f "$pot_file" ]; then
        echo "::warning file=$po_file::no matching .pot template at $pot_file — skipping"
        continue
    fi

    # Extract msgid sequences, ignoring the header msgid "".
    po_msgids=$(mktemp)
    pot_msgids=$(mktemp)
    trap 'rm -f "$po_msgids" "$pot_msgids"' EXIT

    grep '^msgid ' "$po_file" \
        | grep -v '^msgid ""$' \
        | sed 's/^msgid "//;s/"$//' \
        > "$po_msgids"
    grep '^msgid ' "$pot_file" \
        | grep -v '^msgid ""$' \
        | sed 's/^msgid "//;s/"$//' \
        > "$pot_msgids"

    # The .po file is allowed to have entries that the .pot does not
    # (hand-appended msgids that the next `mix gettext.extract` will
    # surface). The relative order of entries that DO appear in both
    # must match — that's the "no merge happened" signature.
    common_msgids=$(mktemp)
    trap 'rm -f "$po_msgids" "$pot_msgids" "$common_msgids"' EXIT

    # Sort msgids that appear in both — the intersection. The .po
    # ordering should match the .pot ordering when projected onto
    # this common set.
    comm -12 <(sort "$pot_msgids") <(sort "$po_msgids") > "$common_msgids"

    # Project the .po sequence down to the common set, in the order
    # the .po lists them, and compare to the .pot projection.
    po_projection=$(grep -Fx -f "$common_msgids" "$po_msgids")
    pot_projection=$(grep -Fx -f "$common_msgids" "$pot_msgids")

    if [ "$po_projection" != "$pot_projection" ]; then
        echo
        echo "❌ $po_file: msgid ordering diverges from $pot_file"
        echo "   (signature of \`mix gettext.merge\` having been run —"
        echo "    hand-append new entries instead; see memory note"
        echo "    dtu-app-gettext-merge-trap.)"
        echo
        diff <(echo "$pot_projection") <(echo "$po_projection") | head -40 || true
        violations=$((violations + 1))
    else
        echo "✓ $po_file: msgid ordering matches $pot_file"
    fi
done

if [ "$violations" -gt 0 ]; then
    echo
    echo "ERROR: $violations .po file(s) have merge-style reordering."
    echo "Hand-append new msgids instead of running \`mix gettext.merge\`."
    exit 1
fi

echo
echo "All touched .po files preserve .pot ordering — guard passed."
