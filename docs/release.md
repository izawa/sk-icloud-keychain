# リリースの手順

公証済みの DMG を作り、GitHub Releases で配布する手順。作者向け。
証明書と公証の認証情報は Rawgenzo・HanaLima と共通(Rawgenzo の `docs/release.md`)。この文書には、sk-icloud-keychain だけの違いを中心に書く。

## Rawgenzo・HanaLima との違い

helper は同期するキーチェーン項目を扱うために `keychain-access-groups` を使う。この権限はプロビジョニングプロファイルがないと効かないので、**Developer ID 用のプロビジョニングプロファイル**を入れて署名する。
ビルドは Xcode のプロジェクトなので、`xcodebuild archive` で作り、`-exportArchive`(method `developer-id`)で Developer ID の署名とプロファイルに差し替える。

配布版は、いつも作者の Team と bundle ID で署名する。鍵の置き場所は `FJYY683YHH.org.izawa.sk-icloud-keychain` になり、作者が `make install` で使ってきた鍵と同じ場所になる(2026-11-10 に、配布版の helper で既存の 6 つの鍵の `list` と `ssh` でのログインを確かめた)。

## 前もって要るもの

| もの | 中身 | 確かめ方 |
|---|---|---|
| 署名の ID | `Developer ID Application: Yukimitsu Izawa (FJYY683YHH)` の証明書と秘密鍵(ログインキーチェーン) | `security find-identity -v -p codesigning` に出る |
| 公証の認証情報 | プロファイル名 `developer-id-notary`(ログインキーチェーン) | `xcrun notarytool history --keychain-profile developer-id-notary` が終了コード 0 |
| App ID | `org.izawa.sk-icloud-keychain`(Explicit、Capabilities なし) | developer.apple.com の Identifiers |
| プロビジョニングプロファイル | `sk-icloud-keychain Developer ID`(種類 Developer ID、Mac)。`keychain-access-groups` に `FJYY683YHH.*` | `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` にあること |

プロファイルが無い Mac では、developer.apple.com の Profiles からダウンロードし、次のように置く。

```sh
uuid=$(security cms -D -i <ダウンロードしたファイル> | plutil -extract UUID raw -o - -)
cp <ダウンロードしたファイル> ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/$uuid.provisionprofile
```

中身の確かめ: `security cms -D -i <プロファイル> | plutil -extract Entitlements xml1 -o - -`

## 手順

1. **バージョンを上げる。** `helper/SKICloudKeychain.xcodeproj/project.pbxproj` の `MARKETING_VERSION` を書き換えてコミットする。アイコンを変えたときは `CURRENT_PROJECT_VERSION` も上げる(README の「開発」)。
2. **テストを通す。** `make test`。署名や helper を変えたときは `tests/e2e.sh` も流す(Touch ID が 2 回)。
3. **DMG を作る。** 作業ツリーにコミットしていない変更があると止まる。
   ```sh
   scripts/release.sh
   ```
   archive・Developer ID での書き出し・access group の確かめ・DMG の作成と署名・公証・staple・確かめを順に行う。
   できるのは `build/<ホスト名>/release/sk-icloud-keychain-<版>.dmg`。最後に SHA-256 が表示される。
   Apple に送らずに署名までを試すときは `--no-notarize` を付ける。
4. **自分の Mac に入れる。** `build/<ホスト名>/release/export/sk-icloud-keychain.app` を `/Applications` に入れ、`sk-icloud-keychain list` と `ssh` で確かめる。
5. **タグを付けて push し、リリースを下書きで作る。** タグは DMG を作ったコミットに付ける。
   ```sh
   git tag -a v<版> -m "sk-icloud-keychain <版>"
   git push origin master v<版>
   gh release create v<版> build/<ホスト名>/release/sk-icloud-keychain-<版>.dmg --draft --verify-tag --title "sk-icloud-keychain <版>" --notes-file <本文>
   ```
6. **見てから公開し、ダウンロードし直して確かめる。** `shasum -a 256`・`xcrun stapler validate`・`spctl -a -t open --context context:primary-signature -v` の 3 つ。ブラウザでダウンロードした DMG から入れて起動することも確かめる。

## リリース本文に書くこと

- 何をするものか。DMG 版の鍵の置き場所は作者の Team(`FJYY683YHH`)で、作者が署名した app を信頼することになること。避けたい人は自分でビルドできること
- 動作環境: macOS 14 以降、Touch ID、iCloud キーチェーン、OpenSSH 8.2 以降
- インストール: DMG を開いて Applications へドラッグ → README の「鍵を作る」へ
- ダウンロードしたファイルの確認: SHA-256 と `shasum -a 256 ~/Downloads/sk-icloud-keychain-<版>.dmg`

## 証明書を作り直したとき

Developer ID Application の証明書は毎年切れる(いまのものは 2027-12-10。作り直し方は Rawgenzo の `docs/release.md`)。
プロファイルの中には署名に使う証明書が書き込まれているので、証明書を作り直したら、**プロファイルも新しい証明書で作り直す**(Profiles で編集して証明書を選び直すか、作り直す)。そのあと、上の手順で Xcode の置き場所に入れ直す。

**確かめていないこと:** 署名した証明書が切れたあと(2027-12-10 以降)も、配布済みの helper が起動し続けるか。Rawgenzo や HanaLima と違ってプロファイルを使うので、macOS がプロファイルの中の証明書の期限を見る可能性がある。2027-12 に確かめ、だめなら新しい証明書で作り直した版を出す。
