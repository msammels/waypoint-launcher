import Foundation
import Testing
@testable import WaypointCore

private func iconPE() -> Data {
    var data = Data(repeating: 0, count: 0x400)
    func put(_ offset: Int, _ value: Int, bytes: Int = 4) {
        for i in 0..<bytes { data[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }
    put(0, 0x5a4d, bytes: 2); put(0x3c, 0x80); put(0x80, 0x4550)
    put(0x86, 1, bytes: 2); put(0x94, 0xf0, bytes: 2); put(0x98, 0x20b, bytes: 2)
    put(0x104, 16); put(0x118, 0x1000); put(0x11c, 0x200)
    put(0x194, 0x1000); put(0x198, 0x200); put(0x19c, 0x200)
    // Root: RT_ICON and RT_GROUP_ICON; each contains one numeric id and language.
    put(0x20e, 2, bytes: 2)
    put(0x210, 3); put(0x214, 0x80000030)
    put(0x218, 14); put(0x21c, 0x80000060)
    for (directory, id, target) in [(0x230, 7, 0x90), (0x260, 1, 0xb0)] {
        put(directory + 14, 1, bytes: 2)
        put(directory + 16, id); put(directory + 20, 0x80000000 | target)
    }
    for (directory, target) in [(0x290, 0xd0), (0x2b0, 0xe0)] {
        put(directory + 14, 1, bytes: 2)
        put(directory + 16, 1033); put(directory + 20, target)
    }
    put(0x2d0, 0x1100); put(0x2d4, 4)
    put(0x2e0, 0x1180); put(0x2e4, 20)
    data.replaceSubrange(0x300..<0x304, with: [1, 2, 3, 4])
    put(0x382, 1, bytes: 2); put(0x384, 1, bytes: 2)
    data[0x386] = 16; data[0x387] = 16
    put(0x38a, 1, bytes: 2); put(0x38c, 32, bytes: 2)
    put(0x38e, 4); put(0x392, 7, bytes: 2)
    return data
}

@Test func windowsExecutableIconRebuildsICOAndAcceptsDataSlices() throws {
    let pe = iconPE()
    let ico = try #require(WindowsExecutableIcon.data(in: pe))
    #expect(ico.count == 26)
    #expect(Array(ico.prefix(6)) == [0, 0, 1, 0, 1, 0])
    #expect(Array(ico[14..<22]) == [4, 0, 0, 0, 22, 0, 0, 0])
    #expect(Array(ico.suffix(4)) == [1, 2, 3, 4])
    let padded = Data([0xff]) + pe
    #expect(WindowsExecutableIcon.data(in: padded.dropFirst()) == ico)
}

@Test func windowsExecutableIconRejectsTruncationAndInvalidResourceReferences() {
    let original = iconPE()
    for size in stride(from: 0, to: original.count, by: 7) {
        #expect(WindowsExecutableIcon.data(in: Data(original.prefix(size))) == nil)
    }
    for (offset, bytes) in [
        (0x19c, [UInt8](repeating: 0xff, count: 4)), // Section outside file.
        (0x2d0, [0xff, 0xff, 0xff, 0x7f]),          // Icon RVA outside section.
        (0x384, [65, 0]),                           // Excess group entries.
        (0x2a4, [0, 0, 0, 0x80]),                 // Resource cycle instead of a leaf.
    ] {
        var broken = original
        broken.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        #expect(WindowsExecutableIcon.data(in: broken) == nil)
    }
}

@Test func windowsExecutableIconReadsOnlyOwnedBuffersFromLiveFiles() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".exe")
    defer { try? FileManager.default.removeItem(at: file) }
    let pe = iconPE()
    try pe.write(to: file)
    #expect(WindowsExecutableIcon.data(at: file) == WindowsExecutableIcon.data(in: pe))
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 32)
    try handle.close()
    #expect(WindowsExecutableIcon.data(at: file) == nil)
}
