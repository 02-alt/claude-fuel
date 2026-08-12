import Foundation

struct UsageEntry {
    let date: Date
    let tokens: Int
    let model: String
}

struct UsageBlock {
    var start: Date
    var end: Date            // start + window
    var used: Int
    var lastActivity: Date
    var perModel: [String: Int]
    var isActive: Bool       // window still open and recently active
}

enum UsageReader {

    // Read every *.jsonl transcript under the projects path and pull token usage.
    static func load(projectsPath: String, includeCacheReads: Bool) -> [UsageEntry] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: projectsPath) else { return [] }
        var entries: [UsageEntry] = []

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        for case let rel as String in en where rel.hasSuffix(".jsonl") {
            let full = (projectsPath as NSString).appendingPathComponent(rel)
            guard let data = fm.contents(atPath: full),
                  let text = String(data: data, encoding: .utf8) else { continue }

            text.enumerateLines { line, _ in
                // Cheap pre-filter: only assistant lines carry a usage object.
                guard line.contains("\"usage\"") else { return }
                guard let ld = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: ld) as? [String: Any]
                else { return }

                guard let ts = obj["timestamp"] as? String,
                      let msg = obj["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any] else { return }

                let date = iso.date(from: ts) ?? isoPlain.date(from: ts)
                guard let date else { return }

                let input  = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                let cc     = usage["cache_creation_input_tokens"] as? Int ?? 0
                let cr     = usage["cache_read_input_tokens"] as? Int ?? 0
                var total = input + output + cc
                if includeCacheReads { total += cr }
                let model = (msg["model"] as? String) ?? "unknown"
                if total == 0 || model == "<synthetic>" { return }

                entries.append(UsageEntry(date: date, tokens: total, model: model))
            }
        }
        entries.sort { $0.date < $1.date }
        return entries
    }

    // Group entries into rolling windows (ccusage-style "blocks") and return the
    // block that is currently active — i.e. your live token "tank".
    static func currentBlock(entries: [UsageEntry], windowHours: Double, now: Date = Date()) -> UsageBlock? {
        guard !entries.isEmpty else { return nil }
        let window = windowHours * 3600

        func floorHour(_ d: Date) -> Date {
            let t = (d.timeIntervalSince1970 / 3600).rounded(.down) * 3600
            return Date(timeIntervalSince1970: t)
        }

        var blocks: [UsageBlock] = []
        var start = floorHour(entries[0].date)
        var used = 0
        var perModel: [String: Int] = [:]
        var last = entries[0].date

        func closeBlock() {
            blocks.append(UsageBlock(start: start, end: start.addingTimeInterval(window),
                                     used: used, lastActivity: last,
                                     perModel: perModel, isActive: false))
        }

        for e in entries {
            let sinceStart = e.date.timeIntervalSince(start)
            let sinceLast  = e.date.timeIntervalSince(last)
            if used > 0, sinceStart >= window || sinceLast >= window {
                closeBlock()
                start = floorHour(e.date)
                used = 0
                perModel = [:]
            }
            used += e.tokens
            perModel[e.model, default: 0] += e.tokens
            last = e.date
        }
        closeBlock()

        guard var block = blocks.last else { return nil }
        // Active only if the window hasn't elapsed and activity is recent.
        block.isActive = now < block.end && now.timeIntervalSince(block.lastActivity) < window
        return block
    }
}
