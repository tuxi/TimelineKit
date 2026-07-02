import Foundation

/// v4 (text-typography-spec §3): smart line-breaking for subtitle text.
///
/// Three rules applied per line:
/// 1. CJK characters break individually; English words stay intact.
/// 2. Emoji grapheme clusters are never split.
/// 3. Chinese punctuation prohibition — certain marks cannot start or end a line.
public enum TextLineBreaker {

    /// Characters forbidden at the start of a line (closing punctuation, etc.).
    private static let lineStartForbidden: Set<Character> = [
        "\u{FF0C}", // ，
        "\u{3002}", // 。
        "\u{FF01}", // ！
        "\u{FF1F}", // ？
        "\u{FF1B}", // ；
        "\u{FF1A}", // ：
        "\u{3001}", // 、
        "\u{FF09}", // ）
        "\u{300D}", // 」
        "\u{300F}", // 』
        "\u{3011}", // 】
        "\u{300B}", // 》
        "\u{201D}", // "
        "\u{2019}", // '
    ]

    /// Characters forbidden at the end of a line (opening punctuation, etc.).
    private static let lineEndForbidden: Set<Character> = [
        "\u{FF08}", // （
        "\u{300C}", // 「
        "\u{300E}", // 『
        "\u{3010}", // 【
        "\u{300A}", // 《
        "\u{201C}", // "
        "\u{2018}", // '
    ]

    // MARK: - Public API

    /// Insert soft `\n` based on maxCharsPerLine + line-break rules.
    /// - Parameter text: original subtitle text.
    /// - Parameter maxCharsPerLine: max grapheme clusters per visual line.
    /// - Returns: text with `\n` inserted where needed; preserves original `\n`.
    public static func wrap(_ text: String, maxCharsPerLine: Int) -> String {
        guard maxCharsPerLine > 0 else { return text }

        // Split by existing hard breaks first, so user-intentional breaks stay.
        let paragraphs = text.components(separatedBy: "\n")
        var result: [String] = []

        for paragraph in paragraphs {
            let lines = breakParagraph(paragraph, maxCharsPerLine: maxCharsPerLine)
            result.append(lines.joined(separator: "\n"))
        }

        return result.joined(separator: "\n")
    }

    // MARK: - Internals

    private static func breakParagraph(_ text: String, maxCharsPerLine: Int) -> [String] {
        guard !text.isEmpty else { return [""] }
        let chars = Array(text)
        var lines: [String] = []
        var start = 0

        while start < chars.count {
            let remaining = chars.count - start
            guard remaining > maxCharsPerLine else {
                lines.append(String(chars[start...]))
                break
            }

            // Find the best break position within [1, maxCharsPerLine] measured
            // backward from the max position.
            var best = start + maxCharsPerLine - 1

            // Walk backward from the initial cut position looking for a safe spot.
            while best > start {
                if isSafeBreak(before: best, in: chars, start: start) {
                    break
                }
                best -= 1
            }

            // If we walked all the way back to start without finding a safe spot,
            // force-break at maxCharsPerLine (should be rare — e.g. very long word).
            if best == start {
                best = start + maxCharsPerLine - 1
            }

            // Apply punctuation prohibition: pull trailing forbidden-start chars
            // back to the current line, and push leading forbidden-end chars to
            // the next line.
            let adjusted = applyPunctuationProhibition(
                breakAfter: best, chars: chars, start: start
            )

            lines.append(String(chars[start...adjusted]))
            start = adjusted + 1
        }

        return lines
    }

    /// Returns true when it's safe to break *after* position `pos` (i.e., the
    /// character at `pos` can end the current line, and the character at
    /// `pos+1` can start the next line).
    private static func isSafeBreak(before pos: Int, in chars: [Character], start: Int) -> Bool {
        let cur = chars[pos]
        let next = pos + 1 < chars.count ? chars[pos + 1] : nil

        // Rule 1: never break inside an English word. An English word is a
        // sequence of ASCII letters. Break is safe only when current char is
        // NOT an ASCII letter, OR the next char is NOT an ASCII letter.
        if cur.isASCIILetter, let n = next, n.isASCIILetter {
            return false
        }

        // Rule 2: never break inside a digit sequence.
        if cur.isNumber, let n = next, n.isNumber {
            return false
        }

        // Rule 3: prefer breaking at script boundary (CJK ↔ Latin boundary is
        // an ideal spot).
        // Already covered by rules above — ASCII letter + non-ASCII = safe.

        return true
    }

    /// Walk the break point to satisfy punctuation prohibition rules:
    /// - Characters in `lineStartForbidden` must not appear at line start.
    /// - Characters in `lineEndForbidden` must not appear at line end.
    private static func applyPunctuationProhibition(
        breakAfter: Int, chars: [Character], start: Int
    ) -> Int {
        var pos = breakAfter

        // Pull back: if the char right after the break is forbidden at line
        // start, move it to the current line.
        let nextIdx = pos + 1
        if nextIdx < chars.count, lineStartForbidden.contains(chars[nextIdx]) {
            // Extend current line to include this forbidden-start char.
            pos = nextIdx
            // Continue pulling more forbidden-start chars.
            var i = pos + 1
            while i < chars.count, lineStartForbidden.contains(chars[i]) {
                pos = i
                i += 1
            }
        }

        // Push forward: if the char at the break is forbidden at line end,
        // move it to the next line.
        while pos > start, lineEndForbidden.contains(chars[pos]) {
            pos -= 1
        }

        // Safety: ensure we don't break before start.
        return max(pos, start)
    }
}

private extension Character {
    var isASCIILetter: Bool {
        guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
        return (scalar.value >= 0x41 && scalar.value <= 0x5A)  // A-Z
            || (scalar.value >= 0x61 && scalar.value <= 0x7A)  // a-z
    }
}
