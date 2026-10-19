import Foundation
import Testing
@testable import WaypointCore

@Test func overwatchFirstLaunchUsesBorderlessRetinaAndKeepsSavedPreferences() throws {
    let fm = FileManager.default, documents = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: documents) }
    let display = WindowsDisplay(width: 3456, height: 2234, framesPerSecond: 120)
    let settings = documents.appendingPathComponent("Overwatch/Settings/Settings_v0.ini")
    try OverwatchSettings.seed(in: documents, display: display)
    let defaults = try String(contentsOf: settings, encoding: .utf8)
    #expect(defaults.contains("WindowMode = \"1\"\n"))
    #expect(defaults.contains("WindowedFullscreen = \"1\"\n"))
    #expect(defaults.contains("FullScreenWidth = \"3456\"\n"))
    #expect(defaults.contains("WindowedHeight = \"2234\"\n"))
    let custom = Data("[Render.13]\r\nWindowMode = \"2\"\r\nTextureDetail = \"3\"\r\n".utf8)
    try custom.write(to: settings)
    try OverwatchSettings.seed(in: documents, display: WindowsDisplay(width: 1920, height: 1080, framesPerSecond: 60))
    #expect(try Data(contentsOf: settings) == custom)
}

@Test func overwatchBorderlessDefaultsDoNotInventUnknownDisplayDimensions() throws {
    let fm = FileManager.default, documents = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: documents) }
    try OverwatchSettings.seed(in: documents, display: nil)
    let defaults = try String(contentsOf: documents.appendingPathComponent("Overwatch/Settings/Settings_v0.ini"), encoding: .utf8)
    #expect(defaults.contains("WindowedFullscreen = \"1\""))
    #expect(!defaults.contains("Width"))
    #expect(!defaults.contains("Height"))
}

@Test func overwatchDefaultsRefuseToWriteThroughHostFolderLinks() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let documents = root.appendingPathComponent("Documents"), outside = root.appendingPathComponent("host-settings")
    try fm.createDirectory(at: documents, withIntermediateDirectories: true)
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: documents.appendingPathComponent("Overwatch"), withDestinationURL: outside)
    #expect(throws: WindowsRuntime.Failure.invalidRuntime) { try OverwatchSettings.seed(in: documents, display: nil) }
    #expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
}
