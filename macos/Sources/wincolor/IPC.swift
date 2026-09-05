import Foundation

/// 常駐 ⇄ CLI の通信。CFMessagePort (同一ログインセッション内、要求/応答) を使う。
/// リクエストは 1 行のテキスト、応答もテキスト
enum IPC {
    /// 常駐側: ポートを開き、handler で応答する
    static func serve(handler: @escaping (String) -> String) -> Bool {
        final class Box { let handler: (String) -> String; init(_ h: @escaping (String) -> String) { handler = h } }
        let box = Box(handler)
        var ctx = CFMessagePortContext(version: 0, info: Unmanaged.passRetained(box).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: CFMessagePortCallBack = { _, _, data, info in
            guard let info = info else { return nil }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let req = data.flatMap { String(data: $0 as Data, encoding: .utf8) } ?? ""
            let resp = box.handler(req)
            return Unmanaged.passRetained((resp.data(using: .utf8) ?? Data()) as CFData)
        }
        var shouldFree: DarwinBoolean = false
        guard let port = CFMessagePortCreateLocal(nil, IPC_PORT_NAME as CFString, callback, &ctx, &shouldFree) else {
            return false
        }
        let source = CFMessagePortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    /// CLI 側: 常駐へ送って応答を返す。常駐がいなければ nil
    static func request(_ line: String, timeout: TimeInterval = 5) -> String? {
        guard let remote = CFMessagePortCreateRemote(nil, IPC_PORT_NAME as CFString) else { return nil }
        var reply: Unmanaged<CFData>?
        let st = CFMessagePortSendRequest(remote, 0, line.data(using: .utf8)! as CFData, timeout, timeout,
                                          CFRunLoopMode.defaultMode.rawValue, &reply)
        guard st == kCFMessagePortSuccess else { return nil }
        guard let d = reply?.takeRetainedValue() else { return "" }
        return String(data: d as Data, encoding: .utf8) ?? ""
    }

    static var residentRunning: Bool {
        CFMessagePortCreateRemote(nil, IPC_PORT_NAME as CFString) != nil
    }
}
