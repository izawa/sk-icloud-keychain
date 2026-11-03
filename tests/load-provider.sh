#!/bin/sh
# Check that OpenSSH loads the provider and reaches the helper lookup in
# sk_enroll. Uses a missing helper so no key is created and no Touch ID is
# needed.
set -eu

dylib=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
keygen=${SSH_KEYGEN:-/opt/homebrew/bin/ssh-keygen}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

nm -gU "$dylib" | grep -q '_sk_api_version$'

SK_ICLOUD_KEYCHAIN_DEBUG=1 SK_ICLOUD_KEYCHAIN_HELPER="$tmp/no-such-helper" \
    "$keygen" -q -t ed25519-sk -w "$dylib" -N '' -f "$tmp/key" \
    >"$tmp/out" 2>&1 && status=0 || status=$?
cat "$tmp/out"

if [ "$status" -eq 0 ]; then
	echo "FAIL: enroll unexpectedly succeeded" >&2
	exit 1
fi
if ! grep -q 'sk-icloud-keychain: run_helper: helper app not found' "$tmp/out"; then
	echo "FAIL: provider was not called" >&2
	exit 1
fi
echo "OK: provider loaded and sk_enroll looked for the helper"
