import XCTest

/// Pure-function mirror of the path resolution algorithm used by both Xcode plugins.
///
/// Plugin targets cannot be imported in tests (SPM limitation), so this helper
/// replicates the exact algorithm. Any change to a plugin's `packageSourcesPath`
/// must be reflected here — the tests below will catch regressions in the algorithm
/// itself (correct number of `deletingLastPathComponent` calls, `lastPathComponent`
/// guard, and `appendingPathComponent` for macOS compatibility).
enum PluginPathResolution {

    /// Mirrors GenerateAcknowledgementsCommand.packageSourcesPath.
    ///
    /// Old Xcode path (2 levels above pluginWorkDir):
    ///   {DerivedData}/xxx/SourcePackages/plugins/GenerateAcknowledgementsCommand/
    /// New Xcode path (4 levels above pluginWorkDir + append):
    ///   {DerivedData}/xxx/Build/Intermediates.noindex/CommandPluginIntermediates/GenerateAcknowledgementsCommand/
    static func commandPlugin(pluginWorkDirectoryURL: URL) -> URL {
        var packageSourcesPath = pluginWorkDirectoryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        if packageSourcesPath.lastPathComponent != "SourcePackages" {
            packageSourcesPath = packageSourcesPath
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("SourcePackages")
        }

        return packageSourcesPath
    }

    /// Mirrors LicensePlistBuildTool path resolution (from PR #241).
    ///
    /// Old Xcode path (4 levels above pluginWorkDir):
    ///   {DerivedData}/xxx/SourcePackages/plugins/MyApp.output/MyApp/LicensePlistBuildTool/
    /// New Xcode path (6 levels above pluginWorkDir + append):
    ///   {DerivedData}/xxx/Build/Intermediates.noindex/BuildToolPluginIntermediates/MyApp.output/MyApp/LicensePlistBuildTool/
    ///
    /// `LICENSE_PLIST_PACKAGE_SOURCES_PATH` takes precedence over the auto-detected path,
    /// and a relative value is resolved against the project directory.
    static func buildToolPlugin(environment: [String: String] = [:],
                                projectDirectoryURL: URL = URL(fileURLWithPath: "/"),
                                pluginWorkDirectoryURL: URL) -> URL {
        if let path = environment["LICENSE_PLIST_PACKAGE_SOURCES_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true, relativeTo: projectDirectoryURL).absoluteURL
        }

        var packageSourcesPath = pluginWorkDirectoryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        if packageSourcesPath.lastPathComponent != "SourcePackages" {
            packageSourcesPath = packageSourcesPath
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("SourcePackages")
        }

        return packageSourcesPath
    }
}

/// Tests the path resolution algorithm used by Xcode plugins to locate
/// the SourcePackages directory from `pluginWorkDirectoryURL`.
final class PluginPathResolutionTests: XCTestCase {

    // MARK: - GenerateAcknowledgementsCommand path resolution

    /// Old Xcode (<=16.2): pluginWorkDirectoryURL is under SourcePackages.
    /// Path: {DerivedData}/xxx/SourcePackages/plugins/GenerateAcknowledgementsCommand/
    /// Going up 2 levels should yield {DerivedData}/xxx/SourcePackages/
    func testCommandPlugin_oldXcode_resolvesSourcePackages() {
        let pluginWorkDir = URL(fileURLWithPath: "/Users/user/Library/Developer/Xcode/DerivedData/MyApp-abc/SourcePackages/plugins/GenerateAcknowledgementsCommand")

        let resolved = PluginPathResolution.commandPlugin(pluginWorkDirectoryURL: pluginWorkDir)

        XCTAssertEqual(resolved.path, "/Users/user/Library/Developer/Xcode/DerivedData/MyApp-abc/SourcePackages")
    }

    /// New Xcode (>=16.3 / Xcode 26): pluginWorkDirectoryURL is under Build/Intermediates.noindex.
    /// Path: {DerivedData}/xxx/Build/Intermediates.noindex/CommandPluginIntermediates/GenerateAcknowledgementsCommand/
    /// The naive 2-level ascent would land at Build/Intermediates.noindex/ — wrong.
    /// The fix must detect the absence of "SourcePackages" and navigate to {DerivedData}/xxx/SourcePackages/
    func testCommandPlugin_newXcode_resolvesSourcePackages() {
        let pluginWorkDir = URL(fileURLWithPath: "/Users/user/Library/Developer/Xcode/DerivedData/MyApp-abc/Build/Intermediates.noindex/CommandPluginIntermediates/GenerateAcknowledgementsCommand")

        let resolved = PluginPathResolution.commandPlugin(pluginWorkDirectoryURL: pluginWorkDir)

        XCTAssertEqual(resolved.path, "/Users/user/Library/Developer/Xcode/DerivedData/MyApp-abc/SourcePackages")
    }

    // MARK: - LicensePlistBuildTool path resolution (regression guard)

    /// Old Xcode: pluginWorkDirectoryURL is under SourcePackages.
    /// Path: {DerivedData}/xxx/SourcePackages/plugins/MyApp.output/MyApp/LicensePlistBuildTool/
    func testBuildToolPlugin_oldXcode_resolvesSourcePackages() {
        let pluginWorkDir = URL(fileURLWithPath: "/Users/user/Library/Developer/Xcode/DerivedData/MyApp-abc/SourcePackages/plugins/MyApp.output/MyApp/LicensePlistBuildTool")

        let resolved = PluginPathResolution.buildToolPlugin(pluginWorkDirectoryURL: pluginWorkDir)

        XCTAssertEqual(resolved.path, "/Users/user/Library/Developer/Xcode/DerivedData/MyApp-abc/SourcePackages")
    }

    /// New Xcode: pluginWorkDirectoryURL is under Build/Intermediates.noindex.
    /// Path: {DerivedData}/xxx/Build/Intermediates.noindex/BuildToolPluginIntermediates/MyApp.output/MyApp/LicensePlistBuildTool/
    func testBuildToolPlugin_newXcode_resolvesSourcePackages() {
        let pluginWorkDir = URL(fileURLWithPath: "/Users/user/Library/Developer/Xcode/DerivedData/MyApp-abc/Build/Intermediates.noindex/BuildToolPluginIntermediates/MyApp.output/MyApp/LicensePlistBuildTool")

        let resolved = PluginPathResolution.buildToolPlugin(pluginWorkDirectoryURL: pluginWorkDir)

        XCTAssertEqual(resolved.path, "/Users/user/Library/Developer/Xcode/DerivedData/MyApp-abc/SourcePackages")
    }

    // MARK: - LicensePlistBuildTool environment variable override

    private let newXcodeBuildToolPluginWorkDir = URL(fileURLWithPath: "/Users/user/Library/Developer/Xcode/DerivedData/MyApp-abc/Build/Intermediates.noindex/BuildToolPluginIntermediates/MyApp.output/MyApp/LicensePlistBuildTool")
    private let projectDir = URL(fileURLWithPath: "/Users/user/MyApp", isDirectory: true)

    /// e.g. `xcodebuild -clonedSourcePackagesDirPath /tmp/ci/SourcePackages` on Xcode >=16.3,
    /// where the auto-detected path does not exist.
    func testBuildToolPlugin_environmentAbsolutePath_takesPrecedence() {
        let resolved = PluginPathResolution.buildToolPlugin(
            environment: ["LICENSE_PLIST_PACKAGE_SOURCES_PATH": "/tmp/ci/SourcePackages"],
            projectDirectoryURL: projectDir,
            pluginWorkDirectoryURL: newXcodeBuildToolPluginWorkDir)

        XCTAssertEqual(resolved.path, "/tmp/ci/SourcePackages")
    }

    func testBuildToolPlugin_environmentRelativePath_resolvesAgainstProjectDirectory() {
        let resolved = PluginPathResolution.buildToolPlugin(
            environment: ["LICENSE_PLIST_PACKAGE_SOURCES_PATH": "SourcePackages"],
            projectDirectoryURL: projectDir,
            pluginWorkDirectoryURL: newXcodeBuildToolPluginWorkDir)

        XCTAssertEqual(resolved.path, "/Users/user/MyApp/SourcePackages")
    }

    func testBuildToolPlugin_emptyEnvironmentValue_fallsBackToAutoDetection() {
        let resolved = PluginPathResolution.buildToolPlugin(
            environment: ["LICENSE_PLIST_PACKAGE_SOURCES_PATH": ""],
            projectDirectoryURL: projectDir,
            pluginWorkDirectoryURL: newXcodeBuildToolPluginWorkDir)

        XCTAssertEqual(resolved.path, "/Users/user/Library/Developer/Xcode/DerivedData/MyApp-abc/SourcePackages")
    }
}
