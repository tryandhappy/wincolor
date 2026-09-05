import Foundation
import AppKit

/// 色プリセット (shared/colors.json と同じ形)
struct Preset: Codable {
    let name: String
    let label: String
    let hex: String
    let textHex: String?
}

/// 解決済みの色。プリセット一致なら name が入る
struct ResolvedColor {
    let name: String?
    let hex: String   // "#RRGGBB" 大文字

    var description: String { name.map { "\($0) (\(hex))" } ?? hex }
    var display: String { name ?? hex }
    var nsColor: NSColor { NSColor(hex: hex) ?? .systemRed }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// 組み込み既定パレット。colors.json が読めない場合のみ使用 (内容は shared/colors.json と同一に保つ)
let DEFAULT_PRESETS: [Preset] = [
    Preset(name: "red",         label: "赤",   hex: "#C42B1C", textHex: "#FFFFFF"),
    Preset(name: "darkred",     label: "深紅", hex: "#7E1416", textHex: "#FFFFFF"),
    Preset(name: "pink",        label: "桃",   hex: "#E3008C", textHex: "#FFFFFF"),
    Preset(name: "orange",      label: "橙",   hex: "#CA5010", textHex: "#FFFFFF"),
    Preset(name: "apricot",     label: "杏",   hex: "#E8A33D", textHex: "#000000"),
    Preset(name: "brown",       label: "茶",   hex: "#8E562E", textHex: "#FFFFFF"),
    Preset(name: "yellow",      label: "黄",   hex: "#C19C00", textHex: "#000000"),
    Preset(name: "lightyellow", label: "薄黄", hex: "#E8DB4F", textHex: "#000000"),
    Preset(name: "lime",        label: "黄緑", hex: "#7CB342", textHex: "#000000"),
    Preset(name: "green",       label: "緑",   hex: "#107C10", textHex: "#FFFFFF"),
    Preset(name: "darkgreen",   label: "深緑", hex: "#1B5E20", textHex: "#FFFFFF"),
    Preset(name: "teal",        label: "青緑", hex: "#00897B", textHex: "#FFFFFF"),
    Preset(name: "cyan",        label: "水",   hex: "#00B7C3", textHex: "#FFFFFF"),
    Preset(name: "blue",        label: "青",   hex: "#0F6CBD", textHex: "#FFFFFF"),
    Preset(name: "navy",        label: "紺",   hex: "#1F3864", textHex: "#FFFFFF"),
    Preset(name: "sky",         label: "空",   hex: "#5B9BD5", textHex: "#000000"),
    Preset(name: "purple",      label: "紫",   hex: "#7A34A3", textHex: "#FFFFFF"),
    Preset(name: "wisteria",    label: "藤",   hex: "#A78BDA", textHex: "#000000"),
    Preset(name: "magenta",     label: "紅紫", hex: "#B4009E", textHex: "#FFFFFF"),
    Preset(name: "gray",        label: "灰",   hex: "#5D5D5D", textHex: "#FFFFFF"),
    Preset(name: "lightgray",   label: "薄灰", hex: "#A6A6A6", textHex: "#000000"),
    Preset(name: "darkgray",    label: "暗灰", hex: "#333333", textHex: "#FFFFFF"),
]

private let hexPattern = try! NSRegularExpression(pattern: "^#[0-9a-fA-F]{6}$")
func isHexColor(_ s: String) -> Bool {
    hexPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

/// 設定ファイルの探索順 (colors.json / rules.json 共通):
///   1. ~/.config/wincolor/<name>        (ユーザー設定。install.sh が rules.json の雛形を置く)
///   2. ~/.local/share/wincolor/<name>   (install.sh が colors.json を置く。upgrade で上書き)
///   3. 実行ファイルと同じディレクトリ    (zip を展開してそのまま使う場合)
///   4. 実行ファイル/../shared/<name>     (リポジトリ構成: macos/.build/release/wincolor → ../../../shared は遠いので
///      exe/../shared と exe/../../../../shared の両方を見る)
func configCandidates(_ name: String) -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    return [
        home.appendingPathComponent(".config/wincolor/\(name)"),
        home.appendingPathComponent(".local/share/wincolor/\(name)"),
        exe.appendingPathComponent(name),
        exe.appendingPathComponent("../shared/\(name)").standardized,
        exe.appendingPathComponent("../../../../shared/\(name)").standardized,
    ]
}

/// 探索順に JSON を読み、最初に読めたものを返す
func readFirstJSON<T: Decodable>(_ name: String, as type: T.Type) -> (URL, T)? {
    for url in configCandidates(name) {
        guard FileManager.default.fileExists(atPath: url.path) else { continue }
        do {
            let data = try Data(contentsOf: url)
            return (url, try JSONDecoder().decode(T.self, from: data))
        } catch {
            logMsg("failed to load \(url.path): \(error.localizedDescription)")
        }
    }
    return nil
}

struct ColorsFile: Decodable { let presets: [Preset] }

final class Palette {
    private(set) var presets: [Preset] = DEFAULT_PRESETS
    private(set) var sourcePath: String? = nil

    init() { reload() }

    func reload() {
        if let found = readFirstJSON("colors.json", as: ColorsFile.self) {
            let (url, file) = found
            let valid = file.presets.filter { !$0.name.isEmpty && isHexColor($0.hex) }
                .map { Preset(name: $0.name, label: $0.label, hex: $0.hex.uppercased(), textHex: $0.textHex) }
            if !valid.isEmpty {
                presets = valid
                sourcePath = url.path
                return
            }
            logMsg("\(url.path): no valid presets, using built-in defaults")
        }
        presets = DEFAULT_PRESETS
        sourcePath = nil
    }

    /// プリセット名 (大文字小文字無視) / ラベル / #RRGGBB を解決。解決できなければ nil
    func resolve(_ spec: String) -> ResolvedColor? {
        let s = spec.trimmingCharacters(in: .whitespaces)
        if let p = presets.first(where: { $0.name.lowercased() == s.lowercased() || $0.label == s }) {
            return ResolvedColor(name: p.name, hex: p.hex)
        }
        guard isHexColor(s) else { return nil }
        let hex = s.uppercased()
        if let p = presets.first(where: { $0.hex == hex }) {
            return ResolvedColor(name: p.name, hex: p.hex)
        }
        return ResolvedColor(name: nil, hex: hex)
    }

    /// 無タグ → 先頭色 → … → 末尾色 → 無タグ (nil) の順で循環
    func cycle(from currentHex: String?, direction: Int) -> ResolvedColor? {
        var idx = (presets.firstIndex(where: { $0.hex == currentHex }) ?? -1) + direction
        if idx < -1 { idx = presets.count - 1 } else if idx >= presets.count { idx = -1 }
        guard idx >= 0 else { return nil }
        return ResolvedColor(name: presets[idx].name, hex: presets[idx].hex)
    }

    var listing: String {
        (["# source: \(sourcePath ?? "built-in defaults")"] + presets.map { "\($0.name)\t\($0.label)\t\($0.hex)" })
            .joined(separator: "\n")
    }
}

func logMsg(_ msg: String) {
    FileHandle.standardError.write("[wincolor] \(msg)\n".data(using: .utf8)!)
}
