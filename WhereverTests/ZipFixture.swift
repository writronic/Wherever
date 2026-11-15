import Foundation

enum ZipFixture {
    struct Entry {
        let name: String
        let bytes: Data

        init(_ name: String, _ bytes: Data = Data()) {
            self.name = name
            self.bytes = bytes
        }
    }

    static func write(_ entries: [Entry], to url: URL) throws {
        var file = Data()
        var directory = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let size = UInt32(entry.bytes.count)
            let offset = UInt32(file.count)
            let crc = checksum(entry.bytes)
            file.integer(UInt32(0x04034b50))
            file.integer(UInt16(20))
            file.integer(UInt16(0x0800))
            file.integer(UInt16(0))
            file.integer(UInt16(0))
            file.integer(UInt16(33))
            file.integer(crc)
            file.integer(size)
            file.integer(size)
            file.integer(UInt16(name.count))
            file.integer(UInt16(0))
            file.append(name)
            file.append(entry.bytes)

            directory.integer(UInt32(0x02014b50))
            directory.integer(UInt16(0x0314))
            directory.integer(UInt16(20))
            directory.integer(UInt16(0x0800))
            directory.integer(UInt16(0))
            directory.integer(UInt16(0))
            directory.integer(UInt16(33))
            directory.integer(crc)
            directory.integer(size)
            directory.integer(size)
            directory.integer(UInt16(name.count))
            directory.integer(UInt16(0))
            directory.integer(UInt16(0))
            directory.integer(UInt16(0))
            directory.integer(UInt16(0))
            directory.integer(UInt32(entry.name.hasSuffix("/") ? 0o40755 : 0o100644) << 16)
            directory.integer(offset)
            directory.append(name)
        }
        let offset = UInt32(file.count)
        let size = UInt32(directory.count)
        file.append(directory)
        if entries.count >= Int(UInt16.max) {
            let end = UInt64(file.count)
            file.integer(UInt32(0x06064b50))
            file.integer(UInt64(44))
            file.integer(UInt16(45))
            file.integer(UInt16(45))
            file.integer(UInt32(0))
            file.integer(UInt32(0))
            file.integer(UInt64(entries.count))
            file.integer(UInt64(entries.count))
            file.integer(UInt64(size))
            file.integer(UInt64(offset))
            file.integer(UInt32(0x07064b50))
            file.integer(UInt32(0))
            file.integer(end)
            file.integer(UInt32(1))
        }
        file.integer(UInt32(0x06054b50))
        file.integer(UInt16(0))
        file.integer(UInt16(0))
        file.integer(UInt16(clamping: entries.count))
        file.integer(UInt16(clamping: entries.count))
        file.integer(size)
        file.integer(offset)
        file.integer(UInt16(0))
        try file.write(to: url)
    }

    private static func checksum(_ bytes: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320)
            }
        }
        return ~crc
    }
}

private extension Data {
    mutating func integer<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
