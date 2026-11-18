import Foundation
import Testing
@testable import DesignStudio

@Suite("软件更新")
struct UpdateServiceTests {
    @Test func comparesVersionComponentsNumerically() throws {
        let data = release()
        let available = try UpdateService.availableUpdate(in: data, installedVersion: "0.9.0")
        let update = try #require(available)
        #expect(update.version == "0.10.0")
        #expect(update.notes == "更新说明")
        #expect(update.downloadURL.absoluteString == downloadURL)
        #expect(try UpdateService.availableUpdate(in: data, installedVersion: "0.10.0") == nil)
        #expect(try UpdateService.availableUpdate(in: data, installedVersion: "1.0.0") == nil)
    }

    @Test func ignoresDraftsAndPrereleases() throws {
        #expect(try UpdateService.availableUpdate(in: release(draft: true), installedVersion: "0.9.0") == nil)
        #expect(try UpdateService.availableUpdate(in: release(prerelease: true), installedVersion: "0.9.0") == nil)
    }

    @Test func requiresTheUploadedInstallerForTheMatchingRelease() {
        for asset in ["", installer(state: "new"), installer(url: "https://example.com/DesignStudio-0.10.0.dmg")] {
            #expect(throws: UpdateService.CheckError.missingInstaller) {
                try UpdateService.availableUpdate(in: release(asset: asset), installedVersion: "0.9.0")
            }
        }
    }

    @Test func loadsSettingsSavedBeforeUpdateChecksExisted() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"accentTheme":"terracotta"}"#.utf8))
        #expect(settings.accentTheme == "terracotta")
        #expect(settings.automaticallyChecksForUpdates == nil)
        #expect(settings.lastUpdateCheck == nil)
    }

    private var downloadURL: String {
        "https://github.com/swiftczz/DesignStudio/releases/download/v0.10.0/DesignStudio-0.10.0.dmg"
    }

    private func installer(state: String = "uploaded", url: String? = nil) -> String {
        #"{"name":"DesignStudio-0.10.0.dmg","state":"\#(state)","browser_download_url":"\#(url ?? downloadURL)"}"#
    }

    private func release(draft: Bool = false, prerelease: Bool = false, asset: String? = nil) -> Data {
        Data(#"{"tag_name":"v0.10.0","draft":\#(draft),"prerelease":\#(prerelease),"body":"更新说明","assets":[\#(asset ?? installer())]}"#.utf8)
    }
}
