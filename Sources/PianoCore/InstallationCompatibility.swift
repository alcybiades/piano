import Foundation

/// Legacy identifiers are used only to preserve an existing installation's data.
public enum InstallationCompatibility {
    public static func workspaceRoot(in applicationSupport: URL) -> URL {
        let current = applicationSupport.appendingPathComponent("Piano/Workspace", isDirectory: true)
        let previous = applicationSupport.appendingPathComponent("Cadenza/Workspace", isDirectory: true)
        if FileManager.default.fileExists(atPath: current.path) { return current }
        if FileManager.default.fileExists(atPath: previous.path) { return previous }
        return current
    }

    public static func importPreferences(into defaults: UserDefaults, legacyDomain: String = "studio.cadenza.piano") {
        let marker = "importedPreviousInstallationPreferences"
        guard !defaults.bool(forKey: marker) else { return }
        let previous = defaults.persistentDomain(forName: legacyDomain) ?? [:]
        // Only application-owned values: never copy credentials or system preference keys.
        for key in ["model", "codexPath", "autoplay", "chatOverlayFraction"] {
            if defaults.object(forKey: key) == nil, let value = previous[key] { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: marker)
    }
}
