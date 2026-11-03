#!/bin/sh
# End-to-end check through OpenSSH: enroll a resident key, sign with
# ssh-keygen -Y sign, verify, then re-download it with ssh-keygen -K.
# Needs Touch ID twice. Leaves the key in iCloud Keychain; remove it with
#   sk-icloud-keychain delete <uuid>
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
keygen=${SSH_KEYGEN:-/opt/homebrew/bin/ssh-keygen}
app=ssh:sk-icloud-keychain-e2e-$(date +%s)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

build="$root/build/$(hostname -s)"   # same as BUILD in the Makefile
export SSH_SK_PROVIDER="$build/libsk-icloud-keychain.dylib"
export SK_ICLOUD_KEYCHAIN_HELPER=${SK_ICLOUD_KEYCHAIN_HELPER:-$build/xcode/Build/Products/Release/sk-icloud-keychain.app/Contents/MacOS/sk-icloud-keychain}
cd "$tmp"

echo "== enroll $app (Touch ID)"
"$keygen" -q -t ed25519-sk -O resident -O verify-required -O "application=$app" \
    -C e2e -N '' -f key

echo "== sign (Touch ID)"
echo "sk-icloud-keychain e2e" > msg
"$keygen" -q -Y sign -f key -n file msg

echo "e2e namespaces=\"file\" $(cut -d' ' -f1,2 key.pub)" > allowed
"$keygen" -Y verify -f allowed -I e2e -n file -s msg.sig < msg
echo tampered >> msg
if "$keygen" -Y verify -f allowed -I e2e -n file -s msg.sig < msg >/dev/null 2>&1; then
	echo "FAIL: tampered message verified" >&2
	exit 1
fi

echo "== download resident keys"
mkdir rk && cd rk
"$keygen" -q -K -N '' -w "$SSH_SK_PROVIDER" 2>/dev/null
if ! cat ./*.pub | cut -d' ' -f1,2 | grep -qxF "$(cut -d' ' -f1,2 ../key.pub)"; then
	echo "FAIL: enrolled key not returned by ssh-keygen -K" >&2
	exit 1
fi
echo "OK: enroll, sign, verify and resident key download work ($app)"
