; wincolor - ウィンドウ単位で色を付けて見分けるツール (Windows版)
; 要件: Windows 11 (build 22000+), AutoHotkey v2
; 使い方:
;   - 任意のウィンドウのタイトルバーを Ctrl+右クリック、または右ボタン長押し → 色メニュー
;   - タスクトレイアイコンのメニュー「ウィンドウ一覧から着色…」でも選択可
;
; 着色は2系統を併用する:
;   1. DWM API (DwmSetWindowAttribute) による枠・タイトルバー・文字色
;      → 標準タイトルバーのアプリ(PuTTY, TeraTerm, 多くのWin32アプリ)に有効
;   2. ウィンドウに追従するクリック透過のオーバーレイ色枠
;      → タイトルバー自前描画のアプリ(Explorer, Terminal, Chrome, 新メモ帳等)にも有効
#Requires AutoHotkey v2.0
#SingleInstance Force

WINCOLOR_VERSION := "1.0.0"

DWMWA_BORDER_COLOR  := 34
DWMWA_CAPTION_COLOR := 35
DWMWA_TEXT_COLOR    := 36
DWMWA_COLOR_DEFAULT := 0xFFFFFFFF

FRAME_THICKNESS := 3   ; オーバーレイ枠の太さ(px)
LONG_PRESS_SEC  := 0.4 ; タイトルバー右ボタン長押しの判定秒数

CoordMode "Mouse", "Screen"

Presets := LoadPresets()
Applied := Map()   ; hwnd -> {hex, gui, last}
IconCache := Map() ; hex -> HBITMAP (メニューの色見本)

SetupTray()

; ---------------------------------------------------------------- ホットキー

; タイトルバー上でのみ介入する(それ以外は通常動作)
#HotIf MouseOverCaption()
^RButton:: {
    MouseGetPos , , &hwnd
    if hwnd
        ShowColorMenu(hwnd)
}

; 右ボタン長押しで色メニュー。短く押せば通常の右クリックとして透過
$RButton:: {
    MouseGetPos , , &hwnd
    if !hwnd
        return
    if KeyWait("RButton", "T" LONG_PRESS_SEC) {
        ; 判定時間内に離された → 通常の右クリックを再送($ により再トリガーしない)
        Send "{Blind}{Click Right}"
    } else {
        ; 長押し → ボタンが離されてからメニュー表示(離した瞬間の誤選択を防ぐ)
        KeyWait "RButton"
        ShowColorMenu(hwnd)
    }
}
#HotIf

MouseOverCaption() {
    CoordMode "Mouse", "Screen"
    MouseGetPos &x, &y, &hwnd
    if !hwnd
        return false
    try hit := SendMessage(0x0084, 0, ((y & 0xFFFF) << 16) | (x & 0xFFFF), , "ahk_id " hwnd, , , , 200)  ; WM_NCHITTEST
    catch
        return false
    return hit = 2  ; HTCAPTION
}

; ---------------------------------------------------------------- メニュー

SetupTray() {
    A_IconTip := "wincolor v" WINCOLOR_VERSION " - ウィンドウ着色"
    tray := A_TrayMenu
    tray.Delete()
    tray.Add("ウィンドウ一覧から着色…", ShowWindowList)
    tray.Add("すべて既定に戻す", ResetAll)
    tray.Add()
    tray.Add("使い方", ShowHelp)
    tray.Add("再読み込み", (*) => Reload())
    tray.Add("終了", (*) => ExitApp())
    tray.Default := "ウィンドウ一覧から着色…"
}

ShowWindowList(*) {
    m := Menu()
    count := 0
    for hwnd in WinGetList() {
        if hwnd = A_ScriptHwnd || IsOwnFrame(hwnd)
            continue
        title := WinGetTitle("ahk_id " hwnd)
        if title = ""
            continue
        cls := WinGetClass("ahk_id " hwnd)
        if cls ~= "^(Progman|Shell_TrayWnd|Shell_SecondaryTrayWnd)$"
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

ShowColorMenu(hwnd, *) {
    if !WinExist("ahk_id " hwnd)
        return
    title := TruncateTitle(WinGetTitle("ahk_id " hwnd))
    m := Menu()
    m.Add(title = "" ? "(無題)" : EscapeMenuText(title), (*) => 0)
    m.Disable("1&")
    m.Add()
    for p in Presets {
        m.Add(p.label, ApplyPreset.Bind(hwnd, p))
        m.SetIcon(p.label, "HBITMAP:*" GetColorIcon(p.hex))
    }
    m.Add()
    m.Add("カスタム色…", ApplyCustom.Bind(hwnd))
    m.Add("既定に戻す", ResetWindow.Bind(hwnd))
    m.Show()
}

ShowHelp(*) {
    MsgBox(
        "■ 使い方`n"
        "・ウィンドウのタイトルバーを Ctrl+右クリック、`n"
        "  または右ボタン長押し(0.4秒) → 色を選択`n"
        "・またはトレイアイコン右クリック →「ウィンドウ一覧から着色…」`n`n"
        "■ 注意`n"
        "・Windows 11 専用(DWM API を使用)`n"
        "・色はウィンドウを閉じるまで有効(アプリ再起動で戻ります)`n"
        "・Explorer / Terminal / Chrome などタイトルバー自前描画のアプリは`n"
        "  タイトルバー色が効かないため、周囲のオーバーレイ色枠で識別します`n"
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
    if Applied.Has(hwnd)
        Applied[hwnd].gui.Destroy()
    rec := {hex: StrReplace(hex, "#"), gui: MakeFrame(StrReplace(hex, "#")), last: ""}
    Applied[hwnd] := rec
    UpdateFrame(hwnd, rec)
    SetTimer(FrameTick, 50)
}

ResetWindow(hwnd, *) {
    for attr in [DWMWA_CAPTION_COLOR, DWMWA_BORDER_COLOR, DWMWA_TEXT_COLOR]
        SetAttr(hwnd, attr, DWMWA_COLOR_DEFAULT)
    if Applied.Has(hwnd) {
        Applied[hwnd].gui.Destroy()
        Applied.Delete(hwnd)
    }
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
    if Applied.Count = 0 {
        SetTimer(FrameTick, 0)
        return
    }
    for hwnd, rec in Applied.Clone()
        UpdateFrame(hwnd, rec)
}

UpdateFrame(hwnd, rec) {
    if !WinExist("ahk_id " hwnd) {
        rec.gui.Destroy()
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
