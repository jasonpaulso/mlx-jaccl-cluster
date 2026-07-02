import Foundation
import Observation

/// Composition root: wires the stores together and is injected into the
/// SwiftUI environment by the thin app target.
@MainActor
@Observable
public final class AppModel {
    public let settings: SettingsStore
    public let hostfiles: HostfileStore
    public let server: ServerController
    public let library: ModelLibraryStore

    public init() {
        let settings = SettingsStore()
        let hostfiles = HostfileStore()
        self.settings = settings
        self.hostfiles = hostfiles
        self.server = ServerController(settings: settings, hostfileStore: hostfiles)
        self.library = ModelLibraryStore(settings: settings)

        hostfiles.refreshAvailableHostfiles(repoURL: settings.config.repoURL)
        if let url = settings.config.hostfileURL, FileManager.default.fileExists(atPath: url.path) {
            hostfiles.load(from: url)
        }
    }

    /// Re-derive everything that depends on Settings (repo path, models dir, token).
    public func settingsChanged() {
        hostfiles.refreshAvailableHostfiles(repoURL: settings.config.repoURL)
        library.rebuildEngines()
        library.rescan()
        library.startWatching()
    }
}
