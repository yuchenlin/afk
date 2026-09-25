import Foundation

public enum TranscriptEvent: Sendable, Equatable {
    case partial(String)
    case final(String)
    case error(String)
}

public struct PolishRequest: Sendable, Equatable {
    public var raw: String
    public var lexicon: [String]

    public init(raw: String, lexicon: [String] = []) {
        self.raw = raw
        self.lexicon = lexicon
    }
}

public enum AFKError: Error, Sendable, Equatable {
    case notConfigured(String)
    case permissionDenied(String)
    case stt(String)
    case insertFailed(String)
}
