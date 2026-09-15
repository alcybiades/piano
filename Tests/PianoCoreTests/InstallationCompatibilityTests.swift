import XCTest
@testable import PianoCore

final class InstallationCompatibilityTests: XCTestCase {
    func testKeepsExistingWorkspaceWithoutMovingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PianoLocationTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("Piano/Workspace", isDirectory: true)
        XCTAssertEqual(InstallationCompatibility.workspaceRoot(in: root), current)
        let previous = root.appendingPathComponent("Cadenza/Workspace", isDirectory: true)
        let workspace = try Workspace(root: previous)
        try workspace.save(.welcome)
        XCTAssertEqual(InstallationCompatibility.workspaceRoot(in: root), previous)
        XCTAssertEqual(try workspace.scores().count, 1)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        XCTAssertEqual(InstallationCompatibility.workspaceRoot(in: root), current)
        XCTAssertEqual(try workspace.scores().count, 1)
    }

    func testPreferencesImportOnlyOnceAndPreserveCurrentValues() {
        let suite = "PianoPreferencesTest-\(UUID())", legacy = "PianoPreviousPreferencesTest-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); defaults.removePersistentDomain(forName: legacy) }
        defaults.setPersistentDomain(["model": "previous", "autoplay": false, "chatOverlayFraction": 0.6, "unrelated": "private"], forName: legacy)
        defaults.set("current", forKey: "model")
        InstallationCompatibility.importPreferences(into: defaults, legacyDomain: legacy)
        XCTAssertEqual(defaults.string(forKey: "model"), "current")
        XCTAssertFalse(defaults.bool(forKey: "autoplay"))
        XCTAssertEqual(defaults.double(forKey: "chatOverlayFraction"), 0.6)
        XCTAssertNil(defaults.object(forKey: "unrelated"))
        defaults.removeObject(forKey: "autoplay")
        InstallationCompatibility.importPreferences(into: defaults, legacyDomain: legacy)
        XCTAssertNil(defaults.object(forKey: "autoplay"))
    }
}
