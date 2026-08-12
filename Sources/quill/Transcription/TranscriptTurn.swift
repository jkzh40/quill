import Foundation

/// A recognized speech segment after its track-relative timestamps have been
/// aligned onto the conversation clock and associated with a speaker.
struct SpeakerTranscriptSegment: Equatable, Sendable {
    let speaker: String
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// A human-readable conversational turn assembled from one or more precise
/// transcript segments. Canonical JSON retains the source segments; turns are
/// the shared presentation unit for canonical and live Markdown.
struct TranscriptTurn: Equatable, Sendable {
    let speaker: String
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// Incrementally groups chronological segments into conversational turns.
/// Sentence punctuation does not end a turn: a speaker change or a proven
/// silence long enough to represent yielding the floor does.
struct TranscriptTurnAssembler {
    static let silenceThreshold: TimeInterval = 2.0

    private var current: TranscriptTurn?

    static func turns(from segments: [SpeakerTranscriptSegment]) -> [TranscriptTurn] {
        var assembler = TranscriptTurnAssembler()
        var turns = assembler.append(segments)
        if let final = assembler.finish() { turns.append(final) }
        return turns
    }

    mutating func append(_ segments: [SpeakerTranscriptSegment]) -> [TranscriptTurn] {
        var completed: [TranscriptTurn] = []
        for segment in segments {
            completed += append(segment)
        }
        return completed
    }

    mutating func append(_ segment: SpeakerTranscriptSegment) -> [TranscriptTurn] {
        let text = Self.normalized(segment.text)
        guard text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else {
            return []
        }

        let start = max(0, segment.start)
        let next = TranscriptTurn(
            speaker: segment.speaker,
            start: start,
            end: max(start, segment.end),
            text: text
        )
        guard let open = current else {
            current = next
            return []
        }

        let gap = next.start - open.end
        if next.speaker == open.speaker, gap <= Self.silenceThreshold {
            current = TranscriptTurn(
                speaker: open.speaker,
                start: open.start,
                end: max(open.end, next.end),
                text: Self.join(open.text, next.text)
            )
            return []
        }

        current = next
        return [open]
    }

    /// Close the open turn only once every decoder has moved far enough past
    /// it that another segment within the turn's silence threshold cannot
    /// still arrive.
    mutating func advance(to watermark: TimeInterval) -> TranscriptTurn? {
        guard let open = current,
              watermark >= open.end + Self.silenceThreshold
        else { return nil }
        current = nil
        return open
    }

    mutating func finish() -> TranscriptTurn? {
        defer { current = nil }
        return current
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    /// Join separately decoded segments without exposing standalone punctuation
    /// tokens at their boundary. If the existing text already ends in a mark,
    /// a second leading mark is redundant; otherwise it belongs directly on
    /// the preceding word.
    private static func join(_ existing: String, _ incoming: String) -> String {
        let boundaryPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?"]
        let leading = incoming.prefix { boundaryPunctuation.contains($0) }
        guard !leading.isEmpty else { return "\(existing) \(incoming)" }

        let remainder = incoming.dropFirst(leading.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = existing.last, boundaryPunctuation.contains(last) {
            return remainder.isEmpty ? existing : "\(existing) \(remainder)"
        }
        return remainder.isEmpty
            ? "\(existing)\(leading)"
            : "\(existing)\(leading) \(remainder)"
    }
}

/// One consistent Markdown block for both transcript modes.
enum TranscriptTurnMarkdown {
    static func block(_ turn: TranscriptTurn) -> String {
        "### \(turn.speaker) · \(clock(turn.start))–\(clock(max(turn.start, turn.end)))"
            + "\n\n\(turn.text)"
    }

    private static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
