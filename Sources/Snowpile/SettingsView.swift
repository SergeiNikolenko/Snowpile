import AppKit
import ApplicationServices
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var updater: Updater
    @ObservedObject var weather: WeatherModel
    @State private var dockAllowed = AXIsProcessTrusted()
    @State private var choosingPlace = false
    @State private var showsWeatherKey = false
    private let screens = NSScreen.screens

    var body: some View {
        TabView {
            effectSettings.tabItem { Text("Effects") }
            generalSettings.tabItem { Text("General") }
        }
        .padding(16)
        .frame(width: 460, height: 370)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            dockAllowed = AXIsProcessTrusted()
        }
    }

    private var effectSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    Text("Effect").gridColumnAlignment(.trailing)
                    HStack {
                        Picker("Effect", selection: $preferences.selection) {
                            Text("Like Outside").tag("weather")
                            Divider()
                            ForEach(SnowMode.allCases) { mode in
                                Text(mode == .custom ? "Custom Snow" : mode.title).tag("snow:" + mode.rawValue)
                            }
                            Divider()
                            ForEach(Effect.allCases.filter { $0 != .snow }, id: \.self) { effect in
                                Text(effect.title).tag(effect.rawValue)
                            }
                        }
                        .labelsHidden()
                        Toggle("Enable effects", isOn: $preferences.snowing)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
                if preferences.followWeather {
                    GridRow {
                        Text("City")
                        Button(preferences.place.name) { choosingPlace = true }
                            .popover(isPresented: $choosingPlace, arrowEdge: .trailing) {
                                PlacePicker { place in
                                    preferences.place = place
                                    choosingPlace = false
                                }
                            }
                    }
                    GridRow {
                        Text("Weather")
                        if let now = weather.conditions {
                            Text(now.summary)
                        } else {
                            Text(weather.failed ? "Could not update" : "Updating…")
                        }
                    }
                } else if preferences.effect != .snow || preferences.mode == .custom {
                    GridRow {
                        Text("Intensity")
                        Slider(value: $preferences.intensity, in: 0.3...3).accessibilityLabel("Intensity")
                    }
                    if preferences.effect != .starfall {
                        GridRow {
                            Text("Wind")
                            Slider(value: $preferences.wind, in: 0...2.5).accessibilityLabel("Wind")
                        }
                    }
                }
            }
            Divider()
            if preferences.followWeather || [.snow, .rain, .sakura, .leaves].contains(preferences.effect) {
                HStack(spacing: 14) {
                    Text("Settle on")
                    Toggle("Windows", isOn: $preferences.onWindows)
                    Toggle("Dock", isOn: $preferences.onDock).disabled(!dockAllowed)
                        .help("Allow Accessibility in General to use the Dock.")
                    Toggle("Floor", isOn: $preferences.onFloor)
                }
            }
            Toggle("Interact with pointer", isOn: $preferences.pointer)
            Spacer(minLength: 0)
        }
        .toggleStyle(.checkbox)
        .padding(20)
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
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
            Toggle("Open at login", isOn: Binding(get: { preferences.opensAtLogin }, set: preferences.setOpensAtLogin))
            Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
            if !dockAllowed {
                Button("Allow Accessibility…") {
                    let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                    dockAllowed = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
                }
            }
            DisclosureGroup("Yandex Weather", isExpanded: $showsWeatherKey) {
                SecureField("API key", text: $preferences.yandexKey)
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
            HStack {
                Text("Version \(Updater.currentVersion)")
                Spacer()
                Button("Check for Updates…") { updater.checkNow() }.disabled(!updater.canCheck)
            }
        }
        .toggleStyle(.checkbox)
        .padding(20)
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
