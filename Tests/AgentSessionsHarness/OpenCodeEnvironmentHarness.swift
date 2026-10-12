import Foundation
import SidelightCore

@main
struct OpenCodeEnvironmentHarness {
    static func main() async {
        guard URL.homeDirectory.path.contains("/build/opencode-testing/") else { fatalError("Synthetic home required") }
        guard let expected = CommandLine.arguments.dropFirst().first else { fatalError("Expected location required") }
        let location = OpenCodeSessionsService.location
        let actual: String
        switch location {
        case .file(let url): actual = url.path
        case .inMemory: actual = ":memory:"
        case .dataFolder: actual = ""
        }
        var failures = actual == expected ? 0 : 1
        print("\(actual == expected ? "PASS" : "FAIL") service effective location")
        let service = OpenCodeSessionsService.openCode()
        if service.database == nil {
            service.start()
            service.start()
            let valid = service.hasLoaded && service.availability == .unsupported && service.sessions.isEmpty
            failures += valid ? 0 : 1
            print("\(valid ? "PASS" : "FAIL") unsupported location loads once without vendor initialization")
            service.stop()
            service.stop()
        } else {
            let valid = service.database?.path == expected
            failures += valid ? 0 : 1
            print("\(valid ? "PASS" : "FAIL") file database matches effective location")
        }
        print("RESULT \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
