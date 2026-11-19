import SwiftUI

/// 画板标题栏上的导出按钮：导出这一个画板（选中画板或其中任意元素时都作用于整个画板）
struct ArtboardExportMenu: View {
    let artboard: Artboard
    let session: ProjectSession

    private var name: String {
        let project = session.project?.name ?? "设计"
        return "\(project)-\(artboard.name)"
    }

    /// 合并了画布共用样式的完整 HTML，单独打开也完整
    private var html: String { session.document.composedHTML(artboard.id) ?? artboard.html }

    /// 当前选中、属于这个画板的元素
    private var selectedElement: (id: Int, name: String)? {
        guard let sel = session.selection, sel.artboardID == artboard.id, let id = sel.elementID else { return nil }
        let props = session.selectedProps?.id == id ? session.selectedProps : nil
        let label = props.map { $0.name.trimmed.isEmpty ? $0.tag : $0.name } ?? "元素"
        return (id, label)
    }

    var body: some View {
        Menu {
            if let element = selectedElement {
                elementSection(element)
                Divider()
            }
            Section("导出画板「\(artboard.name)」") {
                Button("导出 HTML…", systemImage: "doc.richtext") { ExportService.exportHTML(html, name: name) }
                Button("导出 PNG…", systemImage: "photo") {
                    Task { ExportService.exportPNG(await session.snapshot(artboard), name: name) }
                }
                Button("导出 PDF…", systemImage: "doc") {
                    Task {
                        do { ExportService.exportPDF(try await session.pdf(artboard), name: name) }
                        catch { ExportService.presentError("导出 PDF 失败", error) }
                    }
                }
                Button("导出 ZIP（HTML + PNG + PDF）…", systemImage: "doc.zipper") {
                    let html = html
                    Task {
                        let png = await session.snapshot(artboard).flatMap { ImageUtil.pngData($0) }
                        let pdf = try? await session.pdf(artboard)
                        ExportService.exportArtboardZip(name: name, html: html, png: png, pdf: pdf)
                    }
                }
            }
            Divider()
            Button("在浏览器中打开", systemImage: "safari") { ExportService.openInBrowser(html, name: name) }
            Button("拷贝 HTML", systemImage: "doc.on.doc") { ExportService.copyHTML(html) }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(selectedElement == nil ? "导出这个画板" : "导出选中的元素或这个画板")
    }

    /// 选中元素：样式展开后单独导出（PNG 为 2 倍图）
    @ViewBuilder
    private func elementSection(_ element: (id: Int, name: String)) -> some View {
        let fileName = "\(name)-\(element.name)"
        let board = artboard.id
        Section("导出选中元素「\(element.name)」") {
            Button("导出 PNG…", systemImage: "photo") {
                Task {
                    ExportService.exportPNG(await session.elementImage(artboardID: board, elementID: element.id), name: fileName)
                }
            }
            Button("导出 SVG…", systemImage: "square.on.circle") {
                Task {
                    guard let svg = await session.elementSVG(artboardID: board, elementID: element.id) else {
                        ExportService.presentError("导出 SVG 失败", nil); return
                    }
                    ExportService.exportSVG(svg, name: fileName)
                }
            }
            Button("导出 HTML…", systemImage: "doc.richtext") {
                Task {
                    guard let html = await session.elementDocument(artboardID: board, elementID: element.id,
                                                                    title: element.name) else {
                        ExportService.presentError("导出失败", nil); return
                    }
                    ExportService.exportHTML(html, name: fileName)
                }
            }
            Button("导出 ZIP（HTML + PNG + SVG）…", systemImage: "doc.zipper") {
                Task {
                    let html = await session.elementDocument(artboardID: board, elementID: element.id, title: element.name)
                    let png = await session.elementImage(artboardID: board, elementID: element.id).flatMap { ImageUtil.pngData($0) }
                    let svg = await session.elementSVG(artboardID: board, elementID: element.id)
                    ExportService.exportElementZip(name: fileName, html: html, png: png, svg: svg)
                }
            }
        }
    }
}
