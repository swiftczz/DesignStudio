import Foundation
import CoreGraphics

// MARK: - 画布交互状态

/// 底部浮动工具栏中的工具
/// 形状工具可画的图形
nonisolated enum ShapeKind: String, CaseIterable, Identifiable, Sendable {
    case rectangle, ellipse, arrow, line

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rectangle: "矩形"
        case .ellipse: "圆形"
        case .arrow: "箭头"
        case .line: "直线"
        }
    }

    var symbol: String {
        switch self {
        case .rectangle: "square"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        }
    }

    /// 直线 / 箭头按拖动方向画，矩形 / 圆形按拖出的矩形画
    var isStroke: Bool { self == .arrow || self == .line }
}

nonisolated enum CanvasTool: String, CaseIterable, Identifiable, Sendable {
    case select, hand, frame, text, rectangle, image, comment

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "选择"
        case .hand: "抓手"
        case .frame: "画板"
        case .text: "文本"
        case .rectangle: "形状"
        case .image: "图片"
        case .comment: "批注"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .hand: "hand.raised"
        case .frame: "number"
        case .text: "textformat"
        case .rectangle: "square"
        case .image: "photo"
        case .comment: "bubble.left"
        }
    }

    /// 单键快捷键
    var shortcut: Character {
        switch self {
        case .select: "v"
        case .hand: "h"
        case .frame: "f"
        case .text: "t"
        case .rectangle: "r"
        case .image: "i"
        case .comment: "c"
        }
    }

    var help: String {
        switch self {
        case .select: "选择（V）：点击选中元素，双击编辑文字，拖动绝对定位的元素"
        case .hand: "抓手（H）：拖动平移画布"
        case .frame: "画板（F）：点击或拖出一个新画板"
        case .text: "文本（T）：在画板上点击添加文字"
        case .rectangle: "形状（R）：在画板上拖出矩形、圆形、箭头或直线"
        case .image: "图片（I）：在画板上点击插入本地图片"
        case .comment: "批注（C）：点击元素留下修改意见，交给 AI 处理"
        }
    }

    /// 由 SwiftUI 覆盖层接管指针（画板网页不再收到点击）
    var capturesPointer: Bool { self != .select && self != .comment }
}

/// 画布上的选中对象：整个画板（elementID 为 nil）或画板中的某个元素
nonisolated struct CanvasSelection: Hashable, Sendable {
    var artboardID: UUID
    var elementID: Int?
}

/// 悬停高亮
nonisolated struct CanvasHover: Equatable, Sendable {
    var artboardID: UUID
    var elementID: Int
    var rect: ElementRect
}

// MARK: - 编辑脚本回传的数据

nonisolated struct ElementRect: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

nonisolated struct ElementNode: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var tag: String
    var kind: String
    var name: String
    var text: String
    var hidden: Bool?
    var children: [ElementNode]?

    /// 在树中查找从根到目标元素的路径（含目标）
    static func path(to id: Int, in nodes: [ElementNode]) -> [Int]? {
        for n in nodes {
            if n.id == id { return [n.id] }
            if let c = n.children, let sub = path(to: id, in: c) { return [n.id] + sub }
        }
        return nil
    }
}

nonisolated struct ElementProps: Codable, Hashable, Sendable {
    var id: Int
    var tag: String
    var kind: String
    var name: String
    var text: String?
    var rect: ElementRect
    var style: [String: String]
    var inline: [String: String]
    var src: String
    var href: String
    var selector: String
    var parentId: Int?
    var childCount: Int

    func css(_ key: String) -> String { style[key] ?? "" }
    func inlineCSS(_ key: String) -> String { inline[key] ?? "" }

    var isLayout: Bool { css("display").contains("flex") || css("display").contains("grid") }
    var hasText: Bool { text != nil || kind == "button" || kind == "link" }
    var isAbsolute: Bool { ["absolute", "fixed"].contains(css("position")) }
}

nonisolated struct EditResult: Codable, Sendable {
    var id: Int?
    var props: ElementProps?
    var source: String?
    var tree: [ElementNode]?
}

/// 编辑脚本通过 postMessage 发来的消息
nonisolated struct EditorMessage: Decodable, Sendable {
    var type: String
    var id: Int?
    var rect: ElementRect?
    var props: ElementProps?
    var result: EditResult?
    var message: String?
    var key: String?
    var meta: Bool?
    var shift: Bool?
    var alt: Bool?
    var ctrl: Bool?
    /// 右键位置（画板内的 CSS 坐标）与元素信息
    var x: Double?
    var y: Double?
    var info: ContextInfo?
}

/// 右键菜单需要的元素信息（决定哪些菜单项可用）
nonisolated struct ContextInfo: Codable, Hashable, Sendable {
    var isFirst: Bool
    var isLast: Bool
    var hasChildren: Bool
}

/// 元素类型的显示名称与图标
nonisolated enum ElementKind {
    static func title(_ kind: String) -> String {
        switch kind {
        case "text": "文本"
        case "button": "按钮"
        case "image": "图片"
        case "input": "输入框"
        case "link": "链接"
        case "grid": "网格"
        case "row": "横排"
        case "column": "竖排"
        default: "容器"
        }
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "text": "text.alignleft"
        case "button": "capsule"
        case "image": "photo"
        case "input": "character.cursor.ibeam"
        case "link": "link"
        case "grid": "square.grid.2x2"
        case "row": "rectangle.split.3x1"
        case "column": "rectangle.split.1x2"
        default: "square.dashed"
        }
    }
}
