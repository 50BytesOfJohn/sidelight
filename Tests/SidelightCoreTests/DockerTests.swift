import Foundation
import Testing

@testable import SidelightCore

struct DockerContainerTests {
    /// As `docker container inspect` prints ``DockerCLI/inspectTemplate`` in CLI 29.8.2: a Compose service with a
    /// healthcheck and IPv4/IPv6 bindings, and a never-started container with no healthcheck or published port.
    static let inspect = """
        {"id":"a1b2c3d4e5f60718293a4b5c6d7e8f9010111213141516171819202122232425","name":"/shop-api-1","image":"shop-api:dev","state":{"Status":"running","Running":true,"Paused":false,"Restarting":false,"OOMKilled":false,"Dead":false,"Pid":4242,"ExitCode":0,"Error":"","StartedAt":"2026-10-16T08:15:02.123456789Z","FinishedAt":"0001-01-01T00:00:00Z","Health":{"Status":"healthy","FailingStreak":0,"Log":[]}},"restartCount":2,"labels":{"com.docker.compose.project":"shop","com.docker.compose.service":"api","org.example.note":"a, b, c"},"ports":{"8080/tcp":[{"HostIp":"0.0.0.0","HostPort":"8080"},{"HostIp":"::","HostPort":"8080"}],"9229/tcp":null,"53/udp":[{"HostIp":"127.0.0.1","HostPort":"5353"}],"3000/tcp":[{"HostIp":"0.0.0.0","HostPort":"3001"},{"HostIp":"::","HostPort":"3001"}]}}
        {"id":"ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100","name":"/scratchpad","image":"alpine","state":{"Status":"created","Running":false,"ExitCode":0,"StartedAt":"0001-01-01T00:00:00Z","FinishedAt":"0001-01-01T00:00:00Z"},"restartCount":0,"labels":{},"ports":{}}
        """

    @Test func `reads each container inspect prints`() throws {
        let containers = DockerContainer.list(inspectOutput: Data(Self.inspect.utf8))
        #expect(containers.count == 2)
        let api = try #require(containers.first)
        #expect(api.name == "shop-api-1")
        #expect(api.displayName == "api")
        #expect(api.shortID == "a1b2c3d4e5f6")
        #expect(api.image == "shop-api:dev")
        #expect(api.state == .running)
        #expect(api.health == .healthy)
        #expect(api.restartCount == 2)
        #expect(api.project == "shop")
        #expect(api.service == "api")
        #expect(api.finishedAt == nil)
        let started = try #require(api.startedAt)
        #expect(abs(started.timeIntervalSince(try #require(Date(iso8601: "2026-10-16T08:15:02Z")))) < 1)
        // Unpublished ports are left out; each IPv4/IPv6 pair shows once, by host port.
        #expect(
            api.ports == [
                DockerPort(hostPort: 3001, containerPort: 3000),
                DockerPort(hostPort: 5353, containerPort: 53, transport: "udp", hostIP: "127.0.0.1"),
                DockerPort(hostPort: 8080, containerPort: 8080),
            ])
        #expect(api.ports[0].label == ":3001→3000")
        #expect(api.ports[2].label == ":8080")
        #expect(api.ports[0].browserURL == URL(string: "http://localhost:3001"))
        #expect(api.ports[1].browserURL == nil)

        let scratch = containers[1]
        #expect(scratch.state == .created)
        #expect(scratch.health == .none)
        #expect(scratch.startedAt == nil)
        #expect(scratch.project == nil && scratch.displayName == "scratchpad")
        #expect(scratch.ports.isEmpty)
    }

    @Test func `skips lines it can't read and keeps the rest`() {
        let output = "not json\n{\"name\":\"/no-id\"}\n" + Self.inspect + "\n{\"id\":\"abc\",\"state\":42}\n"
        let containers = DockerContainer.list(inspectOutput: Data(output.utf8))
        #expect(containers.map(\.shortID) == ["a1b2c3d4e5f6", "ffeeddccbbaa", "abc"])
        #expect(containers[2].state == .other(""))
    }

    @Test func `empty output is no containers`() {
        #expect(DockerContainer.list(inspectOutput: Data()).isEmpty)
    }
}

struct DockerConditionTests {
    static func container(
        _ state: DockerContainer.State, health: DockerContainer.Health = .none, exitCode: Int = 0
    ) -> DockerContainer {
        DockerContainer(id: "x", name: "x", state: state, health: health, exitCode: exitCode)
    }

    @Test(arguments: [
        (DockerContainer.State.running, DockerContainer.Health.none, 0, DockerCondition.running, false, true),
        (.running, .healthy, 0, .healthy, false, true),
        (.running, .starting, 0, .starting, false, true),
        (.running, .unhealthy, 0, .unhealthy, true, true),
        (.restarting, .none, 1, .restarting, true, true),
        (.paused, .none, 0, .paused, false, true),
        (.created, .none, 0, .created, false, false),
        (.exited, .none, 0, .exited(code: 0), false, false),
        (.exited, .none, 1, .exited(code: 1), false, false),
        (.dead, .none, 0, .dead, true, true),
        (.removing, .none, 0, .removing, false, false),
        (.other("weird"), .none, 0, .other("weird"), false, false),
    ])
    func `each state reads as a condition`(
        state: DockerContainer.State, health: DockerContainer.Health, exitCode: Int, expected: DockerCondition,
        isIssue: Bool, isActive: Bool
    ) {
        let condition = DockerCondition(Self.container(state, health: health, exitCode: exitCode))
        #expect(condition == expected)
        #expect(condition.isIssue == isIssue)
        #expect(condition.isActive == isActive)
    }

    @Test func `crashed is an issue and active`() {
        #expect(DockerCondition.crashed(code: 1).isIssue)
        #expect(DockerCondition.crashed(code: 1).isActive)
        #expect(DockerCondition.crashed(code: 1).issueTitle == "crashed")
    }
}

struct DockerSnapshotTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    static func running(
        _ id: String, project: String? = "shop", service: String? = nil, health: DockerContainer.Health = .none,
        startedMinutesAgo: Double = 60, ports: [DockerPort] = [], image: String = "img"
    ) -> DockerContainer {
        DockerContainer(
            id: id, name: id, image: image, state: .running, health: health, startedAt: ago(startedMinutesAgo),
            project: project, service: service ?? (project == nil ? nil : id), ports: ports)
    }

    static func exited(
        _ id: String, project: String? = "shop", code: Int, finishedMinutesAgo: Double
    ) -> DockerContainer {
        DockerContainer(
            id: id, name: id, state: .exited, startedAt: ago(finishedMinutesAgo + 5),
            finishedAt: ago(finishedMinutesAgo), exitCode: code, project: project, service: id)
    }

    @Test func `an error exit after its running siblings started is a crash`() {
        let worker = Self.exited("worker", code: 1, finishedMinutesAgo: 10)
        let snapshot = DockerSnapshot(containers: [Self.running("web"), worker], fetchedAt: Self.now)
        #expect(snapshot.condition(of: worker) == .crashed(code: 1))
    }

    @Test(arguments: [0, 130, 137, 143])
    func `a clean exit, Ctrl-C, kill or stop isn't a crash`(code: Int) {
        let worker = Self.exited("worker", code: code, finishedMinutesAgo: 10)
        let snapshot = DockerSnapshot(containers: [Self.running("web"), worker], fetchedAt: Self.now)
        #expect(snapshot.condition(of: worker) == .exited(code: code))
    }

    @Test func `running out of memory is a crash, even as exit 137`() {
        var worker = Self.exited("worker", code: 137, finishedMinutesAgo: 10)
        worker.oomKilled = true
        let snapshot = DockerSnapshot(containers: [Self.running("web"), worker], fetchedAt: Self.now)
        #expect(snapshot.condition(of: worker) == .crashed(code: 137))
    }

    @Test func `a leftover from before its siblings started isn't a crash`() {
        let worker = Self.exited("worker", code: 1, finishedMinutesAgo: 90)
        let snapshot = DockerSnapshot(
            containers: [Self.running("web", startedMinutesAgo: 60), worker], fetchedAt: Self.now)
        #expect(snapshot.condition(of: worker) == .exited(code: 1))
    }

    @Test func `nothing is flagged when Docker itself quit`() {
        let containers = ["web", "api", "db"].map { Self.exited($0, code: 255, finishedMinutesAgo: 2) }
        let snapshot = DockerSnapshot(containers: containers, fetchedAt: Self.now)
        #expect(containers.allSatisfy { snapshot.condition(of: $0) == .exited(code: 255) })
        #expect(snapshot.summary.headline == "None running")
    }

    @Test func `an error exit outside a project isn't a crash`() {
        let job = Self.exited("job", project: nil, code: 1, finishedMinutesAgo: 1)
        let snapshot = DockerSnapshot(containers: [Self.running("web", project: nil), job], fetchedAt: Self.now)
        #expect(snapshot.condition(of: job) == .exited(code: 1))
    }

    @Test func `groups put issues first, then projects A to Z, then standalone, then inactive`() {
        let snapshot = DockerSnapshot(
            containers: [
                Self.running("minio", project: nil),
                Self.running("b-web", project: "beta"),
                Self.running("a-web", project: "alpha"),
                Self.running("z-api", project: "zeta", health: .unhealthy),
                Self.running("z-web", project: "zeta"),
                Self.exited("old", project: "old", code: 0, finishedMinutesAgo: 600),
            ], fetchedAt: Self.now)
        #expect(snapshot.groups(scope: .active).map(\.project) == ["zeta", "alpha", "beta", nil])
        #expect(snapshot.groups(scope: .all).map(\.project) == ["zeta", "alpha", "beta", nil, "old"])
        let zeta = snapshot.groups(scope: .active)[0]
        #expect(zeta.worst == .unhealthy)
        #expect(zeta.runningCount == 2)
        #expect(zeta.containers.map(\.id) == ["z-api", "z-web"])
        #expect(zeta.issues.map(\.id) == ["z-api"])
        #expect(snapshot.groups(scope: .active)[3].title == "Other containers")
        #expect(!snapshot.groups(scope: .all)[4].isActive)
    }

    @Test func `starting beats running in a group's worst`() {
        let snapshot = DockerSnapshot(
            containers: [Self.running("a", health: .healthy), Self.running("b", health: .starting)],
            fetchedAt: Self.now)
        #expect(snapshot.groups(scope: .active)[0].worst == .starting)
    }

    @Test func `a group's ports are its running containers', by host port and transport`() {
        let snapshot = DockerSnapshot(
            containers: [
                Self.running("web", ports: [DockerPort(hostPort: 3000, containerPort: 3000)]),
                Self.running("db", ports: [DockerPort(hostPort: 5432, containerPort: 5432)]),
                Self.running(
                    "dns",
                    ports: [
                        DockerPort(hostPort: 53, containerPort: 53, transport: "udp"),
                        DockerPort(hostPort: 53, containerPort: 53),
                    ]),
                DockerContainer(
                    id: "stopped", name: "stopped", state: .exited, project: "shop",
                    ports: [DockerPort(hostPort: 1234, containerPort: 1234)]),
            ], fetchedAt: Self.now)
        let ports = snapshot.groups(scope: .all)[0].ports
        #expect(ports.map(\.hostPort) == [53, 53, 3000, 5432])
        #expect(ports.map(\.transport) == ["tcp", "udp", "tcp", "tcp"])
    }

    @Test func `search matches name, service, project, image and port`() {
        let snapshot = DockerSnapshot(
            containers: [
                Self.running(
                    "café-1", project: "Storefront", service: "api",
                    ports: [DockerPort(hostPort: 8080, containerPort: 80)],
                    image: "ghcr.io/acme/api"),
                Self.running("other", project: "misc", service: "db", image: "postgres"),
            ], fetchedAt: Self.now)
        func found(_ text: String) -> [String] {
            snapshot.groups(scope: .all, search: DockerSearch(text)).flatMap(\.containers).map(\.id)
        }
        #expect(found("CAFE") == ["café-1"])
        #expect(found("API") == ["café-1"])
        #expect(found("storefront") == ["café-1"])
        #expect(found("acme") == ["café-1"])
        #expect(found("8080") == ["café-1"])
        #expect(found(":80") == ["café-1"])
        #expect(found("postgres") == ["other"])
        #expect(found("nothing").isEmpty)
        #expect(found("").count == 2)
    }

    @Test func `headlines count what runs and name the issues`() {
        func headline(_ containers: [DockerContainer]) -> String {
            DockerSnapshot(containers: containers, fetchedAt: Self.now).summary.headline
        }
        #expect(headline([]) == "None running")
        #expect(headline((1...6).map { Self.running("c\($0)") }) == "6 running")
        #expect(headline([Self.running("a"), Self.running("b", health: .unhealthy)]) == "2 running · 1 unhealthy")
        #expect(
            headline([Self.running("a", health: .unhealthy), Self.running("b", health: .unhealthy)])
                == "2 running · 2 unhealthy")
        #expect(
            headline([
                Self.running("a", health: .unhealthy), Self.running("b"),
                Self.exited("c", code: 1, finishedMinutesAgo: 1),
            ]) == "2 running · 2 issues")
        let summary = DockerSnapshot(
            containers: [Self.running("a"), Self.exited("b", code: 0, finishedMinutesAgo: 1)], fetchedAt: Self.now
        ).summary
        #expect(summary.running == 1 && summary.stopped == 1 && summary.issueText == nil)
    }

    @Test func `the sample has an unhealthy storefront`() {
        let sample = DockerSnapshot.sample(at: Self.now)
        #expect(sample.summary.headline == "5 running · 1 unhealthy")
        #expect(sample.groups(scope: .active).first?.project == "storefront")
    }
}

struct DockerCLITests {
    @Test func `a named context goes in front, the current one adds nothing`() {
        #expect(DockerCLI.arguments(DockerCLI.listIDs, context: .current) == ["ps", "-aq", "--no-trunc"])
        #expect(
            DockerCLI.arguments(DockerCLI.listIDs, context: .named("orbstack"))
                == ["--context", "orbstack", "ps", "-aq", "--no-trunc"])
    }

    @Test func `events watch health and leave out exec`() {
        let arguments = DockerCLI.events(since: Date(timeIntervalSince1970: 1_800_000_000.9))
        #expect(arguments.contains("event=health_status"))
        #expect(arguments.contains("event=die"))
        #expect(!arguments.contains { $0.contains("exec_") })
        #expect(arguments.suffix(2) == ["--since", "1800000000"])
        #expect(arguments.contains("type=container"))
    }

    @Test func `inspect embeds the state whole, never its health`() {
        let arguments = DockerCLI.inspect(["a", "b"])
        #expect(arguments.suffix(2) == ["a", "b"])
        #expect(DockerCLI.inspectTemplate.contains("{{json .State}}"))
        #expect(!DockerCLI.inspectTemplate.contains(".State.Health"))
        #expect(!DockerCLI.inspectTemplate.contains("Env"))
    }

    @Test func `reads contexts`() {
        let output = """
            {"Current":false,"Description":"Docker Desktop","DockerEndpoint":"unix:///Users/example/.docker/run/docker.sock","Error":"","Name":"desktop-linux"}
            {"Current":true,"Description":"OrbStack","DockerEndpoint":"unix:///Users/example/.orbstack/run/docker.sock","Error":"","Name":"orbstack"}
            {"Current":false,"Description":"","DockerEndpoint":"ssh://builder","Error":"","Name":"remote"}
            {"Current":false,"Description":"","DockerEndpoint":"","Error":"context not readable","Name":"colima-work"}
            nonsense
            """
        let contexts = DockerContext.list(output: Data(output.utf8))
        #expect(contexts.map(\.name) == ["desktop-linux", "orbstack", "remote", "colima-work"])
        #expect(contexts.map(\.displayName) == ["Docker Desktop", "OrbStack", "remote", "Colima"])
        #expect(contexts.map(\.isCurrent) == [false, true, false, false])
        #expect(contexts[3].error == "context not readable")
        #expect(contexts[0].error == nil)
        #expect(contexts[0].socketURL?.path == "/Users/example/.docker/run/docker.sock")
        #expect(contexts[2].socketURL == nil)
        #expect(contexts[3].socketURL == nil)
        #expect(DockerContext(name: "colima").displayName == "Colima")
    }

    @Test func `reads stats in every unit`() {
        let output = """
            {"id":"a","cpu":"0.54%","mem":"18.99MiB / 3.825GiB","memPerc":"0.48%"}
            {"id":"b","cpu":"120.3%","mem":"1.5GiB / 8GiB","memPerc":"18.75%"}
            {"id":"c","cpu":"--","mem":"-- / --","memPerc":"--"}
            {"id":"d","cpu":"1%","mem":"512KiB / 1GiB","memPerc":"0%"}
            {"id":"e","cpu":"1%","mem":"2kB / 1GB","memPerc":"0%"}
            {"id":"f","cpu":"1%","mem":"3MB / 1GB","memPerc":"0%"}
            {"id":"g","cpu":"1%","mem":"1.5GB / 2GB","memPerc":"0%"}
            {"id":"h","cpu":"1%","mem":"100B / 2GB","memPerc":"0%"}
            """
        let stats = DockerStats.list(output: Data(output.utf8))
        #expect(stats["a"]?.cpuPercent == 0.54)
        #expect(stats["a"]?.memoryBytes == Int64(18.99 * 1_048_576))
        #expect(stats["a"]?.memoryPercent == 0.48)
        #expect(stats["b"]?.memoryBytes == Int64(1.5 * 1_073_741_824))
        #expect(stats["c"] == DockerStats())
        #expect(stats["d"]?.memoryBytes == Int64(512 * 1024))
        #expect(stats["e"]?.memoryBytes == 2000)
        #expect(stats["f"]?.memoryBytes == 3_000_000)
        #expect(stats["g"]?.memoryBytes == 1_500_000_000)
        #expect(stats["h"]?.memoryBytes == 100)
    }

    @Test func `recognises why docker failed`() {
        #expect(
            DockerProblem(
                message:
                    "failed to connect to the docker API at unix:///Users/example/.docker/run/docker.sock; check if the "
                    + "path is correct and if the daemon is running: dial unix …: connect: no such file or directory")
                == .notRunning)
        #expect(
            DockerProblem(
                message:
                    "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?")
                == .notRunning)
        #expect(
            DockerProblem(message: #"error: context "nope": context not found: open /Users/example/.docker/…"#)
                == .contextMissing("nope"))
        #expect(
            DockerProblem(
                message:
                    "permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock"
            )
                == .permissionDenied)
        #expect(DockerProblem(message: "  something odd\nmore  ") == .failed("something odd"))
        #expect(DockerProblem(message: "") == .failed("Docker didn't answer."))
    }
}

struct DockerSettingsTests {
    @Test func `missing options take their defaults`() throws {
        let settings = try JSONDecoder().decode(DockerSettings.self, from: Data("{}".utf8))
        #expect(settings == DockerSettings())
        #expect(settings.contextChoice == .current)
    }

    @Test func `hand-edited values are kept in range or dropped`() throws {
        let settings = try JSONDecoder().decode(
            DockerSettings.self,
            from: Data(#"{"rowCount": 99, "context": 7, "showsStopped": "yes", "showsPorts": 0}"#.utf8))
        #expect(settings.rowCount == 10)
        #expect(settings.context == nil)
        #expect(!settings.showsStopped)
        #expect(settings.showsPorts)
    }

    @Test func `round trips`() throws {
        let settings = DockerSettings(context: "orbstack", showsStopped: true, rowCount: 8, showsPorts: false)
        let decoded = try JSONDecoder().decode(DockerSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.contextChoice == .named("orbstack"))
    }
}

struct DockerDemandTests {
    static func configuration(_ widgets: [WidgetInstance]) -> AppConfiguration {
        var configuration = AppConfiguration()
        configuration.sections = [PanelSection(widgets: widgets)]
        return configuration
    }

    @Test func `a visible widget needs its context, a hidden one nothing`() {
        let shown = WidgetInstance(settings: .docker(DockerSettings(context: "orbstack")))
        let hidden = WidgetInstance(
            settings: .docker(DockerSettings()), showsInSidePanel: false, showsInBar: false)
        let configuration = Self.configuration([shown, hidden])
        #expect(configuration.serviceDemand(at: [.right]).docker.contexts == [.named("orbstack")])
        #expect(Self.configuration([hidden]).serviceDemand(at: [.right]).docker.isEmpty)
    }

    @Test func `previewing every widget runs nothing until one is placed`() {
        let empty = Self.configuration([WidgetInstance(kind: .clock)])
        #expect(empty.serviceDemand(at: [.right], previewsEveryWidget: true).docker.isEmpty)
        let placed = Self.configuration([
            WidgetInstance(settings: .docker(DockerSettings()), showsInSidePanel: false, showsInBar: false)
        ])
        #expect(placed.serviceDemand(at: [.right], previewsEveryWidget: true).docker.contexts == [.current])
    }

    @Test func `limiting to other kinds drops it`() {
        let configuration = Self.configuration([WidgetInstance(kind: .docker)])
        let demand = configuration.serviceDemand(at: [.right])
        #expect(!demand.docker.isEmpty)
        #expect(demand.limited(to: [.clock]).docker.isEmpty)
        #expect(!demand.limited(to: [.docker]).docker.isEmpty)
    }

    @Test func `merging unions contexts and takes stats`() {
        var demand = DockerDemand(contexts: [.current])
        demand.merge(DockerDemand(contexts: [], stats: .named("orbstack")))
        #expect(demand.contexts == [.current, .named("orbstack")])
        #expect(demand.stats == .named("orbstack"))
        demand.merge(DockerDemand())
        #expect(demand.stats == .named("orbstack"))
    }
}
