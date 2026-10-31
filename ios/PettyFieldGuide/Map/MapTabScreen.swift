import SwiftUI

/// The Map tab: one continuous map from the whole park down to Valley buildings. Links, searches and
/// "show on map" requests all land on it.
struct MapTabScreen: View {
    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = MapViewModel(restoresPreferences: true)

    var body: some View {
        MapScreen(model: model)
            .onAppear(perform: routeFocus)
            .onChange(of: router.mapFocus) { _, _ in routeFocus() }
    }

    private func routeFocus() {
        guard let focus = router.mapFocus else { return }
        router.mapFocus = nil
        model.focus(on: focus)
    }
}
