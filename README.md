# sk-icloud-keychain

iCloud キーチェーンに保存した ed25519 鍵を、各 Mac の Touch ID で解錠して SSH に使うための OpenSSH security key provider です。

- 鍵は iCloud キーチェーンで同期されるので、どの Mac でも**同じ鍵**を Touch ID で使えます。
- サーバからは普通の `sk-ssh-ed25519@openssh.com` 鍵に見えます。`verify-required` を付ければ、Touch ID を通らない署名は受け付けません。
- OpenSSH には手を加えません。`SecurityKeyProvider` で dylib を読み込ませるだけです。YubiKey などの FIDO 鍵と並べて使えます。

方式を選んだ経緯は [docs/SSH 鍵保護方式 4 案の比較.html](docs/SSH%20鍵保護方式%204%20案の比較.html)、全体の構成は [docs/architecture.html](docs/architecture.html)、provider と helper の間の通信は [docs/protocol.md](docs/protocol.md) にまとめてあります。

## 仕組み

```
ssh ─ ssh-sk-helper ─ libsk-icloud-keychain.dylib ──(パイプ)── sk-icloud-keychain.app
                       （署名不要・OpenSSH が読み込む）          （署名済み・Touch ID・Keychain）
```

- **provider（dylib）**: OpenSSH の sk-api（`sk_enroll` / `sk_sign` / `sk_load_resident_keys`）を実装します。Keychain には触れず、helper を起動して結果を返します。
- **helper（app）**: 鍵の生成と保存、Touch ID での本人確認、署名を担当します。同期するキーチェーン項目を扱うには `keychain-access-groups` の権限が要り、この権限はプロビジョニングプロファイル付きの署名でしか使えません。そのため helper だけは Apple Developer の Team で署名します。

app の中に dylib を同梱しているので、インストールすると次のパスに置かれます。

```
/Applications/sk-icloud-keychain.app/Contents/Frameworks/libsk-icloud-keychain.dylib
```

## 必要なもの

- macOS 14 以降と、Touch ID（内蔵、または Touch ID 付き Magic Keyboard）
- 普段の Apple Account で iCloud キーチェーンがオンになっていること
- Xcode と、Apple Developer Program に加入した Apple Account（helper の署名用）。普段の Apple Account と別のアカウントでかまいません
- OpenSSH 8.2 以降。Homebrew の 10.6p1 と、macOS 純正の 10.3 で動作を確認しています

Team ID は `FJYY683YHH` に固定しています。別の Team で使う場合は、`helper/SKICloudKeychain.xcodeproj` の `DEVELOPMENT_TEAM`、bundle ID、`docs/protocol.md` の access group を書き換えてください。access group には Team ID が含まれるので、**Team を変えると、それまでに作った鍵は読めなくなります。**

## インストール（Mac ごと）

1. Xcode に開発用 Apple Account でサインインします（Settings → Apple Accounts）。
2. 次を実行します。初回は Mac が端末として登録され、署名用の鍵を使ってよいかの確認ダイアログが出ます。ログインパスワードを入れて「常に許可」を選んでください。

```bash
make install
```

app は、ビルドした Mac 専用の署名になります（開発用プロファイルは登録した Mac でしか起動しません）。他の Mac にはコピーせず、それぞれの Mac で `make install` してください。`make` はビルドの宛先をその Mac にしているので、新しい Mac は自動で Team に登録されます。プロファイルの期限は 1 年なので、1 年ごとに `make install` をやり直します。

ビルド結果は `build/<ホスト名>/` に置かれます。リポジトリを Dropbox などで Mac の間で共有していても、互いのビルドを上書きしません。

helper が起動直後に `killed` になるときは、プロファイルにその Mac が入っていません。`/usr/bin/log show --last 5m --predicate 'eventMessage CONTAINS[c] "sk-icloud-keychain"'` に `Provisioning profile does not allow this device` と出ていれば、`~/Library/Developer/Xcode/UserData/Provisioning Profiles/` を空にしてから `make install` をやり直してください。

## 鍵を作る（最初の 1 回だけ）

```bash
ssh-keygen -t ed25519-sk -O resident -O verify-required \
    -O application=ssh:icloud \
    -w /Applications/sk-icloud-keychain.app/Contents/Frameworks/libsk-icloud-keychain.dylib \
    -f ~/.ssh/id_ed25519_sk_icloud
```

Touch ID を求められます。macOS 純正の `ssh-keygen` などが `Enter PIN for ED25519-SK key:` と聞いてくることがありますが、PIN は使わないので何も入力せずに進めてください。`~/.ssh/id_ed25519_sk_icloud` は鍵ファイルですが、中身は Keychain の項目を指す key handle と公開鍵だけで、秘密鍵は入っていません。

別の Mac では、`~/.ssh` を共有していればそのまま使えます。共有していない場合は、次のコマンドで鍵ファイルを作り直せます（Touch ID は不要です）。

```bash
cd ~/.ssh && ssh-keygen -K -w /Applications/sk-icloud-keychain.app/Contents/Frameworks/libsk-icloud-keychain.dylib
```

## ~/.ssh/config

`SecurityKeyProvider` は、**この鍵を使う Host にだけ**書いてください。`Host *` に書くと、YubiKey などの FIDO 鍵もこの provider に送られて使えなくなります。

```
Host myserver
    HostName myserver.example.com
    IdentityFile ~/.ssh/id_ed25519_sk_icloud
    SecurityKeyProvider /Applications/sk-icloud-keychain.app/Contents/Frameworks/libsk-icloud-keychain.dylib
```

provider のパスはどの Mac でも同じなので、`~/.ssh/config` を Mac の間で共有してもかまいません。

## サーバ側

`~/.ssh/authorized_keys` に公開鍵を 1 行登録します。`verify-required` を付けると、Touch ID を通った署名（UV フラグ付き）だけを受け付けます。

```
verify-required sk-ssh-ed25519@openssh.com AAAA... ssh:icloud
```

Mac を増やしても、サーバ側に鍵を追加する必要はありません。

## 鍵の管理

helper は、コマンドとしても直接使えます。

```bash
H=/Applications/sk-icloud-keychain.app/Contents/MacOS/sk-icloud-keychain
$H list                 # 保存している鍵の一覧（Touch ID 不要）
$H delete <UUID>        # 鍵を削除（Touch ID が必要。iCloud 経由で全 Mac から消えます）
```

`list` の `key_handle` は `skick1:<UUID>` を hex にしたものです。

## 安全性と制約

| 観点 | この方式での扱い |
|---|---|
| 秘密鍵を読めるもの | iCloud キーチェーン（E2E 暗号化）と、access group `FJYY683YHH.org.izawa.sk-icloud-keychain` に属する app、つまり同じ Team で署名した helper だけ |
| 本人確認 | helper が LocalAuthentication で Touch ID を求めます（生体認証のみ、パスワードでの代替なし）。これはソフトウェアでかけるゲートで、Secure Enclave が鍵の使用そのものを強制するわけではありません。生体認証の ACL を付けたキーチェーン項目は同期できないためです |
| helper を呼べるもの | 同じユーザーで動くプロセスなら helper を起動できます。ただし署名のたびに Touch ID が要り、ダイアログには鍵の application（`ssh:…`）が表示されます |
| 鍵の取り違え | 登録時と違う application での署名は拒否します |
| counter | Mac をまたいで単調増加しないので、Unix 時刻を入れています。sshd は既定では counter を見ません |
| 署名の期限 | 開発用プロファイルの期限は 1 年です。切れると helper が起動しなくなるので、`make install` をやり直します |
| アカウント | 開発用 Apple Account を失うと Team ID を引き継げず、鍵を作り直してサーバに登録し直すことになります |

## 開発

```bash
make            # dylib（テスト用）と helper app をビルド
make test       # 単体テストと、provider が読み込まれるかのテスト（Touch ID 不要）
tests/e2e.sh    # 鍵の作成・署名・検証・-K の通し確認（Touch ID が 2 回）
```

`SK_ICLOUD_KEYCHAIN_DEBUG=1` を設定すると、provider と helper が標準エラーに経過を出します。`SK_ICLOUD_KEYCHAIN_HELPER` で helper の場所を差し替えられます。

## ライセンス

MIT ライセンスです（[LICENSE](LICENSE)）。

ただし `provider/sk-api.h` は openssh-portable（V_10_6_P1）のファイルで、Google LLC の ISC ライセンス表記をそのまま残しています。
