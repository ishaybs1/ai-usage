import Foundation

// MARK: - Claude session billing (Claudoscope-compatible)
//
// Port of Claudoscope's SessionParser billing rules: bill only assistant records that
// carry `stop_reason` (final cumulative usage) or orphan max-usage records, dedupe by
// `message.id`, skip parent-history replays in context-fork subagent files, and apply
// fast-mode pricing when `usage.speed` is non-standard.

enum ClaudeSessionBilling {

    struct BillableTurn: Equatable {
        let dayKey: String
        let sessionId: String?
        let model: String
        let cost: Double
        let tokens: TokenUsage
        let entrypoint: String?
    }

    private struct RawRecord {
        let index: Int
        let type: String
        let uuid: String?
        let sessionId: String?
        let timestamp: String?
        let entrypoint: String?
        let isSidechain: Bool
        let messageId: String?
        let model: String?
        let stopReason: String?
        let usage: [String: Any]?
        let speed: String?
    }

    /// Context-forking subagent files replay the parent transcript before new calls.
    private static func isContextForkFilename(_ name: String) -> Bool {
        name.hasPrefix("agent-acompact-") || name.hasPrefix("agent-aside_question-")
    }

    /// Billable assistant `message.id`s from the parent transcript of a subagent file.
    static func parentReplayMessageIds(forSubagentFileAt url: URL) -> Set<String> {
        let parentURL = url.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathExtension("jsonl")
        guard let data = try? Data(contentsOf: parentURL) else { return [] }
        var ids = Set<String>()
        for line in utf8Lines(in: data) {
            guard let obj = parseJSONObject(line),
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  msg["usage"] != nil,
                  let id = msg["id"] as? String else { continue }
            ids.insert(id)
        }
        return ids
    }

    /// Extract every billable turn from one JSONL file's bytes.
    static func billableTurns(in data: Data, fileURL: URL) -> [BillableTurn] {
        let sessionId = fileURL.deletingPathExtension().lastPathComponent
        let isSubagentFile = fileURL.deletingLastPathComponent().lastPathComponent == "subagents"
        let parentReplay = (isSubagentFile && isContextForkFilename(fileURL.lastPathComponent))
            ? parentReplayMessageIds(forSubagentFileAt: fileURL) : []

        var records: [RawRecord] = []
        var idx = 0
        for line in utf8Lines(in: data) {
            defer { idx += 1 }
            guard let obj = parseJSONObject(line) else { continue }
            records.append(parseRaw(obj, index: idx))
        }

        let stopReasonIds = Set(records.compactMap { r -> String? in
            guard r.type == "assistant", r.stopReason != nil, let id = r.messageId else { return nil }
            return id
        })
        let orphanChosen = selectOrphanBillingIndices(records, stopReasonIds: stopReasonIds)

        var seenMsgIds = Set<String>()
        var seenUUIDs = Set<String>()
        var parentSessionId: String?
        var isFirst = true
        var lastDayKey: String?
        var turns: [BillableTurn] = []

        for raw in records {
            if let ts = raw.timestamp, let dk = localDayKey(ts) { lastDayKey = dk }

            let isSidechain = raw.isSidechain || isSubagentFile
            if isFirst {
                isFirst = false
                if !isSidechain, let sid = raw.sessionId, sid != sessionId {
                    parentSessionId = sid
                }
            }
            if !isSidechain, let parent = parentSessionId, raw.sessionId == parent { continue }
            guard raw.type == "assistant", let usage = raw.usage else { continue }

            let msgId = raw.messageId
            let isOrphan = msgId.map { !stopReasonIds.contains($0) } ?? true
            let isBillable = raw.stopReason != nil || isOrphan
            guard isBillable else { continue }

            if isOrphan, let mid = msgId, orphanChosen[mid] != raw.index { continue }
            if let mid = msgId, parentReplay.contains(mid) { continue }
            if let mid = msgId {
                guard !seenMsgIds.contains(mid) else { continue }
                seenMsgIds.insert(mid)
            }
            if let uuid = raw.uuid {
                guard !seenUUIDs.contains(uuid) else { continue }
                seenUUIDs.insert(uuid)
            }

            let model = raw.model ?? ""
            guard !model.isEmpty, model != "<synthetic>" else { continue }

            let tokens = tokens(from: usage)
            guard tokens.input + tokens.output + tokens.cacheRead + tokens.cacheWrite5m + tokens.cacheWrite1h > 0 else {
                continue
            }

            let isFast = raw.speed != nil && raw.speed != "standard"
            let multiplier = isFast ? 2.0 : 1.0
            let normalized = TokenPricing.normalize(model)
            let cost = TokenPricing.cost(model: normalized, usage: tokens, speedMultiplier: multiplier)
            let dayKey = raw.timestamp.flatMap(localDayKey) ?? lastDayKey ?? "1970-01-01"

            turns.append(BillableTurn(
                dayKey: dayKey,
                sessionId: raw.sessionId,
                model: normalized,
                cost: cost,
                tokens: tokens,
                entrypoint: raw.entrypoint
            ))
        }
        return turns
    }

    // MARK: Orphan selection (max cumulative usage per msg.id)

    private static func selectOrphanBillingIndices(
        _ records: [RawRecord],
        stopReasonIds: Set<String>
    ) -> [String: Int] {
        var chosen: [String: Int] = [:]
        var bestTotal: [String: Int] = [:]
        for raw in records {
            guard raw.type == "assistant",
                  let id = raw.messageId,
                  !stopReasonIds.contains(id),
                  let usage = raw.usage else { continue }
            let total = (usage["input_tokens"] as? Int ?? 0)
                + (usage["output_tokens"] as? Int ?? 0)
                + (usage["cache_read_input_tokens"] as? Int ?? 0)
                + (usage["cache_creation_input_tokens"] as? Int ?? 0)
            if let prev = bestTotal[id], total < prev { continue }
            bestTotal[id] = total
            chosen[id] = raw.index
        }
        return chosen
    }

    // MARK: Parsing helpers

    private static func parseRaw(_ obj: [String: Any], index: Int) -> RawRecord {
        let msg = obj["message"] as? [String: Any]
        let usage = msg?["usage"] as? [String: Any]
        let speed = (usage?["speed"] as? String)
            ?? (usage?["service_tier"] as? String) // legacy field name
        return RawRecord(
            index: index,
            type: obj["type"] as? String ?? "",
            uuid: obj["uuid"] as? String,
            sessionId: obj["sessionId"] as? String,
            timestamp: obj["timestamp"] as? String,
            entrypoint: obj["entrypoint"] as? String,
            isSidechain: obj["isSidechain"] as? Bool ?? false,
            messageId: msg?["id"] as? String,
            model: msg?["model"] as? String,
            stopReason: msg?["stop_reason"] as? String,
            usage: usage,
            speed: speed
        )
    }

    private static func tokens(from usage: [String: Any]) -> TokenUsage {
        let cache = usage["cache_creation"] as? [String: Any]
        let cacheCreate = usage["cache_creation_input_tokens"] as? Int ?? 0
        let breakdown5m = cache?["ephemeral_5m_input_tokens"] as? Int
        let breakdown1h = cache?["ephemeral_1h_input_tokens"] as? Int
        let (w5, w1h): (Int, Int)
        if breakdown5m != nil || breakdown1h != nil {
            w5 = breakdown5m ?? 0
            w1h = breakdown1h ?? 0
        } else {
            w5 = cacheCreate
            w1h = 0
        }
        return TokenUsage(
            input: usage["input_tokens"] as? Int ?? 0,
            output: usage["output_tokens"] as? Int ?? 0,
            cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
            cacheWrite5m: w5,
            cacheWrite1h: w1h
        )
    }

    private static func parseJSONObject(_ line: Data) -> [String: Any]? {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        return obj
    }

    private static func utf8Lines(in data: Data) -> [Data] {
        var lines: [Data] = []
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let slice = data[start..<end]
            if slice.count > 2 { lines.append(Data(slice)) }
            start = end < data.endIndex ? data.index(after: end) : data.endIndex
        }
        return lines
    }

    private static func localDayKey(_ ts: String) -> String? {
        LocalUsageScanner.parseISO8601(ts).map { LocalUsageScanner.dayKey($0) }
    }
}
