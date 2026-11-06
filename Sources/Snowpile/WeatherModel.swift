import Foundation

/// Keeps the current conditions for the chosen place, refreshed every 15 minutes while snow follows the weather.
@MainActor
final class WeatherModel: ObservableObject {
    @Published private(set) var conditions: Conditions?
    @Published private(set) var failed = false
    var onChange: () -> Void = {}
    private var task: Task<Void, Never>?
    private var watched: (Place, String)?

    func follow(_ place: Place?, yandexKey: String) {
        guard let place else {
            task?.cancel()
            task = nil
            watched = nil
            return
        }
        if let watched, watched.0 == place, watched.1 == yandexKey, task != nil { return }
        watched = (place, yandexKey)
        conditions = nil
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let now = try await Weather.conditions(at: place, yandexKey: yandexKey)
                    self?.conditions = now
                    self?.failed = false
                } catch {
                    if Task.isCancelled { return }
                    self?.failed = true
                }
                self?.onChange()
                try? await Task.sleep(nanoseconds: (self?.failed == true ? 120 : 900) * 1_000_000_000)
            }
        }
    }
}
