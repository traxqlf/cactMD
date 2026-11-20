import Combine
import SwiftUI
import Sparkle

/// SwiftUI wrapper around Sparkle's standard updater controller.
///
/// The controller owns the updater for the whole app lifetime, so this model
/// has to stay alive as long as the app runs (it is declared as a
/// `@StateObject` in `MyApp`). `startingUpdater: true` schedules the automatic
/// background checks requested by `SUEnableAutomaticChecks` in `Info.plist`.
final class UpdaterViewModel: ObservableObject {
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Opens Sparkle's « Rechercher des mises à jour… » window.
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
