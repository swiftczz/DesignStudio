import SwiftUI

struct SidebarFooterBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            content.frame(height: 32)
        }
    }
}
