import Foundation

/// shared/rules.json と同じ形式:
///   { "rules": [ { "title": "正規表現", "exe": "正規表現", "color": "プリセット名 or #RRGGBB" } ] }
/// title / exe は片方だけでも可 (大文字小文字無視)。macOS では exe を実行ファイル名・アプリ名・
/// バンドル ID のいずれかに照合する。上のルールが優先
struct RuleEntry: Decodable {
    let title: String?
    let exe: String?
    let color: String?
}
struct RulesFile: Decodable { let rules: [RuleEntry]? }

struct Rule {
    let title: NSRegularExpression?
    let exe: NSRegularExpression?
    let titleSrc: String
    let exeSrc: String
    let color: String

    func matches(title: String, exeCandidates: [String]) -> Bool {
        if let t = self.title, t.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) == nil {
            return false
        }
        if let e = self.exe {
            let hit = exeCandidates.contains { c in
                e.firstMatch(in: c, range: NSRange(c.startIndex..., in: c)) != nil
            }
            if !hit { return false }
        }
        return true
    }
}

final class Rules {
    private(set) var rules: [Rule] = []
    private(set) var sourcePath: String? = nil

    func reload(palette: Palette) {
        rules = []
        guard let found = readFirstJSON("rules.json", as: RulesFile.self) else {
            sourcePath = nil
            return
        }
        let (url, file) = found
        sourcePath = url.path
        for (i, r) in (file.rules ?? []).enumerated() {
            let title = (r.title?.isEmpty == false) ? r.title : nil
            let exe = (r.exe?.isEmpty == false) ? r.exe : nil
            let color = r.color ?? ""
            if (title == nil && exe == nil) || color.isEmpty {
                logMsg("rules[\(i)]: needs title and/or exe, and color; skipped")
                continue
            }
            if palette.resolve(color) == nil {
                logMsg("rules[\(i)]: unknown color \"\(color)\"; skipped")
                continue
            }
            do {
                let tre = try title.map { try NSRegularExpression(pattern: $0, options: .caseInsensitive) }
                let ere = try exe.map { try NSRegularExpression(pattern: $0, options: .caseInsensitive) }
                rules.append(Rule(title: tre, exe: ere, titleSrc: title ?? "", exeSrc: exe ?? "", color: color))
            } catch {
                logMsg("rules[\(i)]: invalid regex (\(error.localizedDescription)); skipped")
            }
        }
    }

    var listing: String {
        (["# source: \(sourcePath ?? "none")"] +
         rules.map { "\($0.titleSrc.isEmpty ? "-" : $0.titleSrc)\t\($0.exeSrc.isEmpty ? "-" : $0.exeSrc)\t\($0.color)" })
            .joined(separator: "\n")
    }
}
