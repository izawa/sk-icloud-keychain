# Provider ⇄ helper protocol

The provider dylib (`provider/`) runs inside OpenSSH's `ssh-sk-helper` and
cannot use the synchronizable keychain itself (it has no entitlements). It
spawns the signed helper app's executable with fresh pipes — never the
inherited stdin/stdout, which carry `ssh-sk-helper`'s own protocol — and
exchanges one request and one response:

```
sk-icloud-keychain.app/Contents/MacOS/sk-icloud-keychain <command>
```

Messages are UTF-8 lines of `key=value`. Byte strings are hex; text values
never contain newlines. The request is read until EOF. The helper writes only
protocol messages to stdout; diagnostics go to stderr, and only when
`SK_ICLOUD_KEYCHAIN_DEBUG` is set.

## Commands

| command  | request fields                                  | response fields (on success)                     | Touch ID |
|----------|-------------------------------------------------|--------------------------------------------------|----------|
| `enroll` | `application`, `flags` (1 byte), optional `user` | `public_key` (32 B), `key_handle`, `flags`      | yes      |
| `sign`   | `application`, `key_handle`, `flags`, `data`    | `signature` (64 B), `flags` (1 byte), `counter` (decimal) | yes |
| `list`   | (none; stdin is not read)                       | `count`, then `N.application`, `N.flags`, `N.public_key`, `N.key_handle`, optional `N.user` | no |

`user` is the `-O user=` value from ssh-keygen (at most 31 bytes). Like
sk-usbhid, `enroll` of a resident key fails with `SSH_SK_ERR_CREDENTIAL_EXISTS`
when one already exists for the same application and user, unless the
`SSH_SK_FORCE_OPERATION` flag is set. The provider returns `user` to OpenSSH
as a zero-padded 32-byte user id.

## Locating the helper

The provider runs the first executable it finds among:

1. `$SK_ICLOUD_KEYCHAIN_HELPER`
2. `/Applications/sk-icloud-keychain.app/Contents/MacOS/sk-icloud-keychain`
3. `~/Applications/sk-icloud-keychain.app/Contents/MacOS/sk-icloud-keychain`

If none exists, it returns `SSH_SK_ERR_DEVICE_NOT_FOUND`.

Every response ends with `status=ok`, or is `status=error`, `error=<code>`,
`message=<text>` where `<code>` is an `SSH_SK_ERR_*` value from `sk-api.h`.

`delete <uuid>` is for interactive use only and prints plain text.

## Signing

`sign` hashes `data` itself and signs, with the stored ed25519 key,

```
SHA256(application) || flags || counter (big-endian u32) || SHA256(data)
```

as OpenSSH's `sk-dummy` does. The response flags are always
`UP|UV` (0x05) because Touch ID has verified the user; the counter is the
current Unix time, which sshd ignores by default.

The helper refuses to sign when `application` differs from the one recorded
at enrollment.

## Key handle and storage

`key_handle` is the ASCII string `skick1:<UUID>`. The private key is a
synchronizable generic-password item in the data-protection keychain:

| attribute         | value                                                      |
|-------------------|------------------------------------------------------------|
| service           | `org.izawa.sk-icloud-keychain.key`                         |
| account           | the UUID                                                   |
| access group      | `FJYY683YHH.org.izawa.sk-icloud-keychain`                  |
| accessible        | `WhenUnlocked` (synchronizable)                            |
| value data        | raw 32-byte ed25519 private key                            |
| generic attribute | property list: version, application, flags, public key, created |

`list` reads only attributes, never the private key.
