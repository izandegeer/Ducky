import Foundation

class DuckySettings {
    static let shared = DuckySettings()

    var showNotch: Bool {
        get {
            if UserDefaults.standard.object(forKey: "showNotch") == nil { return true }
            return UserDefaults.standard.bool(forKey: "showNotch")
        }
        set { UserDefaults.standard.set(newValue, forKey: "showNotch") }
    }

    var soundEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "soundEnabled") == nil { return true }
            return UserDefaults.standard.bool(forKey: "soundEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "soundEnabled") }
    }
}
