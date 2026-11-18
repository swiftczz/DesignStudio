import Combine
import Foundation
import Observation
import Sparkle

@Observable
final class SoftwareUpdater {
    private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var availabilityObservation: AnyCancellable?
    @ObservationIgnored private var started = false

    private(set) var canCheckForUpdates = false

    var isConfigured: Bool { controller != nil }
    static let installedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    var automaticallyChecksForUpdates = false {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    init() {
        if Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String {
            controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        } else {
            controller = nil
        }
    }

    func start(legacyAutomaticChecks: Bool?) {
        guard !started, let controller else { return }
        started = true

        // 旧版本把这项偏好存在 settings.json。之后由 Sparkle 保存用户选择。
        let preference = "SUEnableAutomaticChecks"
        if let legacyAutomaticChecks, UserDefaults.standard.object(forKey: preference) == nil {
            UserDefaults.standard.set(legacyAutomaticChecks, forKey: preference)
        }
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        controller.startUpdater()
        availabilityObservation = controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }
}
