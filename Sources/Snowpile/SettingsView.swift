import AppKit
import ApplicationServices
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var updater: Updater
    @ObservedObject var weather: WeatherModel
    @State private var dockAllowed = AXIsProcessTrusted()
    @State private var choosingPlace = false
    private let screens = NSScreen.screens

    var body: some View {
        Form {
            Section {
                Toggle("Snow", isOn: $preferences.snowing)
                Picker("Snowfall", selection: $preferences.followWeather) {
                    Text("Always").tag(false)
                    Text("Like Outside").tag(true)
                }
                .pickerStyle(.segmented)
                if preferences.followWeather {
                    LabeledContent("Region") {
                        Button(preferences.place.name) { choosingPlace = true }
                            .popover(isPresented: $choosingPlace, arrowEdge: .trailing) {
                                PlacePicker { place in
                                    preferences.place = place
                                    choosingPlace = false
                                }
                            }
                    }
                    if let now = weather.conditions {
                        LabeledContent("Now", value: describe(now))
                    } else if weather.failed {
                        LabeledContent("Now", value: preferences.yandexKey.isEmpty ? "No connection" : "Key not accepted")
                    }
                    TextField("Yandex Weather Key", text: $preferences.yandexKey, prompt: Text("Paste key"))
                } else {
                    Slider(value: $preferences.intensity, in: 0.3...3) { Text("Intensity") }
                    Slider(value: $preferences.wind, in: 0...2.5) { Text("Wind") }
                }
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
        .animation(.default, value: preferences.followWeather)
        .frame(width: 400)
        .fixedSize()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            dockAllowed = AXIsProcessTrusted()
        }
    }

    private func describe(_ now: Conditions) -> String {
        let temperature = now.temperature.formatted(.number.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false)))
        let sky = now.snow == 0 ? "no snow" : now.snow < 0.4 ? "light snow" : now.snow < 0.75 ? "snow" : "heavy snow"
        return "\(temperature)°, \(sky)"
    }
}

private struct PlacePicker: View {
    let pick: (Place) -> Void
    @State private var text = ""
    @State private var places: [Place] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("City", text: $text)
                .textFieldStyle(.roundedBorder)
            ForEach(places) { place in
                Button { pick(place) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(place.name)
                        if !place.detail.isEmpty {
                            Text(place.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 260)
        .task(id: text) {
            let query = text.trimmingCharacters(in: .whitespaces)
            guard query.count >= 2 else { places = []; return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            places = (try? await Weather.search(query)) ?? []
        }
    }
}
