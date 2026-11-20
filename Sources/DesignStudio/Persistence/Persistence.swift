import Foundation
import AppKit
import Observation

/// 简单的 JSON 文件存储：~/Library/Application Support/DesignStudio
@MainActor
@Observable
final class PersistenceController {
    let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    @ObservationIgnored private let writer = ProjectDiskWriter()
    @ObservationIgnored private var pending: [UUID: Project] = [:]
    @ObservationIgnored private var scheduledSave: Task<Void, Never>?
    private(set) var saveErrors: [UUID: String] = [:]
    private(set) var recoveredCount = 0
    private(set) var unreadableCount = 0

    init(root: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.root = root ?? base.appending(path: "DesignStudio", directoryHint: .isDirectory)

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
        recoveredCount = 0
        unreadableCount = 0
        return dirs.compactMap { dir in
            guard let id = UUID(uuidString: dir.lastPathComponent) else { return nil }
            if let project = ProjectDiskWriter.read(dir, name: "project.json", id: id, decoder: decoder) {
                return project
            }
            if let backup = ProjectDiskWriter.read(dir, name: "project.backup.json", id: id, decoder: decoder) {
                recoveredCount += 1
                return backup
            }
            unreadableCount += 1
            return nil
        }
    }

    func save(_ project: Project) {
        pending[project.id] = project
        guard scheduledSave == nil else { return }
        scheduledSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            self?.enqueuePending()
        }
    }

    private func enqueuePending() {
        scheduledSave?.cancel()
        scheduledSave = nil
        let projects = pending
        pending.removeAll()
        guard !projects.isEmpty else { return }
        writer.enqueue(projects, directory: projectsDirectory) { [weak self] errors in
            self?.saveErrors = errors
        }
    }

    func flush() -> Bool {
        enqueuePending()
        saveErrors = writer.errors()
        return saveErrors.isEmpty
    }

    func dismissLoadNotice() {
        recoveredCount = 0
        unreadableCount = 0
    }

    /// Commit a new project before adding it to the sidebar. Roll back if its design system cannot be saved.
    func saveImportedProject(_ project: Project, designSystems: [DesignSystem]?) throws {
        let data = try encoder.encode(project)
        let dir = projectDirectory(project.id)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        do {
            try data.write(to: dir.appending(path: "project.json"), options: .atomic)
            if let designSystems {
                try encoder.encode(designSystems).write(to: root.appending(path: "design-systems.json"), options: .atomic)
            }
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    func deleteProject(_ id: UUID) throws {
        // Drain in-flight writes before moving the folder, so a late write cannot recreate it.
        let dir = projectDirectory(id)
        try writer.removeProject(id, directory: dir)
        pending[id] = nil
        saveErrors = writer.errors()
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


// All project writes and deletes use this queue. The UI keeps only the newest unsent snapshot.
nonisolated private final class ProjectDiskWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.designstudio.project-writes", qos: .utility)
    private var failures: [UUID: String] = [:]

    func enqueue(_ projects: [UUID: Project], directory: URL, completion: @escaping @MainActor @Sendable ([UUID: String]) -> Void) {
        queue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for (id, project) in projects {
                let folder = directory.appending(path: id.uuidString, directoryHint: .isDirectory)
                do {
                    let data = try encoder.encode(project)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let current = folder.appending(path: "project.json")
                    if let old = try? Data(contentsOf: current),
                       old != data, (try? decoder.decode(Project.self, from: old))?.id == id {
                        try old.write(to: folder.appending(path: "project.backup.json"), options: .atomic)
                    }
                    try data.write(to: current, options: .atomic)
                    self.failures[id] = nil
                } catch {
                    self.failures[id] = error.localizedDescription
                }
            }
            let errors = self.failures
            DispatchQueue.main.async { completion(errors) }
        }
    }

    func errors() -> [UUID: String] {
        queue.sync { failures }
    }

    func removeProject(_ id: UUID, directory: URL) throws {
        try queue.sync {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
            }
            failures[id] = nil
        }
    }

    static func read(_ folder: URL, name: String, id: UUID, decoder: JSONDecoder) -> Project? {
        guard let data = try? Data(contentsOf: folder.appending(path: name)),
              let project = try? decoder.decode(Project.self, from: data), project.id == id else { return nil }
        return project
    }
}
