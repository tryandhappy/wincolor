# wincolor 共通仕様

## 目的

同一アプリの複数ウィンドウを、色で一目で見分けられるようにする。
代表ユースケース: 複数サーバへの SSH 端末、本番/検証など複数環境の同一アプリ。

## 機能(全OS共通の目標)

1. 常駐アプリ(タスクトレイ / メニューバー)として動作する
2. 対象ウィンドウのタイトルバー上で **Ctrl+右クリック** で色メニューを表示する
   - Windows 版は普通の右クリックでも出る: 標準のシステムメニューを複製した自前メニューの
     末尾に色を並べる(他プロセスのシステムメニューに項目を差し込んでも選択結果を受け取れない
     ため、複製方式にした。標準項目は `WM_SYSCOMMAND` を対象窓に送って実行)
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
   (全 OS で実装済み。手動操作したウィンドウには適用しない)
7. ランチャーモード: `run <色> <コマンド>` 引数でアプリを起動し、そのウィンドウに着色
   (全 OS で実装済み。Windows は常駐インスタンスへ WM_COPYDATA、Linux は拡張へ D-Bus `TagPid`、
   macOS は常駐へ CFMessagePort `tagpid` で依頼)

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

#### Alt+Tab 一覧への反映(実測: Windows 11 24H2, build 26100)
- Alt+Tab のサムネイルは DWM が対象窓だけを縮小描画するため、別窓のオーバーレイ枠は写らない。
  DWM のキャプション色はサムネイルにも出るが、自前描画アプリでは元々効かない
- **不採用案: UI Automation でサムネイル位置を取り、一覧の上に枠を重ねる**。
  スイッチャー窓(class `XamlExplorerHostIslandWindow`、title「タスクの切り替え」、
  explorer.exe)は UIA で `ListView`(AutomationId `SwitchItemListControl`)と、窓タイトルを
  Name に持つ `ListViewItem` + 矩形を公開する **が、explorer 起動後の最初の表示のときだけ**。
  2 回目以降は子が `Windows.UI.Input.InputSite.WindowClass` 1 つになり、FindAll /
  RawViewWalker / ElementFromPoint / GetFocusedElement のいずれでも項目に届かない
  (UIA イベント購読中のクライアントがいても、実キー入力でも同じ)。
  表示/非表示自体は `EVENT_OBJECT_SHOW/HIDE`(SetWinEventHook)で確実に取れる
- **採用: ウィンドウアイコンの差し替え**。`WM_SETICON`(ICON_BIG / ICON_SMALL)で
  「色タイル + 元アイコン縮小」の HICON を設定すると、Alt+Tab の各項目のアイコンが変わる。
  Explorer / Windows Terminal(パッケージアプリ)/ Chrome / Electron(Typora)で反映を確認。
  他プロセスの窓に自プロセスの HICON を渡してよい(USER オブジェクトはセッション内で共有)が、
  自プロセス終了で無効になるため、終了・既定に戻す時に元の HICON(`WM_GETICON` の値、無ければ 0)
  を戻す。置き換え起動時は旧常駐に WM_APP+0x57 を送って自ら終了させ、OnExit で戻させる
- タイルは 4 倍の作業解像度に描いてから HALFTONE で縮小(ギザギザ防止)。元アイコンは
  `WM_GETICON` → クラスアイコン → exe のアイコン(`PrivateExtractIconsW`)→ IDI_APPLICATION の順
- `WM_GETICON` に自前応答して差し替えを無視するアプリは、設定直後の読み戻しで検出して諦める

### macOS (macos/)
- 他アプリのタイトルバー色を変える公開 API はない
- **Swift のメニューバー常駐アプリ + CLI** として実装(単一バイナリ `wincolor`。引数なしで常駐、
  引数付きで CLI。常駐 ⇄ CLI は `CFMessagePort` `tryandhappy.wincolor`)
- 対象窓に追従する**クリック透過のオーバーレイ窓**(枠 3pt・角丸 11pt、上端 28pt に半透明の色帯)を
  `CGWindowListCopyWindowInfo` の 50ms ポーリングで追従させ、`NSWindow.order(.above, relativeTo:)` で
  対象の直上に置く。画面上に無い窓(最小化・別 Space)ではオーバーレイを隠す
- トリガー: タイトルバー領域の **Ctrl+右クリック**(`CGEventTap` で横取りして色メニュー。Windows 版と同じ)、
  メニューバーのアイコンからウィンドウ一覧、CLI
- タイトルは Accessibility API(`AXUIElement` + `_AXUIElementGetWindow`)で取る。**Accessibility 権限が必要**
  (画面収録は不要)。無い場合はタイトル空・Ctrl+右クリック不可だが、メニューバーと CLI(ID 指定)は動く
- 自動ルール(rules.json)は共通形式。`exe` は実行ファイル名・アプリ名・バンドル ID に照合。
  ランチャー(`run`)は Linux 版と同じ PID/子孫/フォールバック判定(常駐に `tagpid` で依頼し、CLI が結果をポーリング)
- 設定ファイルの探索順: `~/.config/wincolor/` → `~/.local/share/wincolor/` → 実行ファイルのディレクトリ → リポジトリの `shared/`
- 初版は実機未確認(手元に macOS が無いため、CI の macOS ランナーでコンパイルと CLI 起動のみ検証)

### Linux (linux/)
- Wayland ネイティブウィンドウは外部プロセスから直接装飾できないため、
  **GNOME Shell 拡張**(`window-color-tag@tryandhappy`)として実装し、mutter 内部の
  `window_group` に枠(St.Widget + CSS border)とタイトルバー相当の色タイントを重ね、
  `position-changed` / `size-changed` に追従させる方式で実装済み(GNOME 限定)
- 拡張は D-Bus (`tryandhappy.WindowColorTag`) で `Set` / `Clear` / `ClearAll` / `List` を公開し、
  CLI ラッパー `wincolor`(bash + `gdbus`)から操作する
- CSD(クライアント側装飾)アプリはタイトルバー右クリックが効かないため、
  mutter キーバインド(既定 `Super+C` でメニュー表示、`Super+X` で色を順送り)で代替
- Alt+Tab の切り替え一覧にも反映する。`switcherPopup.SwitcherList.addItem` を包み、
  項目ウィジェットに色枠を付ける(1 アプリに複数色の窓がある場合は色ドットを並べる)。
  アプリ切り替え(`AppIcon.cachedWindows`)・ウィンドウ切り替え(`WindowIcon.window`)・
  窓サムネイル一覧(`ThumbnailSwitcher._windows`)の 3 経路に対応
- オーバービュー(Super)のウィンドウプレビューにも反映する。`windowPreview.WindowPreview.prototype._init`
  を包んで枠ウィジェットを子に足し、`window_container` の割り当てに `BindConstraint`(ALL)で追従させ、
  オーバービュー出入りの拡大縮小に合わせて `scale-x` / `scale-y` も束縛する。
  プレビューはオーバービューを開いている間だけ存在するため、生きているプレビューを Set で持ち、
  色の変更 (`_addTag` / `_removeTag`) で張り替える
- ワークスペースサムネイル内の小さな窓にも反映する。`workspaceThumbnail.WindowClone.prototype._init`
  を包んで枠を子に足す。クローンの中身は実ウィンドウの座標系のままで `_viewport` ごと縮小されるため、
  枠の太さは縮小率で割った値を CSS に入れる (画面上で常に約 3px に見せる)。縮小率は
  `WorkspaceThumbnail.prototype.setScale` を包んで受け取り、そのたびに枠の位置・大きさも取り直す
- 色パレットは `shared/colors.json` を読む(拡張ディレクトリ直下 → リポジトリの `../../shared/`
  の順に探索。install.sh とリリース zip は拡張ディレクトリに同梱する。読めなければ組み込み既定)。
  D-Bus `Set` はプリセット名 / ラベル / `#RRGGBB` を受け付け、`Palette` で一覧を返す。
  `textHex` はタイトル文字をアプリや mutter が描く Linux では使わない(タイントは半透明の重ね描き)
- 自動ルール (rules.json) は `~/.config/wincolor/rules.json`(→ 拡張ディレクトリ → `../../shared/`)
  から読む。`window-created` とタイトル/WM_CLASS の変化で照合し、一度色を確定した窓
  (ルール適用済み・手動操作済み)には再適用しない。Linux では `exe` をプロセス名
  (`/proc/<pid>/exe`、無理なら `comm`)と WM_CLASS(Wayland の app-id)の両方に照合する。
  ファイルは Gio.FileMonitor で監視し保存時に自動再読み込み(D-Bus `Reload` / `Rules` もある)
- ランチャーモード (`wincolor run <色> <コマンド...>`): CLI がコマンドをバックグラウンド起動して
  PID を取り、拡張の D-Bus `TagPid(pid, color, timeoutMs)` に依頼して結果を待つ(非同期メソッド)。
  拡張は `window-created` で pid 一致または pid の子孫プロセス(`/proc/<pid>/stat` の PPid を遡る。
  Flatpak / Snap / ラッパースクリプト対応)の窓を探す。PID を引き継がないアプリ(gnome-terminal の
  クライアント/サーバ型、既存インスタンスに委譲するブラウザ等)向けに、不一致の新規窓が出たら
  1.5 秒だけ一致を待ってからその窓に付ける。既定 10 秒(`WINCOLOR_RUN_TIMEOUT`)で諦める
- KDE 等 GNOME 以外のコンポジタ、および X11 専用の代替実装は未着手
- 詳細は `linux/README.md` を参照

## 色プリセット

`shared/colors.json` に定義。名前・表示ラベル・HEX 値・タイトル文字色を持つ。
