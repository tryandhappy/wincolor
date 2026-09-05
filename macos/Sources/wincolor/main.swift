import AppKit
import Foundation

// wincolor (macOS版) - ウィンドウ単位で枠＋タイトルバーの色タグを付ける
//
// 使い方:
//   wincolor                      常駐 (メニューバー)。install.sh が LaunchAgent で自動起動にする
//   wincolor list                 ウィンドウ一覧 (ID / アプリ / 現在の色 / タイトル)
//   wincolor colors               使える色プリセット一覧 (shared/colors.json 由来。名前 / ラベル / HEX)
//   wincolor <ID> <色>            指定ウィンドウに色を付ける (プリセット名 red, 青 など、または #RRGGBB)
//   wincolor <ID> off             指定ウィンドウの色を消す
//   wincolor focused <色>         最前面ウィンドウに色
//   wincolor focused next|prev    パレットを順送り/逆送り (末尾の次は色なし)
//   wincolor focused off
//   wincolor clear-all            全部消す
//   wincolor run <色> <コマンド...>  コマンド (またはアプリ名 / .app) を起動し、そのウィンドウに色を付ける
//   wincolor rules                読み込み済みの自動ルール一覧 (title / exe / color)
//   wincolor reload               colors.json / rules.json を再読み込み
//   wincolor --version
//
// 常駐との通信は CFMessagePort (jp.smart2j.wincolor)。常駐していないと list 等は失敗する。

let usage = """
wincolor (macos) v\(WINCOLOR_VERSION) - ウィンドウ単位で枠＋タイトルバーの色タグを付ける

使い方:
  wincolor                      常駐 (メニューバー)
  wincolor list                 ウィンドウ一覧 (ID / アプリ / 現在の色 / タイトル)
  wincolor colors               使える色プリセット一覧 (名前 / ラベル / HEX)
  wincolor <ID> <色>            指定ウィンドウに色を付ける (プリセット名 red, 青 など、または #RRGGBB)
  wincolor <ID> off             指定ウィンドウの色を消す
  wincolor focused <色>         最前面ウィンドウに色
  wincolor focused next|prev    パレットを順送り/逆送り (末尾の次は色なし)
  wincolor focused off
  wincolor clear-all            全部消す
  wincolor run <色> <コマンド...>  コマンド (またはアプリ名 / .app) を起動し、そのウィンドウに色を付ける
                                (WINCOLOR_RUN_TIMEOUT 秒、既定 10)
  wincolor rules                読み込み済みの自動ルール一覧 (title / exe / color)
  wincolor reload               colors.json / rules.json を再読み込み
  wincolor --version            バージョン表示

操作: ウィンドウのタイトルバーを Ctrl+右クリック → 色メニュー / メニューバーのアイコン → ウィンドウ一覧
自動ルール: ~/.config/wincolor/rules.json (install.sh が雛形を置く)
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("error: \(msg)\n".data(using: .utf8)!)
    exit(2)
}

func requireResident(_ line: String, timeout: TimeInterval = 5) -> String {
    guard let r = IPC.request(line, timeout: timeout) else {
        fail("常駐の wincolor が起動していません (引数なしで wincolor を起動、または install.sh で LaunchAgent を登録)")
    }
    return r
}

/// ランチャー: 色を検証 → コマンドを起動 → 常駐に PID の窓への着色を依頼 → 結果を待つ
func runLauncher(_ args: [String]) -> Never {
    guard args.count >= 2 else { fail("使い方: wincolor run <色> <コマンド...>") }
    let color = args[0]
    let cmd = Array(args[1...])
    let palette = Palette()
    guard palette.resolve(color) != nil else { fail("不明な色です: \(color) (wincolor colors で一覧)") }
    guard IPC.residentRunning else { fail("常駐の wincolor が起動していません") }

    let pid: pid_t
    let first = cmd[0]
    let looksLikeApp = first.hasSuffix(".app") || (!first.contains("/") && FileManager.default.fileExists(atPath: "/Applications/\(first).app"))
    if looksLikeApp {
        // アプリ名 / .app: NSWorkspace で起動して pid を得る (open -a 相当。引数は URL ではなく arguments に渡す)
        let appURL = first.hasSuffix(".app") ? URL(fileURLWithPath: first) : URL(fileURLWithPath: "/Applications/\(first).app")
        let conf = NSWorkspace.OpenConfiguration()
        conf.arguments = Array(cmd.dropFirst())
        conf.createsNewApplicationInstance = false
        let sem = DispatchSemaphore(value: 0)
        var launched: pid_t = 0
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: appURL, configuration: conf) { app, err in
            launched = app?.processIdentifier ?? 0
            launchError = err
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 15)
        if let e = launchError { fail("起動に失敗しました: \(first): \(e.localizedDescription)") }
        pid = launched
    } else {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = cmd
        do { try p.run() } catch { fail("起動に失敗しました: \(cmd.joined(separator: " ")): \(error.localizedDescription)") }
        pid = p.processIdentifier
    }
    guard pid > 0 else { fail("起動したプロセスの PID を取得できませんでした") }

    let timeoutSec = Int(ProcessInfo.processInfo.environment["WINCOLOR_RUN_TIMEOUT"] ?? "") ?? 10
    let reg = requireResident("tagpid \(pid) \(color) \(timeoutSec * 1000)")
    guard reg.hasPrefix("pending ") else { print(reg); exit(reg.hasPrefix("ok") ? 0 : 1) }
    let token = String(reg.dropFirst("pending ".count))
    let deadline = Date().addingTimeInterval(Double(timeoutSec) + 3)
    while Date() < deadline {
        let st = requireResident("launch \(token)")
        if st != "pending" { print(st); exit(st.hasPrefix("ok") ? 0 : 1) }
        Thread.sleep(forTimeInterval: 0.2)
    }
    fail("タイムアウト: 対象ウィンドウが見つかりませんでした")
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case nil:
    // 常駐モード
    if IPC.residentRunning { fail("wincolor はすでに常駐しています") }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard IPC.serve(handler: { Tagger.shared.handle($0) }) else { fail("CFMessagePort を開けません") }
    Tagger.shared.start()
    app.run()
case "--version", "-V":
    print("wincolor (macos) v\(WINCOLOR_VERSION)")
case "-h", "--help", "help":
    print(usage)
case "run":
    runLauncher(Array(args.dropFirst()))
case "list", "colors", "rules", "reload", "clear-all", "version":
    print(requireResident(args[0]))
default:
    // <ID|focused> <色|off|next|prev>
    guard args.count >= 2 else { fail("色を指定してください (例: wincolor \(args[0]) red / off)") }
    let target = args[0]
    let color = args[1...].joined(separator: " ")
    print(requireResident(color == "off" ? "clear \(target)" : "set \(target) \(color)"))
}
