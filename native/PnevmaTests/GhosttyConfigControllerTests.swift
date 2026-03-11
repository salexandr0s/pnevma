import XCTest
@testable import Pnevma

@MainActor
final class GhosttyConfigControllerTests: XCTestCase {
    func testLoadKeybindsIncludesMainConfigAndManagedFile() {
        let configText = """
        font-size = 12
        # >>> pnevma managed include >>>
        config-file = "?/tmp/pnevma-ui.generated.ghostty"
        # <<< pnevma managed include <<<
        keybind = cmd+d=new_split:right
        keybind = global:ctrl+grave_accent=toggle_quick_terminal
        """

        let managedText = """
        # Managed by Pnevma.
        keybind = "cmd+t=new_tab"
        """

        let keybinds = GhosttyConfigController.loadKeybinds(
            configText: configText,
            managedText: managedText
        )

        XCTAssertEqual(
            keybinds.map(\.rawBinding),
            [
                "cmd+d=new_split:right",
                "global:ctrl+grave_accent=toggle_quick_terminal",
                "cmd+t=new_tab",
            ]
        )
    }

    func testLoadKeybindsIgnoresInactiveManagedFile() {
        let configText = """
        keybind = cmd+d=new_split:right
        """

        let managedText = """
        keybind = "cmd+t=new_tab"
        """

        let keybinds = GhosttyConfigController.loadKeybinds(
            configText: configText,
            managedText: managedText
        )

        XCTAssertEqual(keybinds.map(\.rawBinding), ["cmd+d=new_split:right"])
    }

    func testDefaultConfigPathUsesCanonicalGhosttyFilename() {
        let homeDirectory = URL(fileURLWithPath: "/tmp/pnevma-tests-home", isDirectory: true)

        let path = GhosttyConfigController.defaultConfigPath(homeDirectory: homeDirectory)

        XCTAssertEqual(path.path, "/tmp/pnevma-tests-home/.config/ghostty/config")
    }

    func testManualKeysCanonicalizeDeprecatedGhosttyAliases() {
        let configText = """
        background-blur-radius = 20
        font-size = 12
        """

        let keys = GhosttyManagedConfigCodec.manualKeys(from: configText)

        XCTAssertEqual(keys, ["background-blur", "font-size"])
    }

    func testParseManagedFileCanonicalizesDeprecatedGhosttyAliases() {
        let configText = """
        background-blur-radius = 20
        """

        let parsed = GhosttyManagedConfigCodec.parseManagedFile(configText)

        XCTAssertEqual(parsed.values["background-blur"], ["20"])
        XCTAssertNil(parsed.values["background-blur-radius"])
    }

    func testLoadEditableDraftUsesMainConfigWhenIncludeInactive() {
        let configText = """
        font-size = 12
        keybind = cmd+d=new_split:right
        """

        let managedText = """
        font-size = 18
        keybind = "cmd+t=new_tab"
        """

        let draft = GhosttyConfigController.loadEditableDraft(
            configText: configText,
            managedText: managedText
        )

        XCTAssertFalse(draft.includeIntegrated)
        XCTAssertEqual(draft.values["font-size"], ["12"])
        XCTAssertEqual(draft.keybinds.map(\.rawBinding), ["cmd+d=new_split:right"])
    }

    func testLoadEditableDraftFlattensManagedIncludeIntoEditableValues() {
        let configText = """
        font-size = 12
        keybind = cmd+d=new_split:right
        # >>> pnevma managed include >>>
        config-file = "?/tmp/pnevma-ui.generated.ghostty"
        # <<< pnevma managed include <<<
        """

        let managedText = """
        font-size = 18
        theme = Ayu
        keybind = "cmd+t=new_tab"
        """

        let draft = GhosttyConfigController.loadEditableDraft(
            configText: configText,
            managedText: managedText
        )

        XCTAssertTrue(draft.includeIntegrated)
        XCTAssertEqual(draft.values["font-size"], ["18"])
        XCTAssertEqual(draft.values["theme"], ["Ayu"])
        XCTAssertEqual(draft.previewText, managedText)
        XCTAssertEqual(
            draft.keybinds.map(\.rawBinding),
            ["cmd+d=new_split:right", "cmd+t=new_tab"]
        )
    }

    func testLoadEffectiveFileValuesIgnoresInactiveManagedFile() {
        let configText = """
        theme = Ayu
        """

        let managedText = """
        theme = Dracula
        """

        let values = GhosttyConfigController.loadEffectiveFileValues(
            configText: configText,
            managedText: managedText
        )

        XCTAssertEqual(values["theme"], "Ayu")
    }

    func testLoadEffectiveFileValuesUsesManagedFileWhenIncludeActive() {
        let configText = """
        theme = Ayu
        # >>> pnevma managed include >>>
        config-file = "?/tmp/pnevma-ui.generated.ghostty"
        # <<< pnevma managed include <<<
        """

        let managedText = """
        theme = Dracula
        """

        let values = GhosttyConfigController.loadEffectiveFileValues(
            configText: configText,
            managedText: managedText
        )

        XCTAssertEqual(values["theme"], "Dracula")
    }

    func testBuildSavePlanPreservesManagedIncludeConfigs() {
        let configText = """
        theme = Ayu
        # >>> pnevma managed include >>>
        config-file = "?/tmp/pnevma-ui.generated.ghostty"
        # <<< pnevma managed include <<<
        """

        let plan = GhosttyConfigController.buildSavePlan(
            configText: configText,
            managedText: "theme = Dracula\n",
            values: ["theme": ["Nord"]],
            keybinds: [GhosttyManagedKeybind(trigger: "cmd+t", action: "new_tab")]
        )

        XCTAssertEqual(plan.configText, configText)
        XCTAssertEqual(
            plan.managedText,
            """
            # Managed by Pnevma.
            # Edit Ghostty settings in Pnevma to update this file.

            theme = Nord

            keybind = "cmd+t=new_tab"
            """ + "\n"
        )
    }

    func testBuildSavePlanUpdatesMainConfigWhenIncludeInactive() {
        let configText = """
        theme = Ayu
        keybind = cmd+d=new_split:right
        """

        let plan = GhosttyConfigController.buildSavePlan(
            configText: configText,
            managedText: "",
            values: ["theme": ["Nord"]],
            keybinds: [GhosttyManagedKeybind(trigger: "cmd+t", action: "new_tab")]
        )

        XCTAssertNil(plan.managedText)
        XCTAssertEqual(
            plan.configText,
            """
            theme = Nord

            keybind = cmd+t=new_tab
            """ + "\n"
        )
    }
}
