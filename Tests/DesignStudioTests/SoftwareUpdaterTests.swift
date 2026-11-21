import Testing
@testable import DesignStudio

@MainActor
struct SoftwareUpdaterTests {
    @Test(arguments: [
        ("0.8.0", "66", "0.10.1", "66", true),
        ("0.10.1", "66", "0.10.1", "66", false),
        ("0.11.0", "66", "0.10.1", "66", false),
        ("0.8.0", "55", "0.10.1", "66", false),
        ("0.8.0", "67", "0.10.1", "66", false)
    ])
    func promptsForNewerReleaseWhenBuildsMatch(
        installedVersion: String, installedBuild: String, releaseVersion: String, releaseBuild: String, expected: Bool
    ) {
        #expect(SoftwareUpdater.isNewerReleaseWithSameBuild(
            installedVersion: installedVersion, installedBuild: installedBuild,
            releaseVersion: releaseVersion, releaseBuild: releaseBuild
        ) == expected)
    }
}
