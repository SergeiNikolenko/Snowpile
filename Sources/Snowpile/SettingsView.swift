import AppKit
import ApplicationServices
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var updater: Updater
    @State private var dockAllowed = AXIsProcessTrusted()
    private let screens = NSScreen.screens

    var body: some View {
        Form {
            Section {
                Toggle("Snow", isOn: $preferences.snowing)
                Slider(value: $preferences.intensity, in: 0.3...3) { Text("Intensity") }
                Slider(value: $preferences.wind, in: 0...2.5) { Text("Wind") }
                if screens.count > 1 {
                    Picker("Displays", selection: $preferences.display) {
                        Text("All Displays").tag(Preferences.allDisplays)
                        Text("Main Display").tag(Preferences.mainDisplay)
                        Divider()
                        ForEach(screens, id: \.self) { screen in
                            Text(screen.localizedName).tag(Preferences.id(of: screen))
                        }
                    }
                }
            }
            Section("Settles On") {
                Toggle("Windows", isOn: $preferences.onWindows)
                if dockAllowed {
                    Toggle("Dock", isOn: $preferences.onDock)
                } else {
                    LabeledContent("Dock") {
                        Button("Allow…") {
                            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                            dockAllowed = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
                        }
                    }
                }
                Toggle("Bottom of Screen", isOn: $preferences.onFloor)
            }
            Section {
                Toggle("Brush Snow with Pointer", isOn: $preferences.pointer)
                Toggle("Open at Login", isOn: Binding(get: { preferences.opensAtLogin }, set: preferences.setOpensAtLogin))
            }
            Section {
                Toggle("Check for Updates Automatically", isOn: $updater.automaticallyChecks)
                LabeledContent("Version \(Updater.currentVersion)") {
                    Button("Check Now") { updater.checkNow() }
                        .disabled(!updater.canCheck)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            dockAllowed = AXIsProcessTrusted()
        }
    }
}
