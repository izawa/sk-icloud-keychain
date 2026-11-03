import Foundation

/// Text for the Touch ID prompt. macOS shows it after its own localized
/// "<app> is trying to …", so it follows the user's preferred language.
enum PromptText {
    enum Action {
        case create, sign, delete
    }

    static func reason(_ action: Action, application: String,
                       languages: [String] = Locale.preferredLanguages) -> String {
        if languages.first?.hasPrefix("ja") == true {
            switch action {
            case .create: return "SSH 鍵「\(application)」を作成"
            case .sign: return "SSH 鍵「\(application)」で署名"
            case .delete: return "SSH 鍵「\(application)」を削除"
            }
        }
        switch action {
        case .create: return "create an SSH key for \(application)"
        case .sign: return "sign in with the SSH key for \(application)"
        case .delete: return "delete the SSH key for \(application)"
        }
    }
}
