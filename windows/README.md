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

### ソースから exe を作って配置する(Releases を使わない場合)

AutoHotkey v2 に同梱の Ahk2Exe でコンパイルし、MSI と同じ場所に置く。
以下はリポジトリのルートで PowerShell を開いて実行する例:

```powershell
$dst = "$env:LOCALAPPDATA\Programs\wincolor"
$build = Join-Path $env:TEMP "wincolor-build"
New-Item -ItemType Directory -Force $dst, $build | Out-Null

# 1. ソースと設定ファイルを一時フォルダにまとめる
Copy-Item windows\wincolor.ahk, shared\colors.json, shared\rules.json $build

# 2. コンパイル (exit 0 なら成功)
& "C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe" /silent verbose `
    /in "$build\wincolor.ahk" /out "$build\wincolor.exe" `
    /base "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"

# 3. 常駐中の wincolor を止めてから配置 (旧 exe / ソース実行中のもの両方)
Get-Process wincolor -ErrorAction SilentlyContinue | Stop-Process
Get-CimInstance Win32_Process -Filter "Name='AutoHotkey64.exe'" |
    Where-Object { $_.CommandLine -match 'wincolor\.ahk' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId }
Copy-Item "$build\wincolor.exe", "$build\colors.json", "$build\rules.json" $dst -Force

# 4. 起動
Start-Process "$dst\wincolor.exe" -WorkingDirectory $dst
```

配置後は下の「自動起動」の手順でログオン時に起動するようにする。
ソースを更新したら同じコマンドを再実行して exe を上書きする(再起動でオーバーレイ枠は消えるので再着色する)。

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

仕組みはどの方法でも同じで、スタートアップフォルダ(`shell:startup`)に `wincolor.lnk` を置く。
MSI インストール版が作るショートカットと同じ場所・同じ名前なので、どの方法で設定しても
トレイメニューのチェック状態に反映され、そこから ON/OFF できる。

### GUI で設定する

1. wincolor を起動する(タスクトレイにアイコンが出る)
2. **トレイアイコンを右クリック →「ログオン時に自動起動」**をクリックしてチェックを入れる
   - exe 版なら exe を、ソース実行中なら AutoHotkey64.exe に `wincolor.ahk` を渡すショートカットが作られる
   - 「次回ログオン時から自動起動します」と通知が出れば完了
3. 解除するときは同じ項目をもう一度クリックしてチェックを外す(ショートカットが削除される)

手で置きたいときは `Win+R` → `shell:startup` でスタートアップフォルダを開き、
`wincolor.exe` を右ドラッグして「ショートカットをここに作成」でもよい。

### コマンドで設定する

exe を `%LocalAppData%\Programs\wincolor` に置いている場合(MSI / 上記の手動配置):

```powershell
$dst  = "$env:LOCALAPPDATA\Programs\wincolor"
$link = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\wincolor.lnk"
$s = (New-Object -ComObject WScript.Shell).CreateShortcut($link)
$s.TargetPath       = "$dst\wincolor.exe"
$s.WorkingDirectory = $dst
$s.Description      = "wincolor - ウィンドウ着色"
$s.Save()
```

ソースのまま自動起動したい場合は `TargetPath` を AutoHotkey64.exe、`Arguments` を
`"<リポジトリ>\windows\wincolor.ahk"`、`WorkingDirectory` を `windows` フォルダにする。

確認と解除:

```powershell
# 登録内容を確認
$l = (New-Object -ComObject WScript.Shell).CreateShortcut("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\wincolor.lnk")
$l.TargetPath; $l.Arguments

# 解除 (ショートカットを消すだけ)
Remove-Item "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\wincolor.lnk"
```

### 起動していないときの確認

```powershell
Get-Process wincolor, AutoHotkey64 -ErrorAction SilentlyContinue | Select-Object Id, Path
Test-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\wincolor.lnk"
```

プロセスが無く `Test-Path` が `False` なら、自動起動が未設定なので上のどちらかの手順で登録する。

## 制限

- 色はウィンドウが閉じられるまで有効。アプリを再起動すると既定色に戻る
- タイトルバー自前描画のアプリではタイトルバー色は変わらない(オーバーレイ枠のみ)
- スクリプトを終了・再読み込みするとオーバーレイ枠は消える(DWM 色は残るため、
  残った色は個別に「既定に戻す」で解除する)
- 管理者権限で動いているウィンドウに適用するには、本スクリプトも管理者で実行する必要がある
- プリセットの変更は次回起動時(またはトレイの「再読み込み」)に反映
