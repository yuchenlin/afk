import Foundation

/// Builds the live transcript from streaming `transcript.partial` events.
/// Utterance-final text replaces that utterance's chunk finals; interim text is provisional.
public struct TranscriptAssembler: Sendable, Equatable {
    private var utterances: [String] = []
    private var chunks: [String] = []
    private var interim = ""

    public init() {}

    public mutating func apply(text: String, isFinal: Bool, speechFinal: Bool) {
        if speechFinal {
            utterances.append(text)
            chunks.removeAll()
            interim = ""
        } else if isFinal {
            chunks.append(text)
            interim = ""
        } else {
            interim = text
        }
    }

    public var text: String {
        Self.join(utterances + chunks + [interim])
    }

    /// Joins segments with a space only between Latin-script text, never next to CJK.
    public static func join(_ parts: [String]) -> String {
        var result = ""
        for part in parts {
            let piece = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if let last = result.unicodeScalars.last, let first = piece.unicodeScalars.first,
               !isCJK(last), !isCJK(first) {
                result += " "
            }
            result += piece
        }
        return result
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F, // CJK punctuation
             0x3040...0x30FF, // kana
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, // ideographs
             0xAC00...0xD7AF, // hangul
             0xFF00...0xFFEF: // full-width forms
            return true
        default:
            return false
        }
    }
}
