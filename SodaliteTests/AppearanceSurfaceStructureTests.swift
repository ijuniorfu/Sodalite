import Foundation
import Testing

@Suite("Appearance surface structure")
struct AppearanceSurfaceStructureTests {
    @Test("presentation surface isolates content and increments depth")
    func presentationSurfacePrimitive() throws {
        let source = try sourceFile("Sodalite/Extensions/GlassBackground.swift")
        #expect(source.contains("func themedPresentationBackground()"))
        #expect(source.contains("Color.black.ignoresSafeArea()"))
        #expect(source.contains("parentDepth + 1"))
        #expect(source.contains("AppBackgroundView(theme: theme, mode: .automatic)"))
        #expect(source.contains(".presentationBackground(.clear)"))
    }

    @Test("path navigation has the same clear iOS container")
    func pathNavigationPrimitive() throws {
        let source = try sourceFile("Sodalite/Extensions/View+PlatformCompat.swift")
        #expect(source.contains("struct ThemeNavigationPathStack"))
        #expect(source.contains("NavigationStack(path: $path)"))
        #expect(source.contains("containerBackground(.clear, for: .navigation)"))
    }

    @Test("settings owns one presentation renderer and child pages inherit it")
    func settingsSurfaceOwnership() throws {
        let tabRoot = try sourceFile("Sodalite/App/TabRootView.swift")
        let settings = try sourceFile("Sodalite/Features/Settings/SettingsView.swift")
        let seerr = try sourceFile("Sodalite/Features/Settings/SeerrSettingsView.swift")
        let licenses = try sourceFile("Sodalite/Features/Settings/Licenses/LicensesView.swift")
        let changelog = try sourceFile("Sodalite/Features/Changelog/ChangelogListView.swift")

        #expect(tabRoot.contains(
            "SettingsView(onClose: { showSettings = false })\n"
                + "                .themedPresentationBackground()"
        ))
        #expect(settings.contains("ThemeNavigationStack {"))
        #expect(!seerr.contains(".themedStaticBackground()"))
        #expect(!licenses.contains(".themedStaticBackground()"))
        #expect(!changelog.contains(".themedStaticBackground()"))
    }

    @Test("URL forms reveal only their isolated theme surface")
    func themedURLForms() throws {
        let source = try sourceFile(
            "Sodalite/Features/Settings/DualURLEditSheet.swift"
        )
        #expect(source.contains("ThemeNavigationStack {"))
        #expect(source.contains(".scrollContentBackground(.hidden)"))
        #expect(source.contains(".themedPresentationBackground()"))
    }

    @Test("auth roots inherit one selected theme surface")
    func authSurfaceOwnership() throws {
        let router = try sourceFile("Sodalite/App/AppRouter.swift")
        let discovery = try sourceFile("Sodalite/Features/Auth/ServerDiscoveryView.swift")
        let launchPicker = try sourceFile("Sodalite/Features/Auth/LaunchProfilePickerView.swift")

        #expect(router.contains(".themedRootBackground()"))
        #expect(discovery.contains("ThemeNavigationPathStack(path: $path)"))
        #expect(launchPicker.contains("ThemeNavigationStack {"))

        for path in [
            "Sodalite/Features/Auth/ServerDiscoveryView.swift",
            "Sodalite/Features/Auth/LaunchProfilePickerView.swift",
            "Sodalite/Features/Auth/UserPickerView.swift",
            "Sodalite/Features/Auth/ServerAddressEntryView.swift",
            "Sodalite/Features/Auth/LoginView.swift"
        ] {
            let source = try sourceFile(path)
            #expect(!source.contains(".glassBackground()"))
        }
    }

    @Test("auth covers own isolated presentation surfaces")
    func authPresentationOwnership() throws {
        let router = try sourceFile("Sodalite/App/AppRouter.swift")
        let launchPicker = try sourceFile("Sodalite/Features/Auth/LaunchProfilePickerView.swift")
        let switchSheet = try sourceFile("Sodalite/Features/Auth/ServerSwitchSheet.swift")

        #expect(router.contains("context: .reprompt"))
        #expect(router.contains(".themedPresentationBackground()"))
        #expect(launchPicker.contains("ServerDiscoveryView(addMode: true)"))
        #expect(launchPicker.contains(".themedPresentationBackground()"))
        #expect(switchSheet.contains(".themedPresentationBackground()"))
    }

    @Test("second URL form owns an isolated theme surface")
    func themedSecondURLForm() throws {
        let source = try sourceFile(
            "Sodalite/Features/Auth/AddSecondURLSheet.swift"
        )
        #expect(source.contains("ThemeNavigationStack {"))
        #expect(source.contains(".scrollContentBackground(.hidden)"))
        #expect(source.contains(".themedPresentationBackground()"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repository.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
