# wincolor (Linux版)

GNOME Shell (Wayland/X11) 上でウィンドウ単位に色枠＋タイトルバー色タグを付けるための
GNOME Shell 拡張機能 + CLI ラッパー。

## 構成

- `gnome-extension/` — GNOME Shell 拡張本体 (`window-color-tag@smart2j.jp`)。
  D-Bus (`jp.smart2j.WindowColorTag`) でウィンドウの色付けを公開する。
- `bin/wincolor` — 上記 D-Bus を叩く CLI ラッパー(bash + `gdbus`)。

## 方式

Wayland ネイティブウィンドウは外部プロセスから直接ウィンドウを装飾できないため、
GNOME Shell 拡張として動かし、mutter 内部の `window_group` に

- 枠(`St.Widget` + CSS border、幅3px・角丸14px)
- タイトルバー相当の色タイント(上端40px、半透明)

を重ねて表示し、`position-changed` / `size-changed` に追従させている。
CSD(クライアント側装飾)アプリはタイトルバー右クリックが効かないため、
`Super+C` で mutter ネイティブのキーバインドからウィンドウメニューを開けるようにしてある。

## 要件

- GNOME Shell(`shell-version` は現状 `50` を指定。動作確認したバージョンに合わせて
  `metadata.json` の `shell-version` を調整すること)
- `gdbus`(通常 `glib2` 系パッケージに含まれる)

## インストール(開発時 / ソースから)

```sh
# 1. 拡張機能を配置
mkdir -p ~/.local/share/gnome-shell/extensions/window-color-tag@smart2j.jp
cp -r linux/gnome-extension/* ~/.local/share/gnome-shell/extensions/window-color-tag@smart2j.jp/

# 2. gschema をコンパイル
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
wincolor <ID> <色>            # 指定ウィンドウに色を付ける (red, blue, #ff8800 など)
wincolor <ID> off             # 指定ウィンドウの色を消す
wincolor focused <色>         # フォーカス中のウィンドウに色 (キーバインド向け)
wincolor focused next|prev    # パレットを順送り/逆送り (末尾の次は色なし)
wincolor focused off
wincolor clear-all            # 全部消す
```

キーバインド(拡張が mutter に登録、Wayland ネイティブ窓でも効く):

- `Super+C` — フォーカス中ウィンドウのウィンドウメニューを開く(CSD 窓向け。色スウォッチ付き)
- `Super+X` — 色タグを順送り

タイトルバーが自前描画でないウィンドウは、タイトルバー右クリック(または Alt+Space)の
ウィンドウメニューにも色スウォッチの行が追加される。

## 既知の制約 / 未対応

- パレットは `gnome-extension/extension.js` 内の `PALETTE` 定数にハードコードされており、
  `shared/colors.json` とは未連携(Windows版はここを参照して色を読み込んでいる)。
- KDE / Wayland 他コンポジタは未対応(`docs/spec.md` の想定どおり GNOME 拡張前提)。
- gschema のコンパイル済みバイナリ (`schemas/gschemas.compiled`) はリポジトリに含めていない。
  インストール手順の `glib-compile-schemas` で生成すること。
