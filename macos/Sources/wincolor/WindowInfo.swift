import Foundation
import AppKit
import ApplicationServices

/// CGWindowList から得た 1 ウィンドウの情報。bounds は CG 座標 (原点: メインディスプレイ左上、y は下向き)
struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let ownerName: String
    let bounds: CGRect
    let cgTitle: String?     // kCGWindowName。画面収録の権限が無いと nil
    let zIndex: Int          // 0 が最前面

    /// CG 座標 → AppKit 座標 (原点: メインディスプレイ左下、y は上向き)
    var appKitFrame: NSRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: bounds.minX, y: mainHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }
}

enum WindowList {
    /// 画面上の通常ウィンドウ (layer 0) を前面から順に返す。自プロセスの窓 (オーバーレイ) は除く
    static func onScreen() -> [WindowInfo] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = getpid()
        var out: [WindowInfo] = []
        for info in raw {
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != me,
                  let bdict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: bdict as CFDictionary),
                  bounds.width >= 50, bounds.height >= 30
            else { continue }
            if let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha == 0 { continue }
            out.append(WindowInfo(
                id: id, pid: pid,
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "?",
                bounds: bounds,
                cgTitle: info[kCGWindowName as String] as? String,
                zIndex: out.count))
        }
        return out
    }
}

// AXUIElement から CGWindowID を得る (公開ヘッダに無いが広く使われている API。yabai / Rectangle 等も使用)
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Accessibility API でウィンドウタイトルを取る (画面収録の権限なしで済む)
enum AXTitles {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// 対象 pid のウィンドウについて CGWindowID → タイトル の辞書を返す
    static func titles(pid: pid_t) -> [CGWindowID: String] {
        guard trusted else { return [:] }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [:] }
        var out: [CGWindowID: String] = [:]
        for w in windows {
            var wid: CGWindowID = 0
            guard _AXUIElementGetWindow(w, &wid) == .success, wid != 0 else { continue }
            var t: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t) == .success, let s = t as? String {
                out[wid] = s
            }
        }
        return out
    }

    static func promptIfNeeded() {
        if trusted { return }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        logMsg("Accessibility 権限がありません。システム設定 → プライバシーとセキュリティ → アクセシビリティ で wincolor を許可してください (タイトル取得と Ctrl+右クリックに必要)")
    }
}

enum ProcessInfoUtil {
    /// ルールの exe 照合に使う候補: 実行ファイル名 / アプリ名 / バンドル ID
    static func exeCandidates(pid: pid_t) -> [String] {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return [] }
        var c: [String] = []
        if let n = app.executableURL?.lastPathComponent { c.append(n) }
        if let n = app.localizedName { c.append(n) }
        if let n = app.bundleIdentifier { c.append(n) }
        return c
    }

    static func parentPid(_ pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    /// child が ancestor と一致するか、その子孫か
    static func isDescendant(_ child: pid_t, of ancestor: pid_t) -> Bool {
        var cur = child
        var depth = 0
        while cur > 1 && depth < 32 {
            if cur == ancestor { return true }
            cur = parentPid(cur)
            depth += 1
        }
        return false
    }
}
