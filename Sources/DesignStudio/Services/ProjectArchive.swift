import Compression
import Foundation
import UniformTypeIdentifiers

/// A versioned ZIP with one JSON member. Import reads that member in memory.
nonisolated struct ProjectArchive: Codable, Sendable {
    static let filenameExtension = "designstudio"
    private static let formatID = "app.designstudio.mac.project"
    static let contentType = UTType(exportedAs: formatID)
    private static let currentVersion = 1
    private static let memberName = "project.json"
    private static let member = Data(memberName.utf8)
    private static let maximumSize = 256 * 1024 * 1024

    private let format: String
    private let version: Int
    let project: Project
    let designSystem: DesignSystem?

    init(project: Project, designSystem: DesignSystem?, includingHistory: Bool,
         canvasIDs: Set<UUID>? = nil, includingComments: Bool? = nil) throws {
        var copy = project
        let document = project.workingDocument
        let pages = canvasIDs.map { ids in document.pages.filter { ids.contains($0.id) } } ?? document.pages
        if let canvasIDs {
            guard !pages.isEmpty, Set(pages.map(\.id)) == canvasIDs else {
                throw ArchiveError.invalidSelection
            }
        }
        copy.name = project.displayName
        copy.titleNeedsSummary = false
        copy.document = document.selectingPages(pages)
        copy.designSystemID = designSystem?.id
        copy.providerID = nil
        copy.model = nil
        copy.effort = nil
        let partial = pages.count != document.pages.count
        if !includingHistory {
            copy.messages = []
        } else if partial {
            copy.messages = Self.canvasConversation(project, document: document, selectedPages: Set(pages.map(\.id)))
        }
        // Version snapshots contain all canvases, even if the turn only edited one.
        if !includingHistory || partial {
            copy.versions = []
            copy.currentVersionID = nil
        }
        if !(includingComments ?? (includingHistory && !partial)) {
            copy.comments = []
            if includingComments == false || partial {
                for index in copy.messages.indices { copy.messages[index].comments = [] }
            }
        } else if partial {
            let selectedBoards = Set(pages.flatMap(\.artboards).map(\.id))
            let byName = Dictionary(grouping: document.allArtboards, by: \.name)
            copy.comments = copy.comments.filter { comment in
                if let id = comment.artboardID { return selectedBoards.contains(id) }
                guard let name = comment.artboardName, let matches = byName[name], matches.count == 1 else { return false }
                return selectedBoards.contains(matches[0].id)
            }
        }
        Self.clearAttachmentPaths(in: &copy)
        self.format = Self.formatID
        self.version = Self.currentVersion
        self.project = copy
        self.designSystem = designSystem
    }

    private static func canvasConversation(_ project: Project, document: DesignDocument,
                                           selectedPages: Set<UUID>) -> [ChatMessage] {
        var pagesByBoard: [UUID: Set<UUID>] = [:]
        var pagesByName: [String: Set<UUID>] = [:]
        for snapshot in [document] + project.versions.compactMap(\.document) {
            for page in snapshot.pages {
                for board in page.artboards {
                    pagesByBoard[board.id, default: []].insert(page.id)
                    pagesByName[board.name, default: []].insert(page.id)
                }
            }
        }
        var conversation: [ChatMessage] = []
        for (user, reply) in zip(project.messages, project.messages.dropFirst()) {
            guard user.role == .user, reply.role == .assistant, reply.generationInProgress != true else { continue }
            let comments = user.comments + reply.comments
            let boardIDs = (user.scopeIDs ?? []).union(reply.scopeIDs ?? [])
                .union([user.target?.artboardID, reply.target?.artboardID].compactMap { $0 })
                .union(comments.compactMap(\.artboardID))
            var evidence = [user.requestPageID, reply.requestPageID].compactMap { $0 }.map { Set([$0]) }
            evidence += boardIDs.map { pagesByBoard[$0] ?? [] }
            evidence += comments.filter { $0.artboardID == nil }.map {
                $0.artboardName.flatMap { pagesByName[$0] } ?? []
            }
            guard let first = evidence.first else { continue }
            let matches = evidence.dropFirst().reduce(first) { $0.intersection($1) }
            guard matches.count == 1, let pageID = matches.first, selectedPages.contains(pageID) else { continue }

            var request = user
            request.requestPageID = pageID
            request.versionID = nil
            request.recovery = nil
            var response = reply
            response.requestPageID = pageID
            response.versionID = nil
            response.recovery = nil
            response.thinking = nil
            response.text = HTMLExtractor.conversationalText(reply.text)
            if response.text.trimmed.isEmpty, !reply.text.trimmed.isEmpty { response.text = "已生成画板。" }
            conversation += [request, response]
        }
        return conversation
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(self)
        guard payload.count <= Self.maximumSize else { throw ArchiveError.tooLarge }
        var writer = ZipWriter()
        writer.addFile(Self.memberName, contents: payload)
        try writer.finish().write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize else { throw ArchiveError.invalid }
        guard size <= maximumSize + 1024 else { throw ArchiveError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumSize + 1024 else { throw ArchiveError.tooLarge }
        let payload = try readPayload(data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let header = try? decoder.decode(Manifest.self, from: payload), header.format == formatID else {
            throw ArchiveError.invalid
        }
        guard header.version == currentVersion else { throw ArchiveError.unsupportedVersion(header.version) }
        guard let archive = try? decoder.decode(Self.self, from: payload),
              isValid(archive.project),
              archive.designSystem.map(isValid) ?? true else {
            throw ArchiveError.invalid
        }
        return archive
    }

    /// Import always creates a copy. Keep nested IDs so history links resolve inside the copy.
    func importedCopy(existingDesignSystems: [DesignSystem]) -> (project: Project, newDesignSystem: DesignSystem?) {
        var copy = project
        copy.id = UUID()
        copy.createdAt = .now
        copy.updatedAt = .now
        copy.providerID = nil
        copy.model = nil
        copy.effort = nil
        copy.designSystemID = nil
        Self.clearAttachmentPaths(in: &copy)
        guard var system = designSystem else { return (copy, nil) }
        if let existing = existingDesignSystems.first(where: { $0.id == system.id }) {
            if existing == system {
                copy.designSystemID = existing.id
                return (copy, nil)
            }
            system.id = UUID()
        }
        copy.designSystemID = system.id
        return (copy, system)
    }

    private struct Manifest: Decodable {
        var format: String
        var version: Int
    }

    private static func clearAttachmentPaths(in project: inout Project) {
        for i in project.messages.indices {
            var message = project.messages[i]
            let paths = Set(message.attachments.compactMap(\.sourcePath))
            guard !paths.isEmpty else { continue }
            var text = message.text
            for reference in AttachmentImporter.pastedDocumentReferences(in: message.text).reversed()
                where paths.contains(reference.url.standardizedFileURL.path) {
                text.replaceSubrange(reference.range, with: reference.url.lastPathComponent)
            }
            message.text = text
            for j in message.attachments.indices { message.attachments[j].sourcePath = nil }
            project.messages[i] = message
        }
    }

    private static func isValid(_ project: Project) -> Bool {
        Set(project.messages.map(\.id)).count == project.messages.count
            && Set(project.versions.map(\.id)).count == project.versions.count
            && Set(project.comments.map(\.id)).count == project.comments.count
            && isValid(project.workingDocument)
            && project.versions.allSatisfy { $0.document.map(isValid) ?? true }
    }

    private static func isValid(_ system: DesignSystem) -> Bool {
        abs(system.cornerRadius) <= Double(Int32.max)
            && abs(system.spacingUnit) <= Double(Int32.max)
            && Set(system.colors.map(\.id)).count == system.colors.count
    }

    private static func isValid(_ document: DesignDocument) -> Bool {
        guard !document.pages.isEmpty, Set(document.pages.map(\.id)).count == document.pages.count,
              Set(document.components.map(\.id)).count == document.components.count else { return false }
        var artboards: Set<UUID> = []
        return document.pages.allSatisfy { page in
            page.artboards.allSatisfy { board in
                artboards.insert(board.id).inserted
                    && [board.x, board.y, board.width, board.height].allSatisfy { abs($0) <= Double(Int32.max) }
                    && board.width > 0 && board.height > 0
            }
        }
    }

    private static func readPayload(_ data: Data) throws -> Data {
        // Limit the reader to the single-member ZIP written by DesignStudio. No paths are extracted.
        let start = 30 + member.count
        let directorySize = 46 + member.count
        guard data.count >= start + directorySize + 22 else { throw ArchiveError.invalid }
        return try data.withUnsafeBytes { bytes in
            func short(_ offset: Int) -> Int {
                Int(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
            }
            func word(_ offset: Int) -> Int {
                Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
            let stored = word(18)
            let size = word(22)
            let method = short(8)
            let checksum = word(14)
            let directory = start + stored
            let end = directory + directorySize
            guard size <= maximumSize else { throw ArchiveError.tooLarge }
            guard word(0) == 0x04034B50, short(6) == 0x0800, short(26) == member.count, short(28) == 0,
                  stored > 0, size > 0, end + 22 == data.count,
                  data[30..<start].elementsEqual(member),
                  word(directory) == 0x02014B50, short(directory + 8) == short(6), short(directory + 10) == method,
                  word(directory + 16) == checksum, word(directory + 20) == stored, word(directory + 24) == size,
                  short(directory + 28) == member.count, short(directory + 30) == 0, short(directory + 32) == 0,
                  word(directory + 42) == 0, data[(directory + 46)..<end].elementsEqual(member),
                  word(end) == 0x06054B50, word(end + 4) == 0, short(end + 8) == 1, short(end + 10) == 1,
                  word(end + 12) == directorySize, word(end + 16) == directory, short(end + 20) == 0
            else { throw ArchiveError.invalid }
            let payload: Data
            switch method {
            case 0 where stored == size:
                payload = data.subdata(in: start..<directory)
            case 8:
                var output = Data(count: size + 1)
                let written = output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
                    compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, size + 1,
                                              bytes.bindMemory(to: UInt8.self).baseAddress! + start, stored,
                                              nil, COMPRESSION_ZLIB)
                }
                guard written == size else { throw ArchiveError.invalid }
                output.removeLast()
                payload = output
            default:
                throw ArchiveError.invalid
            }
            guard ZipWriter.crc32(payload) == UInt32(checksum) else { throw ArchiveError.invalid }
            return payload
        }
    }

    enum ArchiveError: LocalizedError {
        case invalid
        case invalidSelection
        case tooLarge
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .invalid: "文件不是有效的 DesignStudio 项目，或文件已损坏。"
            case .invalidSelection: "请选择至少一张有效的画布。"
            case .tooLarge: "项目数据超过 256 MB。可尝试关闭对话、批注和版本历史后再导出。"
            case .unsupportedVersion(let version): "此文件使用项目格式 v\(version)。请更新 DesignStudio 后再试。"
            }
        }
    }
}
