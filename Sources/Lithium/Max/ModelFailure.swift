import FoundationModels

/// What a Foundation Models error means for the caller. macOS 27 throws `LanguageModelError`;
/// macOS 26 throws `LanguageModelSession.GenerationError`.
@available(macOS 26.0, *)
enum ModelFailure {
    /// Refused for this input (guardrails, refusal, unsupported language): asking again won't help.
    case declined
    case tooLong
    /// Busy, rate limited, cancelled, timed out: fine to try again later.
    case transient

    init(_ error: any Error) {
        if #available(macOS 27.0, *), let error = error as? LanguageModelError {
            switch error {
            case .guardrailViolation, .refusal, .unsupportedLanguageOrLocale: self = .declined
            case .contextSizeExceeded: self = .tooLong
            default: self = .transient
            }
        } else if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal, .unsupportedLanguageOrLocale: self = .declined
            case .exceededContextWindowSize: self = .tooLong
            default: self = .transient
            }
        } else {
            self = .transient
        }
    }
}
