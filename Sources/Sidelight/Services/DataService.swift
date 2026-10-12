/// A service that reads, watches or fetches only while something on screen needs it. `AppController` starts and
/// stops each one as widgets come and go, so both must be safe to call any number of times.
///
/// A stopped service keeps what it read last, so showing its widget again shows that right away.
protocol DataService: AnyObject {
    func start()
    func stop()
}

extension DataService {
    /// Starts or stops the service.
    func setRunning(_ isRunning: Bool) {
        if isRunning { start() } else { stop() }
    }
}
