/// One conformer per tool. Each discovers live sessions and streams
/// status changes into the store.
@MainActor
protocol SessionMonitor {
    func start(into store: SessionStore) async
}
