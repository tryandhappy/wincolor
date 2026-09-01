# wincolor (Windows版)

ウィンドウ単位に色を付けて見分けるための常駐スクリプト。着色は2系統を併用する:

1. **DWM API** (`DwmSetWindowAttribute`) — 枠・タイトルバー・タイトル文字の色を変更。
   標準タイトルバーのアプリ(PuTTY, TeraTerm, 多くの Win32 アプリ)で有効。
2. **オーバーレイ色枠** — ウィンドウの周囲 3px に追従表示されるクリック透過の色枠。
   タイトルバー自前描画のアプリ(Explorer, Windows Terminal, Chrome, 新メモ帳, Electron 系)では
   DWM のタイトルバー色が自前描画に隠されてしまうため、こちらが識別マークになる。
   枠は対象ウィンドウの直上の Z オーダーに追従し、対象が背面に隠れれば枠も隠れる。

## 要件

- Windows 11 (build 22000 以降)

## インストール

### MSI (推奨)

[Releases](https://github.com/tryandhappy/wincolor/releases) から
`wincolor-windows-vX.Y.Z.msi` をダウンロードして実行。

- ユーザー単位インストール(管理者権限不要、`%LocalAppData%\Programs\wincolor`)
- スタートメニューとスタートアップにショートカットを作成(ログイン時に自動起動)
- アンインストールは「設定 > アプリ」から
- AutoHotkey のインストールは不要(単体 exe)

### ポータブル zip

Releases の `wincolor-windows-vX.Y.Z.zip` を展開して `wincolor.exe` を実行するだけ。

### ソースから実行(開発時)

[AutoHotkey v2](https://www.autohotkey.com/)(`winget install AutoHotkey.AutoHotkey`)を入れて:

```powershell
& "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" .\wincolor.ahk
```

## 使い方

- 任意のウィンドウの**タイトルバーを Ctrl+右クリック**、または**右ボタン長押し(0.4秒)** → 色メニューが出る
  (普通の右クリックは従来どおりシステムメニュー。長押し判定の分だけ表示が約0.4秒遅れる)
- または**タスクトレイのアイコンを右クリック** →「ウィンドウ一覧から着色…」
- メニュー: 色プリセット(`shared/colors.json` で編集可能) / カスタム色… / 既定に戻す
- トレイメニューの「すべて既定に戻す」で一括リセット

## 自動ルール

`rules.json`(exe と同じフォルダ、開発時は `shared/rules.json`)にルールを書くと、
条件に合う新しいウィンドウへ自動で色が付く:

```json
{
  "rules": [
    { "title": "本番|prod", "color": "red" },
    { "exe": "KeePass", "color": "purple" }
  ]
}
```

- `title` / `exe` は正規表現(大文字小文字無視)。片方だけでも可。上のルールが優先
- `color` はプリセット名(`red` / `赤`)か `#RRGGBB`
- タイトルは変化を監視するので、SSH 接続後にタイトルへホスト名が出るケースにも効く
- 手動で色を付けた/既定に戻したウィンドウにはルールは適用されない
- 変更はトレイの「再読み込み」で反映

## ショートカットから色付きで起動(ランチャー)

```
wincolor.exe run <色> <コマンド...>
```

例: ショートカットのリンク先に
`"C:\...\wincolor.exe" run red "C:\Program Files\PuTTY\putty.exe" user@prod-server`
と書くと、そのショートカットから起動したウィンドウだけ赤になる。
常駐中の wincolor に依頼する仕組みなので、常駐していればオーバーレイ枠も付く。
(開発時は `AutoHotkey64.exe wincolor.ahk run red ...`)

## 自動起動

`Win+R` → `shell:startup` → 開いたフォルダに `wincolor.ahk` へのショートカットを置く。

## 制限

- 色はウィンドウが閉じられるまで有効。アプリを再起動すると既定色に戻る
- タイトルバー自前描画のアプリではタイトルバー色は変わらない(オーバーレイ枠のみ)
- スクリプトを終了・再読み込みするとオーバーレイ枠は消える(DWM 色は残るため、
  残った色は個別に「既定に戻す」で解除する)
- 管理者権限で動いているウィンドウに適用するには、本スクリプトも管理者で実行する必要がある
- プリセットの変更は次回起動時(またはトレイの「再読み込み」)に反映
