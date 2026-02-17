#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/commit_agent"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

remote="$tmp/remote.git"
work="$tmp/work"

git init --bare "$remote" >/dev/null
git clone "$remote" "$work" >/dev/null 2>&1

git -C "$work" config user.name "commit-agent-test"
git -C "$work" config user.email "commit-agent-test@example.com"
git -C "$work" checkout -b main >/dev/null 2>&1

cat >"$work/watched.txt" <<'EOF'
line-1
line-2
line-3
EOF

git -C "$work" add watched.txt
git -C "$work" commit -m "init" >/dev/null
git -C "$work" push -u origin main >/dev/null 2>&1

# +9 lines: should not commit with min-growth=10
for i in $(seq 1 9); do
  printf 'grow-a-%s\n' "$i" >>"$work/watched.txt"
done

set +e
out="$("$SCRIPT" --repo "$work" --trigger-file watched.txt --min-growth 10 2>&1)"
st=$?
set -e
if [[ $st -ne 10 ]]; then
  echo "expected exit 10 for growth < 10; got $st; out=$out" >&2
  exit 1
fi
echo "$out" | rg -q -- "нечего коммитить"

# Add one more line (+10 total) and one extra file to ensure add -A behavior
printf 'grow-a-10\n' >>"$work/watched.txt"
printf 'hello\n' >"$work/extra.txt"

out="$("$SCRIPT" --repo "$work" --trigger-file watched.txt --min-growth 10 --push 2>&1)"
echo "$out" | rg -q -- "^ok:"

last_msg="$(git -C "$work" log -1 --pretty=%s)"
echo "$last_msg" | rg -q -- "^auto\\(commit\\): watched.txt \\+10 lines$"

# Ensure extra file was included in the auto-commit
git -C "$work" show --name-only --pretty=format: HEAD | rg -q -- "^extra.txt$"
git -C "$work" show --name-only --pretty=format: HEAD | rg -q -- "^watched.txt$"

# Ensure push happened
local_head="$(git -C "$work" rev-parse HEAD)"
remote_head="$(git --git-dir "$remote" rev-parse main)"
if [[ "$local_head" != "$remote_head" ]]; then
  echo "expected remote main to match local HEAD after auto-push" >&2
  exit 1
fi

# Clean tree: should print "нечего коммитить"
set +e
out="$("$SCRIPT" --repo "$work" --trigger-file watched.txt --min-growth 10 2>&1)"
st=$?
set -e
if [[ $st -ne 10 ]]; then
  echo "expected exit 10 for clean tree; got $st; out=$out" >&2
  exit 1
fi
echo "$out" | rg -q -- "нечего коммитить"

# Repo-only mode (no trigger-file): commit any project change
printf 'repo-only-change\n' >"$work/repo_only.txt"
out="$("$SCRIPT" --repo "$work" --push 2>&1)"
echo "$out" | rg -q -- "^ok:"
last_msg="$(git -C "$work" log -1 --pretty=%s)"
echo "$last_msg" | rg -q -- "^auto\\(commit\\): project changes$"

# Repo-only mode on clean tree
set +e
out="$("$SCRIPT" --repo "$work" --push 2>&1)"
st=$?
set -e
if [[ $st -ne 10 ]]; then
  echo "expected exit 10 for clean tree in repo-only mode; got $st; out=$out" >&2
  exit 1
fi
echo "$out" | rg -q -- "нечего коммитить"

echo "OK"
