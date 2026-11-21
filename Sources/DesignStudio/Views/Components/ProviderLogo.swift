import SwiftUI
import AppKit

/// 模型来源对应的服务商品牌（用于显示官方 Logo）
enum ProviderBrand: String, CaseIterable {
    case claude, anthropic, openai, antigravity, openrouter, deepseek, zhipu, kimi, bailian, siliconflow, ollama

    /// 按来源判断品牌：账号登录类型 → Base URL 域名 → 名称关键字
    static func detect(_ profile: ProviderProfile) -> ProviderBrand? {
        switch profile.kind {
        case .claudeCode: return .claude
        case .codex, .chatGPT: return .openai
        case .antigravity: return .antigravity
        default: break
        }
        let url = profile.baseURL.lowercased()
        let hosts: [(String, ProviderBrand)] = [
            ("anthropic.com", .anthropic), ("openai.com", .openai), ("openrouter.ai", .openrouter),
            ("deepseek.com", .deepseek), ("bigmodel.cn", .zhipu), ("z.ai", .zhipu),
            ("moonshot", .kimi), ("dashscope", .bailian), ("aliyuncs.com", .bailian),
            ("siliconflow", .siliconflow), (":11434", .ollama), ("ollama", .ollama)
        ]
        if let hit = hosts.first(where: { url.contains($0.0) }) { return hit.1 }
        return detect(name: profile.name)
    }

    /// 只有名称时（例如旧消息里记录的「DeepSeek · deepseek-chat」）按关键字判断
    static func detect(name: String) -> ProviderBrand? {
        let s = name.lowercased()
        let keys: [(String, ProviderBrand)] = [
            ("claude", .claude), ("anthropic", .anthropic), ("codex", .openai), ("openai", .openai),
            ("chatgpt", .openai), ("antigravity", .antigravity), ("openrouter", .openrouter), ("deepseek", .deepseek),
            ("智谱", .zhipu), ("glm", .zhipu), ("kimi", .kimi), ("moonshot", .kimi),
            ("百炼", .bailian), ("通义", .bailian), ("qwen", .bailian), ("硅基", .siliconflow),
            ("siliconflow", .siliconflow), ("ollama", .ollama)
        ]
        return keys.first(where: { s.contains($0.0) })?.1
    }

    /// 渲染好的单色 Logo：模板图，显示时跟随文字颜色（深色模式、选中行自动变白）
    @MainActor
    var image: NSImage? {
        if let cached = Self.cache[self] { return cached }
        guard let image = NSImage(data: Data(svg.utf8)) else { return nil }
        image.isTemplate = true
        Self.cache[self] = image
        return image
    }

    @MainActor private static var cache: [ProviderBrand: NSImage] = [:]
}

/// 服务商 Logo；识别不出品牌时显示接口类型的系统图标
struct ProviderLogo: View {
    let brand: ProviderBrand?
    var fallbackSymbol = "network"
    var size: CGFloat = 16

    init(_ profile: ProviderProfile?, size: CGFloat = 16) {
        brand = profile.flatMap(ProviderBrand.detect)
        fallbackSymbol = profile?.kind.symbol ?? "cpu"
        self.size = size
    }

    init(brand: ProviderBrand?, size: CGFloat = 16) {
        self.brand = brand
        self.size = size
    }

    var body: some View {
        // 不指定颜色：跟随所在位置的文字颜色
        if let brand, let image = brand.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: size * 0.8))
                .frame(width: size, height: size)
        }
    }
}

extension ProviderBrand {
    /// 菜单项图标：菜单里只能用固定尺寸的 NSImage
    @MainActor
    func menuImage() -> NSImage? {
        guard let base = image, let copy = base.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: 16, height: 16)
        copy.isTemplate = true
        return copy
    }
}
