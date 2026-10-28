import AppKit
import SwiftUI

/// The main menu while a Hearsay window makes the app `.regular` (`AppWindows`). SwiftUI supplies the
/// Hearsay menu (About, Settings… ⌘,, Hide, Quit ⌘Q), File's Close ⌘W, Edit and Window.
struct MainMenuCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if Updater.available { Button("Check for Updates…") { Updater.checkForUpdates() } }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Recording") {
                MainWindowController.shared.show()
                MainWindowModel.startRecording()
            }
            .keyboardShortcut("n")
            .disabled(model.isRecording)
            Divider()
            Button("Confirm Names…") { ConfirmNamesWindowController.shared.show() }
            Button("Open Meetings Folder") { NSWorkspace.shared.open(model.store.root) }
        }
        CommandGroup(after: .textEditing) {
            Button("Find Meetings") {
                MainWindowController.shared.show()
                NotificationCenter.default.post(name: .hearsayFindMeetings, object: nil)
            }
            .keyboardShortcut("f")
        }
        SidebarCommands()
        CommandGroup(after: .sidebar) {
            Button("Live Transcript") { MainWindowController.shared.showRecording() }
                .disabled(!model.isRecording)
        }
        CommandGroup(replacing: .help) {
            Button("Hearsay Help") { NSWorkspace.shared.open(MenuContent.helpURL) }
        }
    }
}
