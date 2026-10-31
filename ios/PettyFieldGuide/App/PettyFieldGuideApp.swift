import SwiftUI

@main
struct PettyFieldGuideApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var theme = ThemeManager.shared
    @StateObject private var router = AppRouter()
    @StateObject private var content = ContentStore.shared
    @StateObject private var saved = SavedStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .nightVision()
                .environmentObject(theme)
                .environmentObject(router)
                .environmentObject(content)
                .environmentObject(saved)
                .preferredColorScheme(theme.resolvedColorScheme)
                .tint(Palette.accent)
                .onOpenURL { url in router.open(url: url) }
                .onReceive(NotificationCenter.default.publisher(for: .pushDeepLink)) { note in
                    if let url = note.object as? URL { router.open(url: url) }
                }
        }
    }
}
