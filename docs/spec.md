# wincolor 共通仕様

## 目的

同一アプリの複数ウィンドウを、色で一目で見分けられるようにする。
代表ユースケース: 複数サーバへの SSH 端末、本番/検証など複数環境の同一アプリ。

## 機能(全OS共通の目標)

1. 常駐アプリ(タスクトレイ / メニューバー)として動作する
2. 対象ウィンドウのタイトルバー上で **Ctrl+右クリック** または **右ボタン長押し(0.4秒)** で
   色メニューを表示する(短い右クリックは通常動作として透過)
   - トレイ/メニューバーのメニューからウィンドウ一覧で選ぶ方式も併設する
3. 色メニューの内容
   - 色プリセット(shared/colors.json 参照)
   - カスタム色(カラーピッカー)
   - 既定に戻す
4. 色の適用対象(OSの制約内で可能な範囲)
   - 枠(ボーダー)
   - タイトルバー背景
   - タイトルバー文字色
5. 設定はウィンドウ生存中のみ有効
6. 自動ルール (rules.json): タイトル/実行ファイル名の正規表現に一致する新規ウィンドウへ自動着色
   (Windows / Linux 版で実装済み。手動操作したウィンドウには適用しない)
7. ランチャーモード: `run <色> <コマンド>` 引数でアプリを起動し、そのウィンドウに着色
   (Windows 版で実装済み。常駐インスタンスへ WM_COPYDATA で依頼)

## OS別の制約

### Windows (windows/)
- `DwmSetWindowAttribute` (Windows 11 build 22000+)
  - `DWMWA_BORDER_COLOR` (34) / `DWMWA_CAPTION_COLOR` (35) / `DWMWA_TEXT_COLOR` (36)
  - COLORREF は 0x00BBGGRR。0xFFFFFFFE=枠非表示、0xFFFFFFFF=既定
- HWND 単位で適用できる。ただし**タイトルバー自前描画のアプリでは
  タイトルバー色が自前描画に覆われて見えない**(実測: Explorer / 新メモ帳 /
  Windows Terminal / Chrome。標準タイトルバーの winver 等では色が維持される)
- このため DWM 色に加えて**オーバーレイ色枠**(クリック透過・50ms 追従)を常に併用する。
  最大化時は枠を内側に描く
- 実装言語: AutoHotkey v2

#### オーバーレイ枠の実装上の要点(実測で判明した3つの落とし穴)
1. **四隅の隙間**: Win11 の窓は角丸(半径約8px)。枠のリージョンも角丸にしないと
   四隅に三日月状の隙間が出る
2. **右・下の1px隙間**: GDI リージョンの右・下端座標は排他的。内側くり抜きに +1 すると
   右・下に 1px の隙間が出る(外周側の +1 は枠幅を左右で揃えるために必要)
3. **影と半透明境界**: 枠を対象の「直下」の Z オーダーに置くと対象自身の DWM 影が枠に落ち、
   アクティブ時に枠が黒ずんで隙間に見える → 枠は対象の**直上**(GW_HWNDPREV の後ろ)に置く。
   さらに Electron 系アプリは最外周 1px が半透明(角丸AA用)で背景が透けるため、
   枠を 1px 窓の内側に重ねて覆う

### macOS (macos/)
- 他アプリのタイトルバー色を変える公開 API はない
- 代替: ウィンドウに追従する色付きオーバーレイ枠を描画(Hammerspoon hs.canvas 等)
- Accessibility 権限が必要

### Linux (linux/)
- Wayland ネイティブウィンドウは外部プロセスから直接装飾できないため、
  **GNOME Shell 拡張**(`window-color-tag@smart2j.jp`)として実装し、mutter 内部の
  `window_group` に枠(St.Widget + CSS border)とタイトルバー相当の色タイントを重ね、
  `position-changed` / `size-changed` に追従させる方式で実装済み(GNOME 限定)
- 拡張は D-Bus (`jp.smart2j.WindowColorTag`) で `Set` / `Clear` / `ClearAll` / `List` を公開し、
  CLI ラッパー `wincolor`(bash + `gdbus`)から操作する
- CSD(クライアント側装飾)アプリはタイトルバー右クリックが効かないため、
  mutter キーバインド(既定 `Super+C` でメニュー表示、`Super+X` で色を順送り)で代替
- 色パレットは `shared/colors.json` を読む(拡張ディレクトリ直下 → リポジトリの `../../shared/`
  の順に探索。install.sh とリリース zip は拡張ディレクトリに同梱する。読めなければ組み込み既定)。
  D-Bus `Set` はプリセット名 / ラベル / `#RRGGBB` を受け付け、`Palette` で一覧を返す。
  `textHex` はタイトル文字をアプリや mutter が描く Linux では使わない(タイントは半透明の重ね描き)
- 自動ルール (rules.json) は `~/.config/wincolor/rules.json`(→ 拡張ディレクトリ → `../../shared/`)
  から読む。`window-created` とタイトル/WM_CLASS の変化で照合し、一度色を確定した窓
  (ルール適用済み・手動操作済み)には再適用しない。Linux では `exe` をプロセス名
  (`/proc/<pid>/exe`、無理なら `comm`)と WM_CLASS(Wayland の app-id)の両方に照合する。
  ファイルは Gio.FileMonitor で監視し保存時に自動再読み込み(D-Bus `Reload` / `Rules` もある)
- ランチャーモード (run) は未実装
- KDE 等 GNOME 以外のコンポジタ、および X11 専用の代替実装は未着手
- 詳細は `linux/README.md` を参照

## 色プリセット

`shared/colors.json` に定義。名前・表示ラベル・HEX 値・タイトル文字色を持つ。
