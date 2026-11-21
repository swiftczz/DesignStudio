import AppKit
import Combine
import Foundation
import Observation
import Sparkle

@Observable
final class SoftwareUpdater {
    private let updater: SPUUpdater?
    @ObservationIgnored private var availabilityObservation: AnyCancellable?
    @ObservationIgnored private var started = false

    private(set) var canCheckForUpdates = false

    var isConfigured: Bool { updater != nil }
    static let installedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    var automaticallyChecksForUpdates = false {
        didSet { updater?.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    init() {
        let bundle = Bundle.main
        if bundle.object(forInfoDictionaryKey: "SUPublicEDKey") is String {
            let driver = DesignStudioUpdateDriver(hostBundle: bundle, delegate: nil)
            updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: nil)
        } else {
            updater = nil
        }
    }

    func start(legacyAutomaticChecks: Bool?) {
        guard !started, let updater else { return }
        started = true

        // 旧版本把这项偏好存在 settings.json。之后由 Sparkle 保存用户选择。
        let preference = "SUEnableAutomaticChecks"
        if let legacyAutomaticChecks, UserDefaults.standard.object(forKey: preference) == nil {
            UserDefaults.standard.set(legacyAutomaticChecks, forKey: preference)
        }
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        do {
            try updater.start()
            availabilityObservation = updater.publisher(for: \.canCheckForUpdates, options: [.initial, .new])
                .sink { [weak self] in self?.canCheckForUpdates = $0 }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        updater?.checkForUpdates()
    }

    static func isNewerReleaseWithSameBuild(installedVersion: String, installedBuild: String,
                                           releaseVersion: String, releaseBuild: String) -> Bool {
        let versions = SUStandardVersionComparator.default
        return versions.compareVersion(installedBuild, toVersion: releaseBuild) == .orderedSame
            && versions.compareVersion(installedVersion, toVersion: releaseVersion) == .orderedAscending
    }
}

private final class DesignStudioUpdateDriver: SPUStandardUserDriver {
    override func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let info = (error as NSError).userInfo
        guard let item = info[SPULatestAppcastItemFoundKey] as? SUAppcastItem,
              item.minimumOperatingSystemVersionIsOK, item.maximumOperatingSystemVersionIsOK,
              item.arm64HardwareRequirementIsOK, item.minimumUpdateVersionIsOK,
              let version = SoftwareUpdater.installedVersion,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              SoftwareUpdater.isNewerReleaseWithSameBuild(installedVersion: version, installedBuild: build,
                                                         releaseVersion: item.displayVersionString, releaseBuild: item.versionString)
        else {
            super.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
            return
        }

        // Sparkle 只会提供构建号更高的安装包。已验证的 appcast 仍可用于提示同构建号的新版。
        dismissUpdateInstallation()
        let alert = NSAlert()
        alert.messageText = "发现 DesignStudio \(item.displayVersionString)"
        alert.informativeText = "你正在使用 \(version)（\(build)）。可以前往发行页面下载更新。"
        alert.addButton(withTitle: "打开下载页面")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn,
           let releasePage = URL(string: "https://github.com/swiftczz/DesignStudio/releases/latest") {
            NSWorkspace.shared.open(releasePage)
        }
        acknowledgement()
    }
}
