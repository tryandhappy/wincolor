# wincolor (macOS版)

ウィンドウ単位に色枠＋タイトルバー色帯を付けるメニューバー常駐アプリ + CLI(Swift)。

## 方式

macOS には他アプリのタイトルバー色を変える公開 API がないため、対象ウィンドウに追従する
**クリック透過のオーバーレイ窓**(枠 3pt、角丸、上端 28pt に半透明の色帯)を重ねる。

- `CGWindowListCopyWindowInfo` で全ウィンドウの位置と Z 順を 50ms ごとに取得し、
  オーバーレイを対象の**直上**に `order(.above, relativeTo:)` で置く(Windows 版と同じ考え方)
- 最小化・別 Space・全画面などで対象が画面上に無いときはオーバーレイを隠す
- タイトルは Accessibility API(`AXUIElement`)で取得する。**アクセシビリティ権限が必要**
  (画面収録の権限は不要)
- 常駐 ⇄ CLI は `CFMessagePort`(`jp.smart2j.wincolor`)で通信する

## 要件

- macOS 13 (Ventura) 以降
- アクセシビリティ権限(システム設定 → プライバシーとセキュリティ → アクセシビリティ)。
  タイトル取得と Ctrl+右クリックの横取りに使う。無くてもメニューバーと CLI(ID 指定)は動く

## インストール

Releases の `wincolor-macos-vX.Y.Z.zip` を展開して `install.sh` を実行する。

```sh
unzip wincolor-macos-vX.Y.Z.zip && cd wincolor
./install.sh              # ~/.local/bin/wincolor に配置し、LaunchAgent で常駐を起動
./install.sh --uninstall  # アンインストール (~/.config/wincolor は残る)
```

ソースからビルドする場合(Xcode Command Line Tools が必要):

```sh
cd macos && swift build -c release && ./install.sh
```

## 使い方

- 対象ウィンドウの**タイトルバーを Ctrl+右クリック** → 色メニュー(Windows 版と同じ操作)
- **メニューバーのアイコン** → 「ウィンドウ一覧から着色…」
- CLI:

```sh
wincolor list                 # ウィンドウ一覧 (ID / アプリ / 現在の色 / タイトル)
wincolor colors               # 使える色プリセット一覧 (名前 / ラベル / HEX)
wincolor <ID> <色>            # 指定ウィンドウに色を付ける (プリセット名 red, 青 など、または #RRGGBB)
wincolor <ID> off             # 指定ウィンドウの色を消す
wincolor focused <色>         # 最前面ウィンドウに色
wincolor focused next|prev    # パレットを順送り/逆送り (末尾の次は色なし)
wincolor clear-all            # 全部消す
wincolor run <色> <アプリ|コマンド...>  # 起動してそのウィンドウに色を付ける (ランチャー)
wincolor rules                # 読み込み済みの自動ルール一覧
wincolor reload               # colors.json / rules.json を再読み込み
```

### 自動ルール

`~/.config/wincolor/rules.json`(`install.sh` が雛形を置く。形式は共通の `shared/rules.json`):

```json
{ "rules": [
  { "title": "本番|prod", "color": "red" },
  { "exe": "Terminal|iTerm2", "color": "green" }
] }
```

- `title` / `exe` は正規表現(大文字小文字無視)。`exe` は実行ファイル名・アプリ名・バンドル ID
  (`com.apple.Terminal` など)のいずれかに一致すればよい
- 手動で色を付けた・消したウィンドウ、一度ルールで色が付いたウィンドウには再適用しない
- 変更後は `wincolor reload` かメニューの「再読み込み」

### ランチャー

```sh
wincolor run red Terminal                 # /Applications/Terminal.app を起動して赤
wincolor run 青 "Google Chrome" --new-window https://staging.example.com
wincolor run green /usr/local/bin/some-gui-tool --flag
```

アプリ名(`/Applications/<名前>.app`)か `.app` のパスなら `NSWorkspace` で起動し、それ以外は
コマンドとして実行する。窓は「起動したプロセスの PID(または子孫)」で判定し、PID を引き継がない
アプリは起動後に現れた最初の新規ウィンドウに付ける(一致を 1.5 秒待ってから)。
既定 10 秒(`WINCOLOR_RUN_TIMEOUT`)で諦める。

## 設定ファイルの探索順

1. `~/.config/wincolor/`(ユーザー設定。rules.json の雛形をここに置く)
2. `~/.local/share/wincolor/`(install.sh が colors.json を置く。upgrade で上書き)
3. 実行ファイルと同じディレクトリ
4. リポジトリ構成の `shared/`

## 既知の制約

- オーバーレイは対象の直上に順序付けるが、macOS の Z 順は AppKit からは完全に制御できないため、
  重なった窓の境界で枠が一瞬ずれる・隠れることがある(50ms 追従で回復する)
- 全画面(Space 化された)ウィンドウには枠を付けない
- Ctrl+右クリックは `CGEventTap` で横取りするため、アクセシビリティ権限が無いと動かない。
  その場合はメニューバーまたは CLI を使う
- 署名・公証はしていない。ブラウザで zip を落とした場合は `install.sh` が隔離属性を外す
- **実機未確認**: 初版はコード確認と CI ビルドのみ。実機で動作確認したら README を更新する
