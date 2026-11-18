import Foundation
import AppKit

/// 简单的 JSON 文件存储：~/Library/Application Support/DesignStudio
@MainActor
final class PersistenceController {
    let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appending(path: "DesignStudio", directoryHint: .isDirectory)

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        try? FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
    }

    var projectsDirectory: URL { root.appending(path: "Projects", directoryHint: .isDirectory) }

    func projectDirectory(_ id: UUID) -> URL {
        projectsDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    func thumbnailURL(_ id: UUID) -> URL {
        projectDirectory(id).appending(path: "thumbnail.png")
    }

    // MARK: Projects

    // MARK: - 生成中标记

    /// 有生成在进行时，这里存在以项目 ID 命名的空文件；重建 / 重启应用前可据此判断是否会打断生成
    var generatingDirectory: URL { root.appending(path: "generating", directoryHint: .isDirectory) }

    func setGenerating(_ projectID: UUID, _ active: Bool) {
        let fm = FileManager.default
        let file = generatingDirectory.appending(path: projectID.uuidString)
        if active {
            try? fm.createDirectory(at: generatingDirectory, withIntermediateDirectories: true)
            fm.createFile(atPath: file.path, contents: Data())
        } else {
            try? fm.removeItem(at: file)
        }
    }

    /// 启动时清掉上次异常退出留下的标记
    func clearGeneratingMarkers() {
        try? FileManager.default.removeItem(at: generatingDirectory)
    }

    func loadProjects() -> [Project] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir in
            let file = dir.appending(path: "project.json")
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? decoder.decode(Project.self, from: data)
        }
    }

    func save(_ project: Project) {
        guard let data = try? encoder.encode(project) else { return }
        let dir = projectDirectory(project.id)
        let file = dir.appending(path: "project.json")
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    func deleteProject(_ id: UUID) {
        let dir = projectDirectory(id)
        do {
            try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        } catch {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    func saveThumbnail(_ image: NSImage, for id: UUID) {
        guard let data = ImageUtil.pngData(image, maxWidth: 960) else { return }
        let dir = projectDirectory(id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: thumbnailURL(id), options: .atomic)
    }

    // MARK: Generic

    func load<T: Decodable>(_ type: T.Type, file: String) -> T? {
        let url = root.appending(path: file)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    func store<T: Encodable>(_ value: T, file: String) {
        guard let data = try? encoder.encode(value) else { return }
        let url = root.appending(path: file)
        try? data.write(to: url, options: .atomic)
    }
}
