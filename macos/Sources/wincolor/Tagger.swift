import AppKit
import ApplicationServices

/// 常駐本体: タグ管理、50ms 追従、自動ルール、ランチャー待ち、メニューバー、Ctrl+右クリック
final class Tagger: NSObject, NSMenuDelegate {
    static let shared = Tagger()

    let palette = Palette()
    let rules = Rules()

    private struct Tag {
        var color: ResolvedColor
        let overlay: OverlayWindow
    }
    private var tags: [CGWindowID: Tag] = [:]
    private var ruleDone: Set<CGWindowID> = []          // 色を確定した窓 (ルール適用済み / 手動操作済み)
    private var knownWindows: Set<CGWindowID> = []      // 前回 tick に存在した窓
    private var titleCache: [pid_t: [CGWindowID: String]] = [:]
    private var tickCount = 0
    private var timer: Timer?
    private var statusItem: NSStatusItem?
    private var eventTap: CFMachPort?
    private var lastWindows: [WindowInfo] = []

    // ランチャー (wincolor run) の待ち
    private struct PendingLaunch {
        let token: String
        let pid: pid_t
        let color: ResolvedColor
        let deadline: Date
        var fallback: CGWindowID?
        var fallbackSince: Date?
        var result: String?
    }
    private var launches: [String: PendingLaunch] = [:]
    private let launchFallbackGrace: TimeInterval = 1.5

    // MARK: - lifecycle

    func start() {
        rules.reload(palette: palette)
        AXTitles.promptIfNeeded()
        setupStatusItem()
        setupEventTap()
        knownWindows = Set(WindowList.onScreen().map { $0.id })
        // 起動時に既にある窓もルールの対象にする (Windows 版と同じ)
        evaluateRules(for: WindowList.onScreen())
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    // MARK: - tick (50ms)

    private func tick() {
        tickCount += 1
        let windows = WindowList.onScreen()
        lastWindows = windows
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })

        // オーバーレイの追従。画面上に無い窓 (最小化 / 別 Space / 閉じた) は隠す
        for (id, tag) in tags {
            if let w = byID[id] {
                tag.overlay.track(targetFrame: w.appKitFrame, targetWindowID: id)
                if !tag.overlay.isVisible { tag.overlay.orderFront(nil); tag.overlay.track(targetFrame: w.appKitFrame, targetWindowID: id) }
            } else if tag.overlay.isVisible {
                tag.overlay.orderOut(nil)
            }
        }

        // 新規窓の検出
        let current = Set(windows.map { $0.id })
        let created = windows.filter { !knownWindows.contains($0.id) }
        knownWindows = current
        if !created.isEmpty {
            handleLaunches(newWindows: created)
        }
        // ルール照合: 新規窓は毎 tick、既存の未確定窓は 10 tick (0.5 秒) ごと (タイトルは後から付くことがある)
        if !created.isEmpty || tickCount % 10 == 0 {
            titleCache = [:]
            evaluateRules(for: tickCount % 10 == 0 ? windows : created)
        }
        // 閉じた窓の後片付け
        for id in Array(tags.keys) where !current.contains(id) && !windowStillExists(id) {
            removeTag(id)
        }
        ruleDone = ruleDone.filter { current.contains($0) || windowStillExists($0) }
        expireLaunches()
    }

    /// 最小化・別 Space の窓は onScreen に出ないので、全リストで存在確認する
    private func windowStillExists(_ id: CGWindowID) -> Bool {
        guard let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return false }
        return raw.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }
    }

    private func title(of w: WindowInfo) -> String {
        if titleCache[w.pid] == nil { titleCache[w.pid] = AXTitles.titles(pid: w.pid) }
        return titleCache[w.pid]?[w.id] ?? w.cgTitle ?? ""
    }

    // MARK: - tags

    @discardableResult
    func setTag(_ id: CGWindowID, color: ResolvedColor, manual: Bool) -> Bool {
        if manual { ruleDone.insert(id) }
        if var t = tags[id] {
            t.color = color
            t.overlay.color = color.nsColor
            tags[id] = t
            return true
        }
        let ov = OverlayWindow.make()
        ov.color = color.nsColor
        tags[id] = Tag(color: color, overlay: ov)
        if let w = lastWindows.first(where: { $0.id == id }) ?? WindowList.onScreen().first(where: { $0.id == id }) {
            ov.track(targetFrame: w.appKitFrame, targetWindowID: id)
            ov.orderFront(nil)
            ov.track(targetFrame: w.appKitFrame, targetWindowID: id)
        }
        return true
    }

    func removeTag(_ id: CGWindowID) {
        guard let t = tags.removeValue(forKey: id) else { return }
        t.overlay.orderOut(nil)
        t.overlay.close()
    }

    func clearAll(manual: Bool) {
        for id in Array(tags.keys) {
            if manual { ruleDone.insert(id) }
            removeTag(id)
        }
    }

    func currentColor(_ id: CGWindowID) -> ResolvedColor? { tags[id]?.color }

    // MARK: - rules

    private func evaluateRules(for windows: [WindowInfo]) {
        guard !rules.rules.isEmpty else { return }
        for w in windows where !ruleDone.contains(w.id) {
            let title = title(of: w)
            if title.isEmpty { continue }   // タイトルは後から付くことがあるので、付いてから照合
            let exes = ProcessInfoUtil.exeCandidates(pid: w.pid) + [w.ownerName]
            for r in rules.rules where r.matches(title: title, exeCandidates: exes) {
                if let c = palette.resolve(r.color) {
                    ruleDone.insert(w.id)
                    setTag(w.id, color: c, manual: false)
                }
                break
            }
        }
    }

    func reload() -> String {
        palette.reload()
        rules.reload(palette: palette)
        evaluateRules(for: WindowList.onScreen())
        return "presets: \(palette.presets.count) (\(palette.sourcePath ?? "built-in defaults"))\n" +
               "rules: \(rules.rules.count) (\(rules.sourcePath ?? "none"))"
    }

    // MARK: - launcher (wincolor run)

    func registerLaunch(pid: pid_t, color: ResolvedColor, timeoutMs: Int) -> String {
        let token = UUID().uuidString
        var p = PendingLaunch(token: token, pid: pid, color: color,
                              deadline: Date().addingTimeInterval(Double(min(max(timeoutMs, 500), 120_000)) / 1000),
                              fallback: nil, fallbackSince: nil, result: nil)
        // すでに窓が出ている場合
        if let w = WindowList.onScreen().first(where: { ProcessInfoUtil.isDescendant($0.pid, of: pid) }) {
            p.result = finishLaunch(p, window: w, how: "pid")
        }
        launches[token] = p
        return token
    }

    func launchStatus(_ token: String) -> String {
        guard let p = launches[token] else { return "unknown token" }
        if let r = p.result { launches.removeValue(forKey: token); return r }
        return "pending"
    }

    private func finishLaunch(_ p: PendingLaunch, window w: WindowInfo?, how: String) -> String {
        guard let w = w else { return "no window appeared for pid \(p.pid)" }
        setTag(w.id, color: p.color, manual: true)
        return "ok: [\(w.id)] \(w.ownerName) \"\(title(of: w))\" -> \(p.color.description) (matched by \(how), pid \(w.pid))"
    }

    private func handleLaunches(newWindows: [WindowInfo]) {
        for (token, p0) in launches where p0.result == nil {
            var p = p0
            for w in newWindows {
                if ProcessInfoUtil.isDescendant(w.pid, of: p.pid) {
                    p.result = finishLaunch(p, window: w, how: "pid")
                    break
                } else if p.fallback == nil {
                    p.fallback = w.id
                    p.fallbackSince = Date()
                }
            }
            launches[token] = p
        }
    }

    private func expireLaunches() {
        let now = Date()
        for (token, p0) in launches where p0.result == nil {
            var p = p0
            if let since = p.fallbackSince, now.timeIntervalSince(since) >= launchFallbackGrace, let fid = p.fallback {
                p.result = finishLaunch(p, window: lastWindows.first(where: { $0.id == fid }), how: "fallback")
            } else if now >= p.deadline {
                let fw = p.fallback.flatMap { fid in lastWindows.first(where: { $0.id == fid }) }
                p.result = finishLaunch(p, window: fw, how: "fallback (timeout)")
            }
            launches[token] = p
        }
    }

    // MARK: - IPC request handling (Linux 版の D-Bus と同じ語彙)

    func handle(_ line: String) -> String {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let cmd = parts.first else { return "empty request" }
        switch cmd {
        case "version": return "wincolor (macos) v\(WINCOLOR_VERSION)"
        case "list": return listing()
        case "colors": return palette.listing
        case "rules": return rules.listing
        case "reload": return reload()
        case "clear-all": clearAll(manual: true); return "ok"
        case "set":
            guard parts.count >= 3 else { return "usage: set <id|focused> <color>" }
            guard let w = resolveTarget(parts[1]) else { return "no window for target: \(parts[1])" }
            let spec = parts[2...].joined(separator: " ")
            let color: ResolvedColor?
            if spec == "next" || spec == "prev" {
                color = palette.cycle(from: currentColor(w.id)?.hex, direction: spec == "next" ? 1 : -1)
                if color == nil { ruleDone.insert(w.id); removeTag(w.id); return "cleared: [\(w.id)]" }
            } else {
                color = palette.resolve(spec)
                if color == nil {
                    return "invalid color: \(spec) (use #RRGGBB or one of: \(palette.presets.map { $0.name }.joined(separator: ", ")))"
                }
            }
            setTag(w.id, color: color!, manual: true)
            return "ok: [\(w.id)] \(w.ownerName) \"\(title(of: w))\" -> \(color!.description)"
        case "clear":
            guard parts.count >= 2 else { return "usage: clear <id|focused>" }
            guard let w = resolveTarget(parts[1]) else { return "no window for target: \(parts[1])" }
            ruleDone.insert(w.id)
            guard tags[w.id] != nil else { return "not tagged" }
            removeTag(w.id)
            return "cleared: [\(w.id)]"
        case "tagpid":
            guard parts.count >= 4, let pid = Int32(parts[1]), let ms = Int(parts[3]) else { return "usage: tagpid <pid> <color> <timeoutMs>" }
            guard let c = palette.resolve(parts[2]) else { return "invalid color: \(parts[2])" }
            return "pending " + registerLaunch(pid: pid, color: c, timeoutMs: ms)
        case "launch":
            guard parts.count >= 2 else { return "usage: launch <token>" }
            return launchStatus(parts[1])
        default:
            return "unknown command: \(cmd)"
        }
    }

    private func listing() -> String {
        titleCache = [:]
        return WindowList.onScreen().map { w in
            "\(w.id)\t\(w.ownerName)\t\(tags[w.id]?.color.display ?? "-")\t\(title(of: w))"
        }.joined(separator: "\n")
    }

    /// "focused" = 最前面アプリの最前面の窓、それ以外は CGWindowID
    private func resolveTarget(_ target: String) -> WindowInfo? {
        let windows = WindowList.onScreen()
        if target == "focused" {
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
            return windows.first(where: { $0.pid == pid })
        }
        guard let id = UInt32(target) else { return nil }
        if let w = windows.first(where: { $0.id == id }) { return w }
        return nil
    }

    // MARK: - menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "wincolor") {
            item.button?.image = img
        } else {
            item.button?.title = "■"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let head = NSMenuItem(title: "wincolor v\(WINCOLOR_VERSION) - ウィンドウ着色", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())

        let windowsItem = NSMenuItem(title: "ウィンドウ一覧から着色…", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for w in WindowList.onScreen() {
            let t = title(of: w)
            let label = "\(w.ownerName)\(t.isEmpty ? "" : " - " + t)"
            let wi = NSMenuItem(title: String(label.prefix(60)), action: nil, keyEquivalent: "")
            wi.submenu = colorMenu(for: w.id)
            if let c = tags[w.id]?.color { wi.image = swatchImage(c.nsColor) }
            sub.addItem(wi)
        }
        if sub.items.isEmpty { sub.addItem(NSMenuItem(title: "(ウィンドウなし)", action: nil, keyEquivalent: "")) }
        windowsItem.submenu = sub
        menu.addItem(windowsItem)

        menu.addItem(NSMenuItem(title: "全部消す", action: #selector(menuClearAll), keyEquivalent: "").withTarget(self))
        menu.addItem(NSMenuItem(title: "colors.json / rules.json を再読み込み", action: #selector(menuReload), keyEquivalent: "").withTarget(self))
        menu.addItem(.separator())
        let ax = NSMenuItem(title: AXTitles.trusted ? "アクセシビリティ: 許可済み" : "アクセシビリティ: 未許可 (クリックで設定を開く)",
                            action: #selector(menuOpenAX), keyEquivalent: "").withTarget(self)
        menu.addItem(ax)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "使い方", action: #selector(menuHelp), keyEquivalent: "").withTarget(self))
        menu.addItem(NSMenuItem(title: "終了", action: #selector(menuQuit), keyEquivalent: "q").withTarget(self))
    }

    /// 対象窓用の色メニュー (プリセット + 既定に戻す)
    func colorMenu(for id: CGWindowID) -> NSMenu {
        let m = NSMenu()
        let current = tags[id]?.color.hex
        for p in palette.presets {
            let mi = NSMenuItem(title: "\(p.label) (\(p.name))", action: #selector(menuPickColor(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = ["id": NSNumber(value: id), "hex": p.hex] as [String: Any]
            mi.image = swatchImage(NSColor(hex: p.hex) ?? .gray)
            mi.state = (p.hex == current) ? .on : .off
            m.addItem(mi)
        }
        m.addItem(.separator())
        let off = NSMenuItem(title: "既定に戻す", action: #selector(menuClearColor(_:)), keyEquivalent: "")
        off.target = self
        off.representedObject = ["id": NSNumber(value: id)] as [String: Any]
        m.addItem(off)
        return m
    }

    private func swatchImage(_ color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return img
    }

    @objc private func menuPickColor(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? [String: Any],
              let id = (d["id"] as? NSNumber)?.uint32Value, let hex = d["hex"] as? String,
              let c = palette.resolve(hex) else { return }
        setTag(id, color: c, manual: true)
    }
    @objc private func menuClearColor(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? [String: Any],
              let id = (d["id"] as? NSNumber)?.uint32Value else { return }
        ruleDone.insert(id)
        removeTag(id)
    }
    @objc private func menuClearAll() { clearAll(manual: true) }
    @objc private func menuReload() { _ = reload() }
    @objc private func menuOpenAX() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func menuHelp() {
        let a = NSAlert()
        a.messageText = "wincolor の使い方"
        a.informativeText = """
        ・ウィンドウのタイトルバーを Ctrl+右クリック → 色メニュー
        ・メニューバーのアイコン → 「ウィンドウ一覧から着色…」
        ・ターミナル: wincolor list / wincolor <ID> red / wincolor run red <アプリ>
        ・自動ルール: ~/.config/wincolor/rules.json (保存後は「再読み込み」)
        ・色は colors.json のプリセット名 / ラベル / #RRGGBB
        """
        a.runModal()
    }
    @objc private func menuQuit() {
        clearAll(manual: false)
        NSApp.terminate(nil)
    }

    // MARK: - Ctrl+右クリック (CGEventTap。Accessibility 権限が必要)

    private func setupEventTap() {
        let mask = CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = Tagger.shared.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if Tagger.shared.handleRightClick(event) { return nil }   // 消費 (対象アプリには渡さない)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback, userInfo: nil) else {
            logMsg("Ctrl+右クリックの監視を開始できません (Accessibility 権限が必要)。メニューバーか CLI から操作してください")
            return
        }
        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Ctrl+右クリックがタイトルバー領域なら色メニューを出して true
    private func handleRightClick(_ event: CGEvent) -> Bool {
        guard event.flags.contains(.maskControl) else { return false }
        let loc = event.location   // CG 座標 (左上原点) なので kCGWindowBounds とそのまま比較できる
        guard let w = WindowList.onScreen().first(where: { $0.bounds.contains(loc) }) else { return false }
        let titleArea = CGRect(x: w.bounds.minX, y: w.bounds.minY, width: w.bounds.width, height: TINT_HEIGHT + 4)
        guard titleArea.contains(loc) else { return false }
        DispatchQueue.main.async { [self] in
            NSApp.activate(ignoringOtherApps: true)
            let menu = colorMenu(for: w.id)
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            menu.popUp(positioning: nil, at: NSPoint(x: loc.x, y: mainHeight - loc.y), in: nil)
        }
        return true
    }
}

private extension NSMenuItem {
    func withTarget(_ t: AnyObject) -> NSMenuItem { target = t; return self }
}
