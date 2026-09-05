# wincolor (Linux版)

GNOME Shell (Wayland/X11) 上でウィンドウ単位に色枠＋タイトルバー色タグを付けるための
GNOME Shell 拡張機能 + CLI ラッパー。

## 構成

- `gnome-extension/` — GNOME Shell 拡張本体 (`window-color-tag@smart2j.jp`)。
  D-Bus (`jp.smart2j.WindowColorTag`) でウィンドウの色付けを公開する。
- `bin/wincolor` — 上記 D-Bus を叩く CLI ラッパー(bash + `gdbus`)。
- 色プリセットはリポジトリ共通の `shared/colors.json` を使う(`install.sh` が拡張ディレクトリに
  コピーする。リポジトリから直接読み込ませる場合は `../../shared/colors.json` も探索する)。

## 方式

Wayland ネイティブウィンドウは外部プロセスから直接ウィンドウを装飾できないため、
GNOME Shell 拡張として動かし、mutter 内部の `window_group` に

- 枠(`St.Widget` + CSS border、幅3px・角丸14px)
- タイトルバー相当の色タイント(上端40px、半透明)

を重ねて表示し、`position-changed` / `size-changed` に追従させている。
CSD(クライアント側装飾)アプリはタイトルバー右クリックが効かないため、
`Super+C` で mutter ネイティブのキーバインドからウィンドウメニューを開けるようにしてある。

## 要件

- GNOME Shell 50 または 51(`metadata.json` の `shell-version` は `50` と `51`)。
  50 は実機確認済み、51 は 51.rc のソースで依存 API の不変を確認したのみ(実機未確認)。
  GNOME 45〜49 は未確認、44 以前は ESM 非対応のため不可。
  対応ディストリビューションの一覧はリポジトリ直下の README.md「対応環境 (Linux 版)」を参照
- `gdbus`(通常 `glib2` 系パッケージに含まれる)
- KDE / Xfce など GNOME Shell 以外のデスクトップは非対応

## インストール(ワンライナー)

```sh
curl -fsSL https://raw.githubusercontent.com/tryandhappy/wincolor/main/linux/get.sh | bash
```

`get.sh` が GitHub Releases から最新の Linux 版バンドル zip を取得し、`install.sh` を実行する
(拡張の配置・gschema コンパイル・CLI の `~/.local/bin` 配置・自動ルール雛形の配置・拡張の有効化)。
終わったら GNOME Shell を再起動する(X11: Alt+F2 → r / Wayland: ログアウト → ログイン)。

```sh
# バージョンを指定
curl -fsSL https://raw.githubusercontent.com/tryandhappy/wincolor/main/linux/get.sh | WINCOLOR_VERSION=0.2.2 bash
# アンインストール (~/.config/wincolor は残る)
curl -fsSL https://raw.githubusercontent.com/tryandhappy/wincolor/main/linux/get.sh | bash -s -- --uninstall
# CLI の配置先を変更
curl -fsSL https://raw.githubusercontent.com/tryandhappy/wincolor/main/linux/get.sh | PREFIX=/usr/local/bin bash
```

必要なもの: `curl`(または `wget`)、`unzip`、GNOME Shell 50 / 51。

## インストール(リリース zip から)

[Releases](../../../releases) の `wincolor-linux-vX.Y.Z.zip` を展開して `install.sh` を実行する
(上のワンライナーが内部で行っているのと同じ手順)。
拡張の配置・gschema コンパイル・CLI の `~/.local/bin` 配置・拡張の有効化までを行う。

```sh
unzip wincolor-linux-vX.Y.Z.zip && cd wincolor
./install.sh                # PREFIX=/path で CLI の配置先変更可
# GNOME Shell を再起動 (X11: Alt+F2 -> r / Wayland: ログアウト -> ログイン)
./install.sh --uninstall    # アンインストール
```

拡張だけ入れる場合は `wincolor-linux-vX.Y.Z-extension.zip` を
`gnome-extensions install <zip>` で導入し、`bin/wincolor` を手動で PATH に置く。

ソースツリーの `linux/install.sh` を直接実行しても同じ結果になる。

## インストール(手動 / ソースから)

```sh
# 1. 拡張機能を配置
mkdir -p ~/.local/share/gnome-shell/extensions/window-color-tag@smart2j.jp
cp -r linux/gnome-extension/* ~/.local/share/gnome-shell/extensions/window-color-tag@smart2j.jp/

# 2. 色プリセットを同梱し、gschema をコンパイル
cp shared/colors.json ~/.local/share/gnome-shell/extensions/window-color-tag@smart2j.jp/
glib-compile-schemas ~/.local/share/gnome-shell/extensions/window-color-tag@smart2j.jp/schemas/

# 3. 拡張を有効化
gnome-extensions enable window-color-tag@smart2j.jp
# X11 なら Alt+F2 -> r -> Enter でシェル再起動、Wayland ならログアウト/ログイン

# 4. CLI ラッパーを PATH に配置
mkdir -p ~/.local/bin
cp linux/bin/wincolor ~/.local/bin/wincolor
chmod +x ~/.local/bin/wincolor
```

## 使い方

```sh
wincolor list                 # ウィンドウ一覧 (ID / クラス / 現在の色 / タイトル)
wincolor colors               # 使える色プリセット一覧 (名前 / ラベル / HEX)
wincolor <ID> <色>            # 指定ウィンドウに色を付ける (プリセット名 red, 青 など、または #RRGGBB)
wincolor <ID> off             # 指定ウィンドウの色を消す
wincolor focused <色>         # フォーカス中のウィンドウに色 (キーバインド向け)
wincolor focused next|prev    # パレットを順送り/逆送り (末尾の次は色なし)
wincolor focused off
wincolor clear-all            # 全部消す
wincolor run <色> <コマンド...>  # コマンドを起動し、そのウィンドウに色を付ける (ランチャー)
wincolor rules                # 読み込み済みの自動ルール一覧
wincolor reload               # colors.json / rules.json を再読み込み
```

キーバインド(拡張が mutter に登録、Wayland ネイティブ窓でも効く):

- `Super+C` — フォーカス中ウィンドウのウィンドウメニューを開く(CSD 窓向け。色スウォッチ付き)
- `Super+X` — 色タグを順送り

タイトルバーが自前描画でないウィンドウは、タイトルバー右クリック(または Alt+Space)の
ウィンドウメニューにも色スウォッチの行が追加される。

## 自動ルール

`~/.config/wincolor/rules.json`(`install.sh` が雛形を置く。形式は Windows 版と共通の
`shared/rules.json`)にルールを書くと、条件に合う新しいウィンドウへ自動で色が付く:

```json
{
  "rules": [
    { "title": "本番|prod", "color": "red" },
    { "exe": "keepass", "color": "purple" },
    { "title": "ステージング", "exe": "chrome|firefox", "color": "orange" }
  ]
}
```

- `title` / `exe` は正規表現(大文字小文字無視)。片方だけでも可。両方書いた場合は両方一致で適用。上のルールが優先
- `exe` はプロセス名(`/proc/<pid>/exe` の basename、読めなければ `comm`)と WM_CLASS
  (Wayland の app-id。`wincolor list` の 2 列目)のどちらかに一致すればよい
- `color` はプリセット名 / ラベル / `#RRGGBB`
- 手動で色を付けた・消したウィンドウ、一度ルールで色が付いたウィンドウには再適用しない
  (タイトルが変わっても色は変わらない)
- ファイルを保存すると自動で再読み込みされる(`wincolor reload` で明示的にも可)。
  読み込み元と件数は `wincolor rules` で確認できる。不正な正規表現や未知の色のルールは
  スキップされ、`journalctl --user -f -o cat /usr/bin/gnome-shell` に警告が出る
- 探索順は `~/.config/wincolor/rules.json` → 拡張ディレクトリ → リポジトリの `shared/rules.json`

## ショートカットから色付きで起動(ランチャー)

```sh
wincolor run red ssh-terminal user@prod-server
wincolor run 青 firefox --new-window https://staging.example.com
```

コマンドをバックグラウンドで起動し、そのウィンドウが現れたら色を付けて終了する
(結果は標準出力に出る)。`.desktop` ファイルに書けばアプリ一覧やドックからも使える:

```ini
[Desktop Entry]
Type=Application
Name=Firefox (本番)
Exec=wincolor run red firefox --new-window https://prod.example.com
Icon=firefox
```

- 対象ウィンドウの判定は「起動したプロセスの PID と一致」または「その子孫プロセス」
  (Flatpak / Snap / ラッパースクリプト経由でも追える)
- PID を引き継がないアプリ(gnome-terminal のように既存サーバに窓を作らせるもの、
  既に起動中の Chrome / Firefox など)は、起動後に現れた最初の新規ウィンドウに付ける
  (一致する窓を 1.5 秒待ってから)。同時に別のウィンドウが開くと取り違えることがある
- 既定 10 秒待って窓が出なければ諦める(`WINCOLOR_RUN_TIMEOUT=30 wincolor run ...` で変更)
- ランチャーで付けた色は手動操作扱いとなり、自動ルールで上書きされない

## 既知の制約 / 未対応

- 色は `shared/colors.json` のプリセット(名前・ラベル)か `#RRGGBB` のみ受け付ける。
  CSS 色名(`tomato` 等)は使えない。`#RRGGBB` がプリセットと一致すればその名前で表示される。
- ウィンドウメニューの色スウォッチは 8 個ずつ折り返して表示する(22 色 + 消すボタン)。
- KDE / Wayland 他コンポジタは未対応(`docs/spec.md` の想定どおり GNOME 拡張前提)。
- gschema のコンパイル済みバイナリ (`schemas/gschemas.compiled`) はリポジトリに含めていない。
  `install.sh` またはインストール手順の `glib-compile-schemas` で生成すること
  (リリースの拡張 zip には同梱済み)。

## リリース

1. `gnome-extension/metadata.json` の `version-name` と `bin/wincolor` の `WINCOLOR_VERSION` を更新
2. `git tag linux-vX.Y.Z && git push origin main --tags`

GitHub Actions が検証(構文チェック・gschema コンパイル・install.sh のスモークテスト)を行い、
上記 2 種類の zip を添付した Release を作成する。バージョンがタグと一致しないと失敗する。
