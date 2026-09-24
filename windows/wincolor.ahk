; wincolor - ウィンドウ単位で色を付けて見分けるツール (Windows版)
; 要件: Windows 11 (build 22000+), AutoHotkey v2
; 使い方:
;   - 任意のウィンドウのタイトルバーを右クリック → 標準メニュー(の複製)の下に色が並ぶ
;   - タスクトレイアイコンのメニュー「ウィンドウ一覧から着色…」でも選択可
;   - 自動ルール: rules.json に「タイトル/exe名の正規表現 → 色」を書くと新しいウィンドウに自動適用
;   - ランチャー: wincolor.ahk run <色> <コマンド...> でアプリを起動し、その窓に色を付ける
;     (ショートカットのリンク先に設定すると「起動時に色を決めておく」が実現できる)
;
; 着色は3系統を併用する:
;   1. DWM API (DwmSetWindowAttribute) による枠・タイトルバー・文字色
;      → 標準タイトルバーのアプリ(PuTTY, TeraTerm, 多くのWin32アプリ)に有効
;   2. ウィンドウに追従するクリック透過のオーバーレイ色枠
;      → タイトルバー自前描画のアプリ(Explorer, Terminal, Chrome, 新メモ帳等)にも有効
;   3. ウィンドウアイコン (WM_SETICON) を色タイル付きに差し替える
;      → Alt+Tab 一覧やタスクバーなど、サムネイル(オーバーレイ枠が写らない)しか
;        表示されない場面でも色で見分けられる
#Requires AutoHotkey v2.0
; 常駐モードとランチャーモード(run 引数)を同じスクリプトで担うため、
; 単一インスタンス制御は手動で行う (ReplaceExistingResident)
#SingleInstance Off

WINCOLOR_VERSION := "1.2.0"
RESIDENT_MARKER  := "wincolor_resident"   ; 常駐インスタンスの隠しウィンドウ識別タイトル
AUTOSTART_ITEM   := "ログオン時に自動起動"  ; トレイメニュー項目名 (チェック状態の操作に使う)
ICON_TAG_ITEM    := "Alt+Tab のアイコンにも色を付ける"
WM_COPYDATA_MAGIC := 0x57434C31           ; 'WCL1'
WM_WINCOLOR_QUIT  := 0x8057               ; WM_APP+0x57: 旧常駐へ「後片付けして終了」を依頼
SETTINGS_PATH     := A_AppData "\wincolor\settings.ini"

DWMWA_BORDER_COLOR  := 34
DWMWA_CAPTION_COLOR := 35
DWMWA_TEXT_COLOR    := 36
DWMWA_COLOR_DEFAULT := 0xFFFFFFFF

FRAME_THICKNESS := 3   ; オーバーレイ枠の太さ(px)

CoordMode "Mouse", "Screen"
A_IconHidden := true   ; ランチャーモードではトレイアイコンを出さない

Presets := LoadPresets()
Applied := Map()    ; hwnd -> {hex, gui, last, icon}  icon: "" または {origBig, origSmall, tagBig, tagSmall, unsupported}
IconCache := Map()  ; hex -> HBITMAP (メニューの色見本)
ExeIconCache := Map() ; exe パス -> HICON (WM_GETICON もクラスアイコンも無い窓の代替元)
RuleDone := Map()   ; hwnd -> true (手動・ルール問わず一度色を確定した窓。ルールが上書きしない)
RuleTitles := Map() ; hwnd -> 最後に評価したタイトル (変化時のみ再評価)
IconTagEnabled := IniRead(SETTINGS_PATH, "options", "iconTag", "1") = "1"

; ---------------------------------------------------------------- ランチャーモード
; wincolor.ahk run <色(プリセット名 or #RRGGBB)> <コマンド...>
if A_Args.Length >= 3 && A_Args[1] = "run" {
    RunLauncher(A_Args)   ; 中で ExitApp する
}

; ---------------------------------------------------------------- 常駐モード
ReplaceExistingResident()
DllCall("SetWindowText", "ptr", A_ScriptHwnd, "str", RESIDENT_MARKER)
A_IconHidden := false
Rules := LoadRules()
OnMessage(0x4A, OnCopyData)   ; ランチャーからの着色依頼を受ける
OnMessage(WM_WINCOLOR_QUIT, (*) => ExitApp())   ; 新しい常駐からの置き換え依頼
OnExit(RestoreAllIcons)   ; 差し替えたアイコンは本プロセスの寿命と共に無効になるため、終了前に必ず戻す
SetupTray()
if Rules.Length
    SetTimer(RuleTick, 1000)

; ---------------------------------------------------------------- ホットキー

; タイトルバー上でのみ介入する(それ以外は通常動作)。
; 右クリック → 標準のシステムメニューを複製し、その下に色プリセットを並べた自前メニューを出す。
; タスクバー等のシェル窓は WM_NCHITTEST に HTCAPTION を返すことがある(Windows 11 のサブモニタの
; タスクバー Shell_SecondaryTrayWnd は全域で HTCAPTION)ため、クラス名で除外して標準メニューに任せる。
; 標準メニューは WM_NCRBUTTONDOWN でキャプチャを取り WM_NCRBUTTONUP で表示されるので、
; ダウンだけ横取りすれば二重には出ない(アップは透過させる。アップまで抑止すると
; KeyWait が物理的な離しを検知できず固まることがあった)
#HotIf MouseOverCaption()
$RButton:: {
    MouseGetPos , , &hwnd
    KeyWait "RButton", "T1"     ; 離してから表示(離した瞬間の誤選択を防ぐ)。1秒で諦めて表示
    if hwnd
        ShowCaptionMenu(hwnd)
}
#HotIf

MouseOverCaption() {
    CoordMode "Mouse", "Screen"
    MouseGetPos &x, &y, &hwnd
    if !hwnd || IsShellWindow(hwnd)
        return false
    try hit := SendMessage(0x0084, 0, ((y & 0xFFFF) << 16) | (x & 0xFFFF), , "ahk_id " hwnd, , , , 200)  ; WM_NCHITTEST
    catch
        return false
    return hit = 2  ; HTCAPTION
}

; タスクバー・デスクトップなどシェルの窓。着色対象にもタイトルバー右クリックの対象にもしない
IsShellWindow(hwnd) {
    try cls := WinGetClass("ahk_id " hwnd)
    catch
        return false
    return cls ~= "^(Progman|WorkerW|Shell_TrayWnd|Shell_SecondaryTrayWnd)$"
}

; ---------------------------------------------------------------- メニュー

SetupTray() {
    A_IconTip := "wincolor v" WINCOLOR_VERSION " - ウィンドウ着色"
    tray := A_TrayMenu
    tray.Delete()
    tray.Add("ウィンドウ一覧から着色…", ShowWindowList)
    tray.Add("すべて既定に戻す", ResetAll)
    tray.Add()
    tray.Add(AUTOSTART_ITEM, ToggleAutoStart)
    UpdateAutoStartCheck()
    tray.Add(ICON_TAG_ITEM, ToggleIconTag)
    UpdateIconTagCheck()
    tray.Add()
    tray.Add("使い方", ShowHelp)
    tray.Add("再読み込み", (*) => Reload())
    tray.Add("終了", (*) => ExitApp())
    tray.Default := "ウィンドウ一覧から着色…"
}

; ---------------------------------------------------------------- 自動起動

; スタートアップフォルダのショートカット。MSI インストール時と同じパス・同じ名前なので、
; MSI で入れた場合もこのトグルで ON/OFF できる
StartupLinkPath() => A_Startup "\wincolor.lnk"

AutoStartEnabled() => FileExist(StartupLinkPath()) != ""

UpdateAutoStartCheck() {
    if AutoStartEnabled()
        A_TrayMenu.Check(AUTOSTART_ITEM)
    else
        A_TrayMenu.Uncheck(AUTOSTART_ITEM)
}

ToggleAutoStart(*) {
    link := StartupLinkPath()
    if AutoStartEnabled() {
        try {
            FileDelete(link)
        } catch as e {
            MsgBox("自動起動の解除に失敗しました:`n" link "`n" e.Message, "wincolor")
            return
        }
        TrayTip("ログオン時の自動起動を解除しました", "wincolor")
    } else {
        ; exe 版はそのまま、ソース実行時は AutoHotkey64.exe にスクリプトを渡す
        if A_IsCompiled
            target := A_ScriptFullPath, args := ""
        else
            target := A_AhkPath, args := '"' A_ScriptFullPath '"'
        try {
            FileCreateShortcut(target, link, A_ScriptDir, args,
                "wincolor - ウィンドウ着色", A_IsCompiled ? A_ScriptFullPath : "")
        } catch as e {
            MsgBox("自動起動の設定に失敗しました:`n" link "`n" e.Message, "wincolor")
            return
        }
        TrayTip("次回ログオン時から自動起動します", "wincolor")
    }
    UpdateAutoStartCheck()
}

; ---------------------------------------------------------------- メニュー(続き)

ShowWindowList(*) {
    m := Menu()
    count := 0
    for hwnd in WinGetList() {
        if hwnd = A_ScriptHwnd || IsOwnFrame(hwnd)
            continue
        title := WinGetTitle("ahk_id " hwnd)
        if title = ""
            continue
        if IsShellWindow(hwnd)
            continue
        if IsCloaked(hwnd)
            continue
        count++
        m.Add(count ". " EscapeMenuText(TruncateTitle(title)), ShowColorMenu.Bind(hwnd))
    }
    if count = 0
        m.Add("(対象ウィンドウなし)", (*) => 0)
    m.Show()
}

; トレイの「ウィンドウ一覧から着色…」用: 窓タイトルを見出しにした色メニュー
ShowColorMenu(hwnd, *) {
    if !WinExist("ahk_id " hwnd)
        return
    title := TruncateTitle(WinGetTitle("ahk_id " hwnd))
    m := Menu()
    m.Add(title = "" ? "(無題)" : EscapeMenuText(title), (*) => 0)
    m.Disable("1&")
    m.Add()
    AddColorItems(m, hwnd)
    m.Show()
}

; タイトルバー右クリック用: 標準のシステムメニューを複製し、その下に色プリセットを並べる
ShowCaptionMenu(hwnd) {
    if !WinExist("ahk_id " hwnd)
        return
    m := Menu()
    if CopySystemMenu(m, hwnd)
        m.Add()
    AddColorItems(m, hwnd)
    m.Show()
}

AddColorItems(m, hwnd) {
    for p in Presets {
        m.Add(p.label, ApplyPreset.Bind(hwnd, p))
        m.SetIcon(p.label, "HBITMAP:*" GetColorIcon(p.hex))
    }
    m.Add()
    m.Add("カスタム色…", ApplyCustom.Bind(hwnd))
    m.Add("既定に戻す", ResetWindow.Bind(hwnd))
}

; 対象窓のシステムメニュー(GetSystemMenu)の項目を m に写す。戻り値: 写した項目数
; 文字列・ID・チェック/既定状態・標準グリフ(hbmpItem)・アプリ独自の追加項目(Terminal の「設定」等)を
; そのまま持ち込み、選ばれたら WM_SYSCOMMAND を対象窓に送る。
; 「元のサイズに戻す/移動/サイズ変更/最小化/最大化」の有効・無効は Windows が表示時に決めるものなので、
; メニューに残っている状態ではなく窓の現状から決める
CopySystemMenu(m, hwnd) {
    hSys := DllCall("GetSystemMenu", "ptr", hwnd, "int", 0, "ptr")
    if !hSys
        return 0
    ; アプリ独自項目の状態更新の機会を与える(標準メニュー表示時と同じ通知)
    try SendMessage(0x0116, hSys, 0, , "ahk_id " hwnd, , , , 300)            ; WM_INITMENU
    try SendMessage(0x0117, hSys, 1 << 16, , "ahk_id " hwnd, , , , 300)      ; WM_INITMENUPOPUP (HIWORD=1: ウィンドウメニュー)
    mm := WinGetMinMax("ahk_id " hwnd)
    style := WinGetStyle("ahk_id " hwnd)
    n := DllCall("GetMenuItemCount", "ptr", hSys)
    added := 0, pendingSep := false
    loop n {
        buf := Buffer(1024, 0)
        mii := Buffer(80, 0)   ; MENUITEMINFOW (x64)
        NumPut("uint", 80, mii, 0)
        NumPut("uint", 0x1 | 0x2 | 0x4 | 0x40 | 0x80 | 0x100, mii, 4)   ; STATE|ID|SUBMENU|STRING|BITMAP|FTYPE
        NumPut("ptr", buf.Ptr, mii, 56), NumPut("uint", 511, mii, 64)    ; dwTypeData / cch
        if !DllCall("GetMenuItemInfoW", "ptr", hSys, "uint", A_Index - 1, "int", 1, "ptr", mii)
            continue
        fType := NumGet(mii, 8, "uint"), state := NumGet(mii, 12, "uint"), id := NumGet(mii, 16, "uint")
        hSub := NumGet(mii, 24, "ptr"), hbmp := NumGet(mii, 72, "ptr")
        if fType & 0x800 {   ; MFT_SEPARATOR: 先頭や連続の区切りは出さない
            pendingSep := added > 0
            continue
        }
        text := StrGet(buf, "UTF-16")
        if hSub || text = ""
            continue
        if pendingSep
            m.Add(), pendingSep := false
        m.Add(text, SysCommand.Bind(hwnd, id))
        added++
        pos := DllCall("GetMenuItemCount", "ptr", m.Handle) "&"
        disabled := (state & 0x3) != 0   ; MFS_GRAYED / MFS_DISABLED
        switch id & 0xFFF0 {
            case 0xF120: disabled := mm = 0                                   ; SC_RESTORE
            case 0xF010: disabled := mm != 0                                  ; SC_MOVE
            case 0xF000: disabled := mm != 0 || !(style & 0x40000)            ; SC_SIZE (WS_THICKFRAME)
            case 0xF020: disabled := mm = -1 || !(style & 0x20000)            ; SC_MINIMIZE (WS_MINIMIZEBOX)
            case 0xF030: disabled := mm = 1 || !(style & 0x10000)             ; SC_MAXIMIZE (WS_MAXIMIZEBOX)
        }
        if disabled
            m.Disable(pos)
        if state & 0x8       ; MFS_CHECKED
            m.Check(pos)
        if state & 0x1000    ; MFS_DEFAULT
            m.Default := pos
        if hbmp {            ; 標準グリフ(HBMMENU_POPUP_*)やアプリのビットマップをそのまま使う
            bm := Buffer(80, 0)
            NumPut("uint", 80, bm, 0), NumPut("uint", 0x80, bm, 4), NumPut("ptr", hbmp, bm, 72)
            DllCall("SetMenuItemInfoW", "ptr", m.Handle, "uint", DllCall("GetMenuItemCount", "ptr", m.Handle) - 1, "int", 1, "ptr", bm)
        }
    }
    return added
}

; 複製したシステムメニューの項目が選ばれた → 対象窓に WM_SYSCOMMAND。
; ID の下位 4bit はヒットテストコードで、メニュー由来は 0(移動/サイズ変更はキーボード式のモードに入る)
SysCommand(hwnd, id, *) {
    if !WinExist("ahk_id " hwnd)
        return
    MouseGetPos &x, &y
    PostMessage(0x0112, id, ((y & 0xFFFF) << 16) | (x & 0xFFFF), , "ahk_id " hwnd)
}

ShowHelp(*) {
    MsgBox(
        "■ 使い方`n"
        "・ウィンドウのタイトルバーを右クリック → 標準メニューの下に`n"
        "  並んだ色を選択`n"
        "・またはトレイアイコン右クリック →「ウィンドウ一覧から着色…」`n"
        "・rules.json に自動ルール(タイトル/exe名 → 色)を書ける`n"
        "・ショートカット起動: wincolor.ahk run <色> <コマンド>`n"
        "・トレイメニュー「ログオン時に自動起動」で自動起動を ON/OFF`n"
        "・「Alt+Tab のアイコンにも色を付ける」で、Alt+Tab 一覧やタスクバーに`n"
        "  出るウィンドウアイコンを色タイル付きに差し替える(ON/OFF 可)`n`n"
        "■ 注意`n"
        "・Windows 11 専用(DWM API を使用)`n"
        "・色はウィンドウを閉じるまで有効(アプリ再起動で戻ります)`n"
        "・Explorer / Terminal / Chrome などタイトルバー自前描画のアプリは`n"
        "  タイトルバー色が効かないため、周囲のオーバーレイ色枠で識別します`n"
        "・Alt+Tab のサムネイルにはオーバーレイ枠は写りません(アイコンの色で識別)`n"
        "・管理者権限のウィンドウには、本ツールも管理者で実行しないと効きません",
        "wincolor v" WINCOLOR_VERSION " - 使い方")
}

; ---------------------------------------------------------------- 着色処理

ApplyPreset(hwnd, p, *) {
    ApplyColorTo(hwnd, p.hex, p.textHex)
}

ApplyCustom(hwnd, *) {
    c := PickColor()
    if c < 0
        return
    r := c & 0xFF, g := (c >> 8) & 0xFF, b := (c >> 16) & 0xFF
    hex := Format("#{:02X}{:02X}{:02X}", r, g, b)
    ; 背景の明るさに応じて文字色を白黒自動選択
    lum := 0.299 * r + 0.587 * g + 0.114 * b
    ApplyColorTo(hwnd, hex, lum > 140 ? "#000000" : "#FFFFFF")
}

ApplyColorTo(hwnd, hex, textHex) {
    ; 1. DWM 色 (効くアプリではタイトルバーごと変わる)
    c := HexToColorref(hex)
    SetAttr(hwnd, DWMWA_CAPTION_COLOR, c)
    SetAttr(hwnd, DWMWA_BORDER_COLOR, c)
    SetAttr(hwnd, DWMWA_TEXT_COLOR, HexToColorref(textHex))
    ; 2. オーバーレイ枠 (全アプリ共通の識別マーク)
    ; 再着色時は元アイコンの記録を引き継ぐ(今の窓アイコンは既に差し替え済みのもの)
    old := Applied.Has(hwnd) ? Applied[hwnd] : ""
    if old
        old.gui.Destroy()
    rec := {hex: StrReplace(hex, "#"), gui: MakeFrame(StrReplace(hex, "#")), last: "", icon: old ? old.icon : ""}
    Applied[hwnd] := rec
    RuleDone[hwnd] := true   ; 一度色を確定した窓には自動ルールを適用しない
    UpdateFrame(hwnd, rec)
    ; 3. ウィンドウアイコン (Alt+Tab・タスクバー用)
    if IconTagEnabled
        TagIcon(hwnd, rec)
    SetTimer(FrameTick, 50)
}

ResetWindow(hwnd, *) {
    for attr in [DWMWA_CAPTION_COLOR, DWMWA_BORDER_COLOR, DWMWA_TEXT_COLOR]
        SetAttr(hwnd, attr, DWMWA_COLOR_DEFAULT)
    if Applied.Has(hwnd) {
        RestoreIcon(hwnd, Applied[hwnd])
        Applied[hwnd].gui.Destroy()
        Applied.Delete(hwnd)
    }
    RuleDone[hwnd] := true   ; ユーザーが既定に戻した窓を自動ルールで塗り直さない
}

ResetAll(*) {
    for hwnd in [Applied.Clone()*]  ; キーのみ複製してから削除
        ResetWindow(hwnd)
}

SetAttr(hwnd, attr, value) {
    return DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "uint", attr, "uint*", value, "uint", 4)
}

; ---------------------------------------------------------------- オーバーレイ枠

MakeFrame(hexRGB) {
    ; レイヤード(E0x80000) + クリック透過(E0x20) + 非アクティブ化(E0x08000000) + ツールウィンドウ
    g := Gui("-Caption +ToolWindow +E0x80000 +E0x20 +E0x08000000 -DPIScale")
    g.BackColor := hexRGB
    g.Show("Hide w10 h10")   ; ウィンドウだけ生成
    WinSetTransparent(255, g)  ; レイヤード有効化(完全不透明)
    return g
}

IsOwnFrame(hwnd) {
    for , rec in Applied
        if rec.gui.Hwnd = hwnd
            return true
    return false
}

FrameTick() {
    static n := 0
    if Applied.Count = 0 {
        SetTimer(FrameTick, 0)
        return
    }
    for hwnd, rec in Applied.Clone()
        UpdateFrame(hwnd, rec)
    ; アイコンの再確認は 10 tick(約 0.5 秒)ごと
    if IconTagEnabled && Mod(++n, 10) = 0
        CheckIcons()
}

UpdateFrame(hwnd, rec) {
    if !WinExist("ahk_id " hwnd) {
        rec.gui.Destroy()
        DropTagIcons(rec)   ; 窓は消えているので戻し先はない。ハンドルだけ解放
        Applied.Delete(hwnd)
        return
    }
    mm := WinGetMinMax("ahk_id " hwnd)
    if mm = -1 || IsCloaked(hwnd) || !DllCall("IsWindowVisible", "ptr", hwnd) {
        rec.gui.Hide()
        return
    }
    fh := rec.gui.Hwnd
    if !DllCall("IsWindowVisible", "ptr", fh) {
        rec.gui.Show("NA")
        rec.last := ""   ; Show が位置を動かすことがあるため再配置を強制
    }
    GetFrameBounds(hwnd, &x, &y, &w, &h)
    t := FRAME_THICKNESS
    off := (mm = 1) ? 0 : t   ; 最大化中は外側にはみ出せないので内側に描く
    key := x "," y "," w "," h "," mm
    if rec.last != key {
        rec.last := key
        DllCall("MoveWindow", "ptr", fh, "int", x - off, "int", y - off, "int", w + 2 * off, "int", h + 2 * off, "int", 1)
        SetFrameRegion(fh, w + 2 * off, h + 2 * off, t, mm != 1)
    }
    ; 対象ウィンドウの「直上」に維持する。
    ; 直下に置くと対象自身の DWM 影が枠に落ち、アクティブ時に枠が黒ずんで
    ; 隙間があるように見える。枠は窓の外周のみを描くので直上でも窓を覆わない。
    hPrev := DllCall("GetWindow", "ptr", hwnd, "uint", 3, "ptr")  ; GW_HWNDPREV
    if hPrev != fh
        DllCall("SetWindowPos", "ptr", fh, "ptr", hPrev, "int", 0, "int", 0, "int", 0, "int", 0, "uint", 0x13)  ; hPrev=0 なら HWND_TOP / NOSIZE|NOMOVE|NOACTIVATE
}

; ウィンドウの見た目どおりの矩形(影・不可視リサイズ境界を除く)
GetFrameBounds(hwnd, &x, &y, &w, &h) {
    rect := Buffer(16, 0)
    if DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 9, "ptr", rect, "uint", 16) = 0 {  ; DWMWA_EXTENDED_FRAME_BOUNDS
        x := NumGet(rect, 0, "int"), y := NumGet(rect, 4, "int")
        w := NumGet(rect, 8, "int") - x, h := NumGet(rect, 12, "int") - y
    } else {
        WinGetPos &x, &y, &w, &h, "ahk_id " hwnd
    }
}

; 額縁状のリージョン(外周 t px のみ残す)
; rounded: Windows 11 の角丸(半径約8px)に内周を合わせ、四隅の三日月状の隙間を防ぐ
SetFrameRegion(hwnd, w, h, t, rounded := true) {
    static rad := 8   ; Win11 標準ウィンドウの角丸半径
    if rounded {
        ; 右・下端は排他的。inner に +1 すると右・下に 1px の隙間が出る。
        ; outer は +1 して右・下の枠幅を左・上と同じ t px に揃える(窓の外にはみ出た分はクリップされる)
        ; ov: 窓の最外周 1px が半透明のアプリ(Electron 等の角丸AA用透明ボーダー)があり、
        ;     そこに背景が透けて隙間に見えるため、枠を 1px 窓の内側に重ねて覆う
        ov := 1
        outer := DllCall("CreateRoundRectRgn", "int", 0, "int", 0, "int", w + 1, "int", h + 1,
                         "int", (rad + t) * 2, "int", (rad + t) * 2, "ptr")
        inner := DllCall("CreateRoundRectRgn", "int", t + ov, "int", t + ov, "int", w - t - ov, "int", h - t - ov,
                         "int", (rad - ov) * 2, "int", (rad - ov) * 2, "ptr")
    } else {
        outer := DllCall("CreateRectRgn", "int", 0, "int", 0, "int", w, "int", h, "ptr")
        inner := DllCall("CreateRectRgn", "int", t, "int", t, "int", w - t, "int", h - t, "ptr")
    }
    DllCall("CombineRgn", "ptr", outer, "ptr", outer, "ptr", inner, "int", 4)  ; RGN_DIFF
    DllCall("DeleteObject", "ptr", inner)
    DllCall("SetWindowRgn", "ptr", hwnd, "ptr", outer, "int", 1)  ; リージョンの所有権はOSへ移る
}

; ---------------------------------------------------------------- ウィンドウアイコンの色タイル (Alt+Tab・タスクバー用)
;
; Alt+Tab 一覧のサムネイルは DWM が対象窓だけを縮小描画するため、別窓であるオーバーレイ枠は写らない。
; 一覧上のサムネイル位置を UI Automation で取って枠を重ねる案は、Windows 11 24H2 では
; スイッチャーの XAML 要素が「explorer 起動後の最初の表示」にしか公開されないため成立しなかった。
; 代わりに、一覧の各項目(とタスクバー)に出るウィンドウアイコンを WM_SETICON で
; 「色タイルの上に元アイコンを縮小して載せたもの」に差し替える。実測で Explorer / Windows Terminal
; (パッケージアプリ) / Chrome / Electron のいずれも一覧に反映されることを確認済み。
; 差し替えた HICON は本プロセスが所有するため、既定に戻す時・終了時に必ず元へ戻す。

UpdateIconTagCheck() {
    if IconTagEnabled
        A_TrayMenu.Check(ICON_TAG_ITEM)
    else
        A_TrayMenu.Uncheck(ICON_TAG_ITEM)
}

ToggleIconTag(*) {
    global IconTagEnabled
    IconTagEnabled := !IconTagEnabled
    try {
        DirCreate(A_AppData "\wincolor")
        IniWrite(IconTagEnabled ? "1" : "0", SETTINGS_PATH, "options", "iconTag")
    }
    UpdateIconTagCheck()
    for hwnd, rec in Applied.Clone() {
        if IconTagEnabled
            TagIcon(hwnd, rec)
        else
            RestoreIcon(hwnd, rec)
    }
}

; 対象窓のアイコンを色タイル付きに差し替える(初回は元アイコンを記録)
TagIcon(hwnd, rec) {
    if rec.icon = "" {
        rec.icon := {origBig: GetWinIcon(hwnd, 1), origSmall: GetWinIcon(hwnd, 0), tagBig: 0, tagSmall: 0, unsupported: false}
    } else if rec.icon.unsupported {
        return
    }
    ic := rec.icon
    base := BaseIcon(hwnd, ic)
    newBig := MakeTagIcon(rec.hex, base, SysGet(11))     ; SM_CXICON
    newSmall := MakeTagIcon(rec.hex, base, SysGet(49))   ; SM_CXSMICON
    SetWinIcon(hwnd, 1, newBig)
    SetWinIcon(hwnd, 0, newSmall)
    ; 自前で WM_GETICON に応答して差し替えを無視するアプリは諦める(毎回付け直す無駄を避ける)
    if GetWinIcon(hwnd, 1, &ok) != newBig && ok {
        SetWinIcon(hwnd, 1, ic.origBig)
        SetWinIcon(hwnd, 0, ic.origSmall)
        DllCall("DestroyIcon", "ptr", newBig), DllCall("DestroyIcon", "ptr", newSmall)
        ic.unsupported := true
        return
    }
    DropTagIcons(rec)   ; 旧タイルは窓から外れた後に解放
    ic.tagBig := newBig, ic.tagSmall := newSmall
}

; 元のアイコンに戻し、タイルを解放する。rec.icon は空に戻す(再度 ON にした時に現状を取り直す)
RestoreIcon(hwnd, rec) {
    if rec.icon = ""
        return
    ic := rec.icon
    if !ic.unsupported && WinExist("ahk_id " hwnd) {
        SetWinIcon(hwnd, 1, ic.origBig)
        SetWinIcon(hwnd, 0, ic.origSmall)
    }
    DropTagIcons(rec)
    rec.icon := ""
}

DropTagIcons(rec) {
    if rec.icon = ""
        return
    if rec.icon.tagBig
        DllCall("DestroyIcon", "ptr", rec.icon.tagBig)
    if rec.icon.tagSmall
        DllCall("DestroyIcon", "ptr", rec.icon.tagSmall)
    rec.icon.tagBig := 0, rec.icon.tagSmall := 0
}

RestoreAllIcons(*) {
    for hwnd, rec in Applied.Clone()
        RestoreIcon(hwnd, rec)
}

; アプリ側がアイコンを変えた(Explorer のフォルダー移動、Chrome のプロファイル変更など)ら、
; それを新しい「元」として取り直し、タイルを作り直す
CheckIcons() {
    for hwnd, rec in Applied.Clone() {
        if rec.icon = "" || rec.icon.unsupported || !WinExist("ahk_id " hwnd)
            continue
        cur := GetWinIcon(hwnd, 1, &ok)
        if !ok || cur = rec.icon.tagBig
            continue
        rec.icon.origBig := cur
        rec.icon.origSmall := GetWinIcon(hwnd, 0)
        TagIcon(hwnd, rec)
    }
}

; タイルに載せる元アイコン。WM_GETICON → クラスアイコン → exe のアイコン → 既定アプリアイコン の順
BaseIcon(hwnd, ic) {
    if ic.origBig
        return ic.origBig
    if ic.origSmall
        return ic.origSmall
    h := DllCall("GetClassLongPtr", "ptr", hwnd, "int", -14, "ptr")   ; GCLP_HICON
    if !h
        h := DllCall("GetClassLongPtr", "ptr", hwnd, "int", -34, "ptr")   ; GCLP_HICONSM
    if h
        return h
    path := ""
    try path := WinGetProcessPath("ahk_id " hwnd)
    if path != "" {
        if !ExeIconCache.Has(path) {
            hi := 0, id := 0
            DllCall("PrivateExtractIconsW", "str", path, "int", 0, "int", 32, "int", 32, "ptr*", &hi, "uint*", &id, "uint", 1, "uint", 0)
            ExeIconCache[path] := hi
        }
        if ExeIconCache[path]
            return ExeIconCache[path]
    }
    return DllCall("LoadIcon", "ptr", 0, "ptr", 32512, "ptr")   ; IDI_APPLICATION
}

; WM_GETICON。応答しない窓(ハング中)は ok=false で 0 を返す
GetWinIcon(hwnd, which, &ok := false) {
    r := 0
    ok := DllCall("SendMessageTimeoutW", "ptr", hwnd, "uint", 0x7F, "ptr", which, "ptr", 0, "uint", 2, "uint", 300, "ptr*", &r) != 0  ; SMTO_ABORTIFHUNG
    return ok ? r : 0
}

SetWinIcon(hwnd, which, hicon) {
    r := 0
    DllCall("SendMessageTimeoutW", "ptr", hwnd, "uint", 0x80, "ptr", which, "ptr", hicon, "uint", 2, "uint", 300, "ptr*", &r)
}

; 色タイル(size×size、外周 size/8 が色)の上に元アイコンを縮小して載せた HICON を作る。
; 4 倍の作業解像度で描いてから HALFTONE で縮小し、ギザギザを避ける。結果は全画素不透明
MakeTagIcon(hexRGB, hBase, size) {
    t := Max(2, Round(size / 8))
    N := size * 4, tN := t * 4
    hdc := DllCall("GetDC", "ptr", 0, "ptr")
    work := CreateDIB32(hdc, N, &wbits)
    wdc := DllCall("CreateCompatibleDC", "ptr", hdc, "ptr")
    DllCall("SelectObject", "ptr", wdc, "ptr", work, "ptr")
    br := DllCall("CreateSolidBrush", "uint", HexToColorref(hexRGB), "ptr")
    rect := Buffer(16, 0)
    NumPut("int", N, rect, 8), NumPut("int", N, rect, 12)
    DllCall("FillRect", "ptr", wdc, "ptr", rect, "ptr", br)
    DllCall("DeleteObject", "ptr", br)
    if hBase
        DllCall("DrawIconEx", "ptr", wdc, "int", tN, "int", tN, "ptr", hBase, "int", N - 2 * tN, "int", N - 2 * tN, "uint", 0, "ptr", 0, "uint", 3)  ; DI_NORMAL
    out := CreateDIB32(hdc, size, &obits)
    odc := DllCall("CreateCompatibleDC", "ptr", hdc, "ptr")
    DllCall("SelectObject", "ptr", odc, "ptr", out, "ptr")
    DllCall("SetStretchBltMode", "ptr", odc, "int", 4)   ; HALFTONE
    DllCall("SetBrushOrgEx", "ptr", odc, "int", 0, "int", 0, "ptr", 0)
    DllCall("StretchBlt", "ptr", odc, "int", 0, "int", 0, "int", size, "int", size,
            "ptr", wdc, "int", 0, "int", 0, "int", N, "int", N, "uint", 0x00CC0020)   ; SRCCOPY
    loop size * size
        NumPut("uchar", 0xFF, obits, (A_Index - 1) * 4 + 3)   ; α を不透明に
    maskBits := Buffer(((size + 15) // 16) * 2 * size, 0)     ; 全 0 = 全画素表示
    mask := DllCall("CreateBitmap", "int", size, "int", size, "uint", 1, "uint", 1, "ptr", maskBits, "ptr")
    ii := Buffer(32, 0)                 ; ICONINFO (x64)
    NumPut("int", 1, ii, 0)             ; fIcon
    NumPut("ptr", mask, ii, 16), NumPut("ptr", out, ii, 24)
    hicon := DllCall("CreateIconIndirect", "ptr", ii, "ptr")
    DllCall("DeleteDC", "ptr", wdc), DllCall("DeleteDC", "ptr", odc)
    DllCall("DeleteObject", "ptr", work), DllCall("DeleteObject", "ptr", out), DllCall("DeleteObject", "ptr", mask)
    DllCall("ReleaseDC", "ptr", 0, "ptr", hdc)
    return hicon
}

; 32bpp トップダウン DIB。bits に画素の先頭アドレスを返す
CreateDIB32(hdc, size, &bits) {
    bi := Buffer(40, 0)
    NumPut("uint", 40, bi, 0), NumPut("int", size, bi, 4), NumPut("int", -size, bi, 8)
    NumPut("ushort", 1, bi, 12), NumPut("ushort", 32, bi, 14)
    bits := 0
    return DllCall("CreateDIBSection", "ptr", hdc, "ptr", bi, "uint", 0, "ptr*", &bits, "ptr", 0, "uint", 0, "ptr")
}

; メニュー用の色見本ビットマップ(角丸風の塗り+薄いグレー枠)。hex 単位でキャッシュする
GetColorIcon(hex) {
    global IconCache
    if IconCache.Has(hex)
        return IconCache[hex]
    size := SysGet(49)   ; SM_CXSMICON
    hdc := DllCall("GetDC", "ptr", 0, "ptr")
    mdc := DllCall("CreateCompatibleDC", "ptr", hdc, "ptr")
    hbm := DllCall("CreateCompatibleBitmap", "ptr", hdc, "int", size, "int", size, "ptr")
    obm := DllCall("SelectObject", "ptr", mdc, "ptr", hbm, "ptr")
    rect := Buffer(16, 0)
    NumPut("int", size, rect, 8), NumPut("int", size, rect, 12)
    ; メニュー背景に合わせて余白を白ではなくメニュー色で塗る
    DllCall("FillRect", "ptr", mdc, "ptr", rect, "ptr", DllCall("GetSysColorBrush", "int", 4, "ptr"))  ; COLOR_MENU
    br := DllCall("CreateSolidBrush", "uint", HexToColorref(hex), "ptr")
    pen := DllCall("CreatePen", "int", 0, "int", 1, "uint", 0x808080, "ptr")
    obr := DllCall("SelectObject", "ptr", mdc, "ptr", br, "ptr")
    open := DllCall("SelectObject", "ptr", mdc, "ptr", pen, "ptr")
    DllCall("RoundRect", "ptr", mdc, "int", 1, "int", 1, "int", size - 1, "int", size - 1, "int", 4, "int", 4)
    DllCall("SelectObject", "ptr", mdc, "ptr", obr, "ptr")
    DllCall("SelectObject", "ptr", mdc, "ptr", open, "ptr")
    DllCall("DeleteObject", "ptr", br)
    DllCall("DeleteObject", "ptr", pen)
    DllCall("SelectObject", "ptr", mdc, "ptr", obm, "ptr")
    DllCall("DeleteDC", "ptr", mdc)
    DllCall("ReleaseDC", "ptr", 0, "ptr", hdc)
    IconCache[hex] := hbm
    return hbm
}

; ---------------------------------------------------------------- 色選択ダイアログ

; 標準の色選択ダイアログ (ChooseColorW)。戻り値: COLORREF、キャンセル時 -1
PickColor() {
    static custColors := Buffer(64, 0)  ; COLORREF[16] カスタム色の保存領域
    cc := Buffer(72, 0)                 ; CHOOSECOLORW (x64)
    NumPut("uint", cc.Size, cc, 0)      ; lStructSize
    NumPut("ptr", 0, cc, 8)             ; hwndOwner
    NumPut("uint", 0, cc, 24)           ; rgbResult
    NumPut("ptr", custColors.Ptr, cc, 32) ; lpCustColors
    NumPut("uint", 0x1 | 0x2, cc, 40)   ; CC_RGBINIT | CC_FULLOPEN
    if !DllCall("comdlg32\ChooseColorW", "ptr", cc)
        return -1
    return NumGet(cc, 24, "uint")
}

; ---------------------------------------------------------------- 常駐管理・ランチャー・自動ルール

; 既存の常駐インスタンスがいれば終了させる (#SingleInstance Force 相当)
ReplaceExistingResident() {
    loop 5 {
        hwnd := FindResident()
        if !hwnd
            break
        pid := 0
        DllCall("GetWindowThreadProcessId", "ptr", hwnd, "uint*", &pid)
        if pid && pid != DllCall("GetCurrentProcessId") {
            ; まず終了を依頼し(OnExit で差し替えたアイコンを元に戻させる)、応じなければ強制終了
            DllCall("PostMessage", "ptr", hwnd, "uint", WM_WINCOLOR_QUIT, "ptr", 0, "ptr", 0)
            if ProcessWaitClose(pid, 3) {   ; 戻り値は「まだ生きていれば PID、終了していれば 0」
                ProcessClose(pid)
                ProcessWaitClose(pid, 3)
            }
        } else {
            break
        }
    }
}

FindResident() {
    return DllCall("FindWindow", "str", "AutoHotkey", "str", RESIDENT_MARKER, "ptr")
}

; ランチャーモード: アプリを起動してそのウィンドウに色を付ける
RunLauncher(args) {
    colorSpec := args[2]
    if !ResolveColor(colorSpec) {
        MsgBox("不明な色です: " colorSpec "`nプリセット名 (red / 赤 など) か #RRGGBB を指定してください。", "wincolor run")
        ExitApp
    }
    cmd := ""
    i := 3
    while i <= args.Length {
        part := args[i]
        cmd .= (cmd = "" ? "" : " ") (InStr(part, " ") ? '"' part '"' : part)
        i++
    }
    existing := Map()
    for h in WinGetList()
        existing[h] := true
    try Run(cmd, , , &pid)
    catch as e {
        MsgBox("起動に失敗しました: " cmd "`n" e.Message, "wincolor run")
        ExitApp
    }
    hwnd := 0
    if WinWait("ahk_pid " pid, , 5) {
        hwnd := WinExist("ahk_pid " pid)
    } else {
        ; PID を引き継がないアプリ (Windows Terminal 等): 新規ウィンドウの出現を待つ
        deadline := A_TickCount + 10000
        while A_TickCount < deadline {
            for h in WinGetList() {
                if !existing.Has(h) && WinGetTitle("ahk_id " h) != "" && !IsCloaked(h) {
                    hwnd := h
                    break 2
                }
            }
            Sleep 250
        }
    }
    if hwnd {
        resident := FindResident()
        if resident {
            SendColorCmd(resident, hwnd "|" colorSpec)
        } else {
            ; 常駐なし: DWM 色のみ直接適用 (オーバーレイ枠の追従は常駐が必要)
            p := ResolveColor(colorSpec)
            c := HexToColorref(p.hex)
            SetAttr(hwnd, DWMWA_CAPTION_COLOR, c)
            SetAttr(hwnd, DWMWA_BORDER_COLOR, c)
            SetAttr(hwnd, DWMWA_TEXT_COLOR, HexToColorref(p.textHex))
        }
    } else {
        TrayTip("対象ウィンドウが見つかりませんでした", "wincolor run")
        Sleep 1500
    }
    ExitApp
}

; WM_COPYDATA で常駐に「hwnd|色」を送る
SendColorCmd(target, str) {
    buf := Buffer(StrPut(str, "UTF-16"))
    StrPut(str, buf, "UTF-16")
    cds := Buffer(A_PtrSize * 3, 0)
    NumPut("ptr", WM_COPYDATA_MAGIC, cds, 0)
    NumPut("ptr", buf.Size, cds, A_PtrSize)
    NumPut("ptr", buf.Ptr, cds, A_PtrSize * 2)
    result := 0
    DllCall("SendMessageTimeoutW", "ptr", target, "uint", 0x4A, "ptr", A_ScriptHwnd,
            "ptr", cds.Ptr, "uint", 0x2, "uint", 3000, "ptr*", &result)  ; SMTO_ABORTIFHUNG
}

; 常駐側: ランチャーからの着色依頼を受信
OnCopyData(wParam, lParam, msg, hwnd) {
    if NumGet(lParam, 0, "ptr") != WM_COPYDATA_MAGIC
        return
    size := NumGet(lParam, A_PtrSize, "ptr")
    ptr := NumGet(lParam, A_PtrSize * 2, "ptr")
    parts := StrSplit(StrGet(ptr, size // 2, "UTF-16"), "|")
    if parts.Length >= 2 {
        target := Integer(parts[1])
        p := ResolveColor(parts[2])
        if p && WinExist("ahk_id " target)
            ApplyColorTo(target, p.hex, p.textHex)
    }
    return 1
}

; プリセット名 (name/label) または #RRGGBB を {hex, textHex} に解決
ResolveColor(s) {
    for p in Presets
        if p.name = s || p.label = s
            return p
    if RegExMatch(s, "^#?[0-9A-Fa-f]{6}$") {
        hex := "#" StrReplace(s, "#")
        c := HexToColorref(hex)
        r := c & 0xFF, g := (c >> 8) & 0xFF, b := (c >> 16) & 0xFF
        lum := 0.299 * r + 0.587 * g + 0.114 * b
        return {name: s, label: s, hex: hex, textHex: lum > 140 ? "#000000" : "#FFFFFF"}
    }
    return ""
}

; 自動ルール: 新しいウィンドウ/タイトルが変わったウィンドウをルールと照合して着色
RuleTick() {
    live := Map()
    for hwnd in WinGetList() {
        live[hwnd] := true
        if RuleDone.Has(hwnd) || hwnd = A_ScriptHwnd || IsOwnFrame(hwnd)
            continue
        title := WinGetTitle("ahk_id " hwnd)
        if title = "" || IsCloaked(hwnd)
            continue
        if RuleTitles.Has(hwnd) && RuleTitles[hwnd] = title
            continue
        RuleTitles[hwnd] := title
        exe := ""
        try exe := WinGetProcessName("ahk_id " hwnd)
        for r in Rules {
            if r.title != "" && !RegExMatch(title, "i)" r.title)
                continue
            if r.exe != "" && !RegExMatch(exe, "i)" r.exe)
                continue
            p := ResolveColor(r.color)
            if p
                ApplyColorTo(hwnd, p.hex, p.textHex)
            break
        }
    }
    ; 閉じられたウィンドウの記録を掃除
    for hwnd in [RuleTitles.Clone()*]
        if !live.Has(hwnd)
            RuleTitles.Delete(hwnd)
    for hwnd in [RuleDone.Clone()*]
        if !live.Has(hwnd)
            RuleDone.Delete(hwnd)
}

; rules.json を読む。探索順は colors.json と同じ
; 形式: { "rules": [ { "title": "正規表現", "exe": "正規表現", "color": "プリセット名 or #RRGGBB" } ] }
; title / exe は片方だけでも可 (指定したものすべてにマッチしたら適用、上のルールが優先)
LoadRules() {
    path := ""
    for cand in [A_ScriptDir "\rules.json", A_ScriptDir "\..\shared\rules.json"] {
        if FileExist(cand) {
            path := cand
            break
        }
    }
    if path = ""
        return []
    txt := FileRead(path, "UTF-8")
    rules := []
    if !RegExMatch(txt, 's)"rules"\s*:\s*\[(.*?)\]', &sec)
        return rules
    pos := 1
    while pos := RegExMatch(sec[1], '\{[^{}]*\}', &m, pos) {
        r := {title: "", exe: "", color: ""}
        if RegExMatch(m[0], '"title"\s*:\s*"([^"]*)"', &f)
            r.title := JsonUnescape(f[1])
        if RegExMatch(m[0], '"exe"\s*:\s*"([^"]*)"', &f)
            r.exe := JsonUnescape(f[1])
        if RegExMatch(m[0], '"color"\s*:\s*"([^"]*)"', &f)
            r.color := f[1]
        if r.color != "" && (r.title != "" || r.exe != "")
            rules.Push(r)
        pos += m.Len
    }
    return rules
}

JsonUnescape(s) {
    s := StrReplace(s, '\\', '\')
    return s
}

; ---------------------------------------------------------------- ユーティリティ

; "#RRGGBB" または "RRGGBB" → COLORREF (0x00BBGGRR)
HexToColorref(hex) {
    hex := StrReplace(hex, "#")
    r := Integer("0x" SubStr(hex, 1, 2))
    g := Integer("0x" SubStr(hex, 3, 2))
    b := Integer("0x" SubStr(hex, 5, 2))
    return (b << 16) | (g << 8) | r
}

IsCloaked(hwnd) {
    cloaked := 0
    DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 14, "uint*", &cloaked, "uint", 4)  ; DWMWA_CLOAKED
    return cloaked != 0
}

TruncateTitle(t) {
    t := StrReplace(t, "`t", " ")
    return StrLen(t) > 60 ? SubStr(t, 1, 60) "…" : t
}

EscapeMenuText(t) => StrReplace(t, "&", "&&")

; colors.json からプリセットを読む。無ければ組み込み既定を使う
; 探索順: exe/スクリプトと同じフォルダ(MSI配布) → リポジトリ構成 (../shared/)
LoadPresets() {
    path := ""
    for cand in [A_ScriptDir "\colors.json", A_ScriptDir "\..\shared\colors.json"] {
        if FileExist(cand) {
            path := cand
            break
        }
    }
    if path = ""
        return DefaultPresets()
    txt := FileRead(path, "UTF-8")
    presets := []
    pos := 1
    pattern := '\{\s*"name"\s*:\s*"([^"]*)"\s*,\s*"label"\s*:\s*"([^"]*)"\s*,\s*"hex"\s*:\s*"(#[0-9A-Fa-f]{6})"\s*,\s*"textHex"\s*:\s*"(#[0-9A-Fa-f]{6})"\s*\}'
    while pos := RegExMatch(txt, pattern, &mt, pos) {
        presets.Push({name: mt[1], label: mt[2], hex: mt[3], textHex: mt[4]})
        pos += mt.Len
    }
    return presets.Length ? presets : DefaultPresets()
}

DefaultPresets() {
    return [
        {name: "red",         label: "赤",   hex: "#C42B1C", textHex: "#FFFFFF"},
        {name: "darkred",     label: "深紅", hex: "#7E1416", textHex: "#FFFFFF"},
        {name: "pink",        label: "桃",   hex: "#E3008C", textHex: "#FFFFFF"},
        {name: "orange",      label: "橙",   hex: "#CA5010", textHex: "#FFFFFF"},
        {name: "apricot",     label: "杏",   hex: "#E8A33D", textHex: "#000000"},
        {name: "brown",       label: "茶",   hex: "#8E562E", textHex: "#FFFFFF"},
        {name: "yellow",      label: "黄",   hex: "#C19C00", textHex: "#000000"},
        {name: "lightyellow", label: "薄黄", hex: "#E8DB4F", textHex: "#000000"},
        {name: "lime",        label: "黄緑", hex: "#7CB342", textHex: "#000000"},
        {name: "green",       label: "緑",   hex: "#107C10", textHex: "#FFFFFF"},
        {name: "darkgreen",   label: "深緑", hex: "#1B5E20", textHex: "#FFFFFF"},
        {name: "teal",        label: "青緑", hex: "#00897B", textHex: "#FFFFFF"},
        {name: "cyan",        label: "水",   hex: "#00B7C3", textHex: "#FFFFFF"},
        {name: "blue",        label: "青",   hex: "#0F6CBD", textHex: "#FFFFFF"},
        {name: "navy",        label: "紺",   hex: "#1F3864", textHex: "#FFFFFF"},
        {name: "sky",         label: "空",   hex: "#5B9BD5", textHex: "#000000"},
        {name: "purple",      label: "紫",   hex: "#7A34A3", textHex: "#FFFFFF"},
        {name: "wisteria",    label: "藤",   hex: "#A78BDA", textHex: "#000000"},
        {name: "magenta",     label: "紅紫", hex: "#B4009E", textHex: "#FFFFFF"},
        {name: "gray",        label: "灰",   hex: "#5D5D5D", textHex: "#FFFFFF"},
        {name: "lightgray",   label: "薄灰", hex: "#A6A6A6", textHex: "#000000"},
        {name: "darkgray",    label: "暗灰", hex: "#333333", textHex: "#FFFFFF"}
    ]
}
