import Compression
import Foundation

/// 最小的 ZIP 写入器：文件名标记为 UTF-8（中文文件名在 Windows 上解压也不乱码），内容用 DEFLATE 压缩。
/// 系统自带的 ditto / zip 都不写 UTF-8 标记。
nonisolated struct ZipWriter {
    private var data = Data()
    private var central = Data()
    private var count: UInt16 = 0

    /// 打包一个文件夹：压缩包里的路径以文件夹自身的名字开头
    static func zip(folder: URL) throws -> Data {
        var writer = ZipWriter()
        let base = folder.deletingLastPathComponent().standardizedFileURL.path
        let root = folder.standardizedFileURL
        var entries = [root]
        if let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            entries += items.compactMap { $0 as? URL }.sorted { $0.path < $1.path }
        }
        for url in entries {
            let path = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory { writer.addDirectory(path) } else { writer.addFile(path, contents: try Data(contentsOf: url)) }
        }
        return writer.finish()
    }

    mutating func addDirectory(_ path: String) {
        add(path.hasSuffix("/") ? path : path + "/", contents: Data(), isDirectory: true)
    }

    mutating func addFile(_ path: String, contents: Data) {
        add(path, contents: contents, isDirectory: false)
    }

    private mutating func add(_ path: String, contents: Data, isDirectory: Bool) {
        let name = Data(path.utf8)
        let crc = Self.crc32(contents)
        let deflated = isDirectory ? nil : Self.deflate(contents)
        let method: UInt16 = deflated == nil ? 0 : 8
        let body = deflated ?? contents
        let (time, date) = Self.dosDateTime(Date())
        let offset = UInt32(data.count)
        let flags: UInt16 = 0x0800   // 文件名是 UTF-8

        var local = Data()
        local.append32(0x04034B50); local.append16(20); local.append16(flags); local.append16(method)
        local.append16(time); local.append16(date); local.append32(crc)
        local.append32(UInt32(body.count)); local.append32(UInt32(contents.count))
        local.append16(UInt16(name.count)); local.append16(0)
        data.append(local); data.append(name); data.append(body)

        let mode: UInt32 = isDirectory ? (0o040755 << 16) | 0x10 : 0o100644 << 16
        var entry = Data()
        entry.append32(0x02014B50); entry.append16(0x0314); entry.append16(20); entry.append16(flags)
        entry.append16(method); entry.append16(time); entry.append16(date); entry.append32(crc)
        entry.append32(UInt32(body.count)); entry.append32(UInt32(contents.count))
        entry.append16(UInt16(name.count)); entry.append16(0); entry.append16(0); entry.append16(0); entry.append16(0)
        entry.append32(mode); entry.append32(offset)
        central.append(entry); central.append(name)
        count += 1
    }

    mutating func finish() -> Data {
        var out = data
        let offset = UInt32(out.count)
        out.append(central)
        var end = Data()
        end.append32(0x06054B50); end.append16(0); end.append16(0); end.append16(count); end.append16(count)
        end.append32(UInt32(central.count)); end.append32(offset); end.append16(0)
        out.append(end)
        return out
    }

    /// 原始 DEFLATE（Compression 框架的 ZLIB 就是 RFC 1951 原始流）；压不小时返回 nil，按存储方式写入
    private static func deflate(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        let capacity = input.count + input.count / 8 + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written < input.count else { return nil }
        return output.prefix(written)
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16(max((c.year ?? 1980) - 1980, 0) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }
}

private extension Data {
    nonisolated mutating func append16(_ v: UInt16) { append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
    nonisolated mutating func append32(_ v: UInt32) {
        append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }
}
