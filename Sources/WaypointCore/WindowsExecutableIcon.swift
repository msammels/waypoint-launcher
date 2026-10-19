import Foundation

/// Reads an executable's own icon without running Windows code or installing
/// another utility. All offsets are checked against the PE section and file.
public enum WindowsExecutableIcon {
    public static func data(at executable: URL) -> Data? {
        // Owned buffers stay valid if an update replaces/truncates the EXE or
        // an external volume disconnects. Never map a live installation file.
        guard let file = try? FileHandle(forReadingFrom: executable) else { return nil }
        defer { try? file.close() }
        guard let header = try? file.read(upToCount: 64 << 10) else { return nil }
        func read(_ offset: Int, _ count: Int) -> Int? {
            guard offset >= 0, offset <= header.count, count <= header.count - offset else { return nil }
            return (0..<count).reduce(0) { $0 | Int(header[offset + $1]) << ($1 * 8) }
        }
        guard read(0, 2) == 0x5a4d, let pe = read(0x3c, 4), read(pe, 4) == 0x4550,
              let count = read(pe + 6, 2), (1...96).contains(count), let optionalSize = read(pe + 20, 2) else { return nil }
        let optional = pe + 24, table = optional + optionalSize, end = table + count * 40
        let directories: Int
        switch read(optional, 2) {
        case 0x20b: directories = optional + 112
        case 0x10b: directories = optional + 96
        default: return nil
        }
        guard end <= header.count, directories + 24 <= table,
              let directoryCount = read(directories - 4, 4), directoryCount >= 3,
              let address = read(directories + 16, 4), address != 0,
              let size = read(directories + 20, 4), (16...(32 << 20)).contains(size) else { return nil }
        for index in 0..<count {
            let section = table + index * 40
            guard let start = read(section + 12, 4), let length = read(section + 16, 4),
                  let raw = read(section + 20, 4), address >= start else { continue }
            let relative = address - start
            guard relative <= length, size <= length - relative else { continue }
            do {
                try file.seek(toOffset: UInt64(raw + relative))
                guard let resources = try file.read(upToCount: size), resources.count == size else { return nil }
                // Compact the PE to its headers and declared resource region.
                // Payloads outside that region fall back to the generic icon.
                var compact = Data(header.prefix(end))
                func put(_ offset: Int, _ value: Int) {
                    for i in 0..<4 { compact[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
                }
                for other in 0..<count {
                    put(table + other * 40 + 16, 0); put(table + other * 40 + 20, 0)
                }
                put(section + 12, address); put(section + 16, size); put(section + 20, end)
                compact.append(resources)
                return data(in: compact)
            } catch { return nil }
        }
        return nil
    }

    static func data(in bytes: Data) -> Data? {
        struct Section { let address: Int; let size: Int; let offset: Int }
        func fits(_ offset: Int, _ count: Int, in limit: Int) -> Bool {
            offset >= 0 && count >= 0 && offset <= limit && count <= limit - offset
        }
        func u16(_ offset: Int) -> Int? {
            guard fits(offset, 2, in: bytes.count) else { return nil }
            return Int(bytes[bytes.startIndex + offset]) | Int(bytes[bytes.startIndex + offset + 1]) << 8
        }
        func u32(_ offset: Int) -> Int? {
            guard fits(offset, 4, in: bytes.count) else { return nil }
            return (0..<4).reduce(0) { $0 | Int(bytes[bytes.startIndex + offset + $1]) << ($1 * 8) }
        }
        guard u16(0) == 0x5a4d, let pe = u32(0x3c), u32(pe) == 0x00004550,
              let count = u16(pe + 6), (1...96).contains(count), let optionalSize = u16(pe + 20) else { return nil }
        let optional = pe + 24
        let directories: Int
        switch u16(optional) {
        case 0x20b: directories = optional + 112
        case 0x10b: directories = optional + 96
        default: return nil
        }
        guard fits(optional, optionalSize, in: bytes.count), directories + 24 <= optional + optionalSize,
              let directoryCount = u32(directories - 4), directoryCount >= 3,
              let resourceAddress = u32(directories + 16), resourceAddress != 0,
              let resourceSize = u32(directories + 20), (16...(32 << 20)).contains(resourceSize) else { return nil }
        let table = optional + optionalSize
        guard fits(table, count * 40, in: bytes.count) else { return nil }
        var sections: [Section] = []
        for index in 0..<count {
            let entry = table + index * 40
            guard let address = u32(entry + 12), let size = u32(entry + 16), let offset = u32(entry + 20),
                  fits(offset, size, in: bytes.count) else { return nil }
            sections.append(Section(address: address, size: size, offset: offset))
        }
        func fileOffset(_ address: Int, size: Int) -> Int? {
            for section in sections where address >= section.address {
                let relative = address - section.address
                if fits(relative, size, in: section.size) { return section.offset + relative }
            }
            return nil
        }
        guard let root = fileOffset(resourceAddress, size: resourceSize) else { return nil }
        struct Entry { let id: Int?; let offset: Int; let directory: Bool }
        func entries(_ relative: Int) -> [Entry]? {
            guard fits(relative, 16, in: resourceSize), let named = u16(root + relative + 12),
                  let numbered = u16(root + relative + 14), named + numbered <= 4096,
                  fits(relative + 16, (named + numbered) * 8, in: resourceSize) else { return nil }
            return (0..<(named + numbered)).compactMap { index in
                let position = root + relative + 16 + index * 8
                guard let name = u32(position), let target = u32(position + 4) else { return nil }
                return Entry(id: name & 0x80000000 == 0 ? name : nil,
                             offset: target & 0x7fffffff, directory: target & 0x80000000 != 0)
            }
        }
        guard let types = entries(0) else { return nil }
        func resources(_ type: Int) -> [Entry]? {
            guard let entry = types.first(where: { $0.id == type && $0.directory }) else { return nil }
            return entries(entry.offset)
        }
        func contents(_ entry: Entry) -> Data? {
            guard entry.directory, let languages = entries(entry.offset),
                  let leaf = languages.first(where: { $0.id == 1033 && !$0.directory }) ?? languages.first(where: { !$0.directory }),
                  fits(leaf.offset, 16, in: resourceSize),
                  let address = u32(root + leaf.offset), let size = u32(root + leaf.offset + 4),
                  (1...(4 << 20)).contains(size), let offset = fileOffset(address, size: size) else { return nil }
            return bytes.subdata(in: (bytes.startIndex + offset)..<(bytes.startIndex + offset + size))
        }
        guard let groups = resources(14), let groupEntry = groups.first,
              let group = contents(groupEntry), group.count >= 6 else { return nil }
        func group16(_ offset: Int) -> Int { Int(group[offset]) | Int(group[offset + 1]) << 8 }
        let icons = group16(4)
        guard group16(0) == 0, group16(2) == 1, (1...64).contains(icons),
              fits(6, icons * 14, in: group.count), let images = resources(3) else { return nil }
        var payloads: [(Data, Data)] = []
        var total = 6 + icons * 16
        for index in 0..<icons {
            let offset = 6 + index * 14, id = group16(offset + 12)
            guard let entry = images.first(where: { $0.id == id }), let image = contents(entry),
                  total + image.count <= 16 << 20 else { return nil }
            payloads.append((group.subdata(in: offset..<(offset + 8)), image))
            total += image.count
        }
        var result = group.prefix(6)
        func append32(_ value: Int) {
            for shift in stride(from: 0, to: 32, by: 8) { result.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        var offset = 6 + icons * 16
        for (description, image) in payloads {
            result.append(description); append32(image.count); append32(offset)
            offset += image.count
        }
        for (_, image) in payloads { result.append(image) }
        return Data(result)
    }
}
