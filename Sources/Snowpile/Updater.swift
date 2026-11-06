import AppKit
import Combine
import Sparkle

/// Sparkle updates from the GitHub release feed named in Info.plist.
final class Updater: ObservableObject {
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private let controller: SPUStandardUpdaterController?
    private var observation: AnyCancellable?
    @Published private(set) var canCheck = false
    @Published var automaticallyChecks: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    init() {
        // Builds run straight from `swift run` have no feed or key; they simply never update.
        let configured = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
        controller = configured ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil
        automaticallyChecks = controller?.updater.automaticallyChecksForUpdates ?? false
        observation = controller?.updater.publisher(for: \.canCheckForUpdates).sink { [weak self] in self?.canCheck = $0 }
    }

    func checkNow() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
}
