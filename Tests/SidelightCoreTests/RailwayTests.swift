import Foundation
import Testing

@testable import SidelightCore

struct RailwayTests {
    /// A response to the status query for two workspaces with usage, shaped as Railway's API answers it: the second
    /// workspace isn't visible to the sign-in.
    static let status = """
        {
          "data": {
            "w0": {
              "id": "ws1", "name": "Acme", "plan": "HOBBY",
              "customer": {
                "currentUsage": 9.02,
                "billingPeriod": { "start": "2026-09-23T12:11:38.000Z", "end": "2026-10-23T12:11:38.000Z" },
                "usageLimit": { "softLimit": 15, "hardLimit": 20, "isOverLimit": false }
              },
              "projects": { "edges": [
                { "node": {
                  "id": "p1", "name": "shop", "primaryEnvironmentId": "env-prod", "deletedAt": null,
                  "environments": { "edges": [
                    { "node": { "id": "env-prod", "name": "production", "isEphemeral": false } },
                    { "node": { "id": "env-stg", "name": "staging", "isEphemeral": false } }
                  ] },
                  "services": { "edges": [
                    { "node": { "id": "s1", "name": "API", "icon": null, "serviceInstances": { "edges": [
                      { "node": { "environmentId": "env-prod", "sleepApplication": false, "latestDeployment": {
                        "id": "d1", "status": "SUCCESS", "createdAt": "2026-10-09T07:38:19.231Z",
                        "staticUrl": "api.up.railway.app" } } },
                      { "node": { "environmentId": "env-stg", "sleepApplication": false, "latestDeployment": {
                        "id": "d2", "status": "CRASHED", "createdAt": "2026-10-10T07:38:19.231Z", "staticUrl": null } } }
                    ] } } },
                    { "node": { "id": "s2", "name": "worker", "icon": "https://devicons.railway.com/i/postgresql.svg",
                      "serviceInstances": { "edges": [
                        { "node": { "environmentId": "env-prod", "sleepApplication": true, "latestDeployment": {
                          "id": "d3", "status": "SUCCESS", "createdAt": "2026-10-01T07:38:19Z", "staticUrl": null } } }
                    ] } } },
                    { "node": { "id": "s3", "name": "cron", "icon": null, "serviceInstances": { "edges": [
                      { "node": { "environmentId": "env-prod", "sleepApplication": false, "latestDeployment": {
                        "id": "d4", "status": "BUILDING", "createdAt": "2026-10-10T20:00:00.000Z", "staticUrl": null } } }
                    ] } } }
                  ] }
                } },
                { "node": {
                  "id": "p-deleted", "name": "old", "primaryEnvironmentId": null, "deletedAt": "2026-01-01T00:00:00Z",
                  "environments": { "edges": [] }, "services": { "edges": [] }
                } }
              ] }
            },
            "e0": [
              { "measurement": "MEMORY_USAGE_GB", "estimatedValue": 43200 },
              { "measurement": "CPU_USAGE", "estimatedValue": 21600 }
            ],
            "w1": null
          },
          "errors": [ { "message": "Not Authorized", "path": ["w1"] } ]
        }
        """

    static func snapshot() throws -> Railway.Snapshot {
        let status = try RailwayAPI.status(status: 200, body: Data(status.utf8), workspaceCount: 2).get()
        return Railway.Snapshot(workspaces: status.workspaces, fetchedAt: .now)
    }

    // MARK: Requests

    @Test func `asks for each workspace under its own alias, and for usage only when wanted`() {
        let plain = RailwayAPI.statusQuery(workspaceCount: 2, includesUsage: false)
        #expect(plain.contains("query SidelightStatus($w0: String!, $w1: String!)"))
        #expect(plain.contains("w1: workspace(workspaceId: $w1)"))
        #expect(!plain.contains("customer"))
        #expect(!plain.contains("estimatedUsage"))

        let withUsage = RailwayAPI.statusQuery(workspaceCount: 1, includesUsage: true)
        #expect(withUsage.contains("customer { currentUsage"))
        #expect(withUsage.contains("e0: estimatedUsage(workspaceId: $w0"))
    }

    @Test func `sends the token as a bearer token to Railway's API`() throws {
        let request = RailwayAPI.request(
            RailwayAPI.accountQuery, variables: ["w0": "ws1"], token: "secret", userAgent: "Sidelight/1")
        #expect(request.url == RailwayAPI.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["query"] as? String == RailwayAPI.accountQuery)
        #expect((json["variables"] as? [String: String]) == ["w0": "ws1"])
    }

    // MARK: Responses

    @Test func `reads workspaces, skipping ones the sign-in can't see and deleted projects`() throws {
        let workspaces = try RailwayAPI.status(status: 200, body: Data(Self.status.utf8), workspaceCount: 2).get()
            .workspaces
        #expect(workspaces.map(\.id) == ["ws1"])
        let workspace = workspaces[0]
        #expect(workspace.plan == "HOBBY")
        #expect(workspace.projects.map(\.id) == ["p1"])

        let project = workspace.projects[0]
        #expect(project.environments.map(\.name) == ["production", "staging"])
        #expect(project.services.map(\.name) == ["API", "worker", "cron"])
        #expect(project.services[1].icon == URL(string: "https://devicons.railway.com/i/postgresql.svg"))

        let api = project.services[0]
        #expect(api.instances.count == 2)
        let deployment = try #require(api.instances[0].deployment)
        #expect(deployment.id == "d1")
        #expect(deployment.status == .success)
        #expect(deployment.domain == "api.up.railway.app")
        #expect(deployment.createdAt == Date(timeIntervalSince1970: 1_791_531_499))
        #expect(project.services[1].instances[0].deployment?.createdAt == Date(timeIntervalSince1970: 1_790_840_299))
    }

    @Test func `reads the bill and estimates it as Railway's CLI does`() throws {
        let bill = try #require(try Self.snapshot().workspaces[0].bill)
        #expect(bill.currentDollars == 9.02)
        // 43,200 GB-minutes of memory at $10 a GB-month, and 21,600 vCPU-minutes at $20 a vCPU-month.
        #expect(abs((bill.estimatedDollars ?? 0) - 20) < 0.0001)
        #expect(bill.softLimitDollars == 15)
        #expect(bill.hardLimitDollars == 20)
        #expect(bill.limitDollars == 20)
        #expect(bill.percentOfLimit.map { abs($0 - 45.1) < 0.0001 } == true)
        #expect(bill.periodEnd == Date(timeIntervalSince1970: 1_792_757_498))
        #expect(!bill.isOverLimit)
    }

    @Test func `leaves the bill out when it wasn't asked for`() throws {
        let json = #"{"data": {"w0": {"id": "ws1", "name": "Acme", "projects": {"edges": []}}}}"#
        let workspaces = try RailwayAPI.status(status: 200, body: Data(json.utf8), workspaceCount: 1).get().workspaces
        #expect(workspaces[0].bill == nil)
    }

    @Test func `reads the account and its workspaces`() throws {
        let json = #"{"data": {"me": {"name": "Ada", "workspaces": [{"id": "ws1", "name": "Acme"}]}}}"#
        let account = try RailwayAPI.account(status: 200, body: Data(json.utf8)).get()
        #expect(account.name == "Ada")
        #expect(account.workspaces == [.init(id: "ws1", name: "Acme")])
    }

    @Test func `tells why a request failed`() {
        let notAuthorized = #"{"data": null, "errors": [{"message": "Not Authorized"}]}"#
        #expect(RailwayAPI.account(status: 200, body: Data(notAuthorized.utf8)) == .failure(.notAuthorized))
        let other = #"{"data": null, "errors": [{"message": "Problem processing request"}]}"#
        #expect(
            RailwayAPI.account(status: 200, body: Data(other.utf8))
                == .failure(.refused(message: "Problem processing request")))
        #expect(RailwayAPI.account(status: 401, body: Data()) == .failure(.rejected(status: 401)))
        #expect(RailwayAPI.account(status: 429, body: Data()) == .failure(.rateLimited(retryAfter: nil)))
        #expect(RailwayAPI.account(status: 200, body: Data("<html>".utf8)) == .failure(.unreadable))
    }

    @Test func `reads commits, and images for services deployed from one`() throws {
        let json = """
            {"data": {
              "d0": {"id": "d1", "meta": {"commitMessage": "Fix login\\n\\nLonger story", "branch": "main",
                     "commitHash": "abc123", "commitAuthor": "ada", "serviceManifest": {"build": {}}}},
              "d1": {"id": "d3", "meta": {"image": "redis:8", "logsV2": true}},
              "d2": null
            }}
            """
        let commits = try RailwayAPI.commits(status: 200, body: Data(json.utf8)).get()
        #expect(commits.count == 2)
        #expect(commits["d1"]?.title == "Fix login")
        #expect(commits["d1"]?.branch == "main")
        #expect(commits["d1"]?.author == "ada")
        #expect(commits["d3"]?.title == "redis:8")
    }

    // MARK: Overview

    @Test func `shows each project's primary environment by default`() throws {
        let snapshot = try Self.snapshot()
        let overview = try #require(RailwayOverview(snapshot: snapshot, settings: RailwaySettings()))
        #expect(overview.title == "shop")
        #expect(overview.environmentName == "production")
        #expect(overview.rows.map(\.name) == ["API", "worker", "cron"])
        #expect(overview.rows.map(\.health) == [.running, .sleeping, .deploying])
        #expect(overview.health == .deploying)
        #expect(overview.count(.deploying) == 1)
        #expect(snapshot.isDeploying)
        #expect(snapshot.deploymentIDs == ["d1", "d2", "d3", "d4"])
    }

    @Test func `shows another environment by name`() throws {
        var settings = RailwaySettings()
        settings.environmentName = "staging"
        let overview = try #require(RailwayOverview(snapshot: Self.snapshot(), settings: settings))
        #expect(overview.rows.map(\.name) == ["API"])
        #expect(overview.health == .failing)
        #expect(overview.rows[0].dashboardURL?.absoluteString.contains("environmentId=env-stg") == true)
    }

    @Test func `has no overview for a workspace it doesn't know`() throws {
        var settings = RailwaySettings()
        settings.workspaceID = "elsewhere"
        #expect(RailwayOverview(snapshot: try Self.snapshot(), settings: settings) == nil)
    }

    @Test func `orders services by attention, name or latest deploy`() throws {
        let overview = try #require(RailwayOverview(snapshot: Self.snapshot(), settings: RailwaySettings()))
        #expect(overview.rows(ordered: .attention, showsSleeping: true).map(\.name) == ["cron", "API", "worker"])
        #expect(overview.rows(ordered: .name, showsSleeping: true).map(\.name) == ["API", "cron", "worker"])
        #expect(overview.rows(ordered: .recent, showsSleeping: true).map(\.name) == ["cron", "API", "worker"])
        #expect(overview.rows(ordered: .name, showsSleeping: false).map(\.name) == ["API", "cron"])
    }

    @Test func `reads every deploy status, keeping unknown ones`() {
        #expect(Railway.DeploymentStatus("CRASHED").health == .failing)
        #expect(Railway.DeploymentStatus("NEEDS_APPROVAL") == .needsApproval)
        #expect(Railway.DeploymentStatus("QUEUED").health == .deploying)
        #expect(Railway.DeploymentStatus("REMOVED").health == .inactive)
        #expect(Railway.DeploymentStatus("TELEPORTING") == .other("TELEPORTING"))
    }

    // MARK: Rate limit and pacing

    @Test func `reads the rate limit from the response headers`() {
        let now = Date(timeIntervalSince1970: 1_000)
        let limit = RailwayRateLimit(
            headers: [
                "Ratelimit-Policy": #""default";q=1000;w=3600"#, "X-RateLimit-Remaining": "42",
                "X-RateLimit-Reset": "1791700000", "Retry-After": "30",
            ], now: now)
        #expect(limit.limit == 1000)
        #expect(limit.window == 3600)
        #expect(limit.hourlyLimit == 1000)
        #expect(limit.remaining == 42)
        #expect(limit.resetsAt == Date(timeIntervalSince1970: 1_791_700_000))
        #expect(limit.retryAfter == 30)

        let relative = RailwayRateLimit(headers: ["x-ratelimit-reset": "90"], now: now)
        #expect(relative.resetsAt == now.addingTimeInterval(90))
        #expect(relative.hourlyLimit == nil)
    }

    @Test func `automatic refresh stays within a small share of the rate limit`() {
        let now = Date.now
        func interval(_ hourly: Int?, deploying: Bool) -> TimeInterval {
            RailwayPacing.interval(
                refreshMinutes: nil, isDeploying: deploying,
                rateLimit: hourly.map { RailwayRateLimit(limit: $0, window: 3600) }, now: now)
        }
        // Hobby, and the assumption before Railway says.
        #expect(interval(1000, deploying: false) == 120)
        #expect(interval(nil, deploying: false) == 120)
        #expect(abs(interval(1000, deploying: true) - 14.4) < 0.001)
        // Free: 100 an hour.
        #expect(interval(100, deploying: false) == 720)
        #expect(interval(100, deploying: true) == 144)
        // Pro.
        #expect(interval(10_000, deploying: false) == 120)
        #expect(interval(10_000, deploying: true) == 10)
    }

    @Test func `a fixed refresh keeps its pace, deploying or not`() {
        let interval = RailwayPacing.interval(refreshMinutes: 5, isDeploying: true, rateLimit: nil, now: .now)
        #expect(interval == 300)
    }

    @Test func `waits for the window to reset when nearly out of requests`() {
        let now = Date.now
        let limit = RailwayRateLimit(limit: 1000, window: 3600, remaining: 50, resetsAt: now.addingTimeInterval(900))
        #expect(RailwayPacing.interval(refreshMinutes: nil, isDeploying: true, rateLimit: limit, now: now) == 900)
    }

    // MARK: Sign-in

    @Test func `reads the CLI's sign-in without its other settings`() throws {
        let json = """
            {"projects": {"/code": {"project": "p1"}},
             "user": {"accessToken": "rw_abc", "refreshToken": "rt_xyz", "tokenExpiresAt": 1791700000, "token": null}}
            """
        let signIn = try #require(RailwayCLISignIn(configJSON: Data(json.utf8)))
        #expect(signIn.accessToken == "rw_abc")
        #expect(signIn.expiresAt == Date(timeIntervalSince1970: 1_791_700_000))
        #expect(!signIn.description.contains("rw_abc"))

        let expiry = Date(timeIntervalSince1970: 1_791_700_000)
        #expect(!signIn.needsRenewal(at: expiry.addingTimeInterval(-61)))
        #expect(signIn.needsRenewal(at: expiry.addingTimeInterval(-60)))
        #expect(signIn.isUsable(at: expiry.addingTimeInterval(-30)))
        #expect(!signIn.isUsable(at: expiry))
    }

    @Test func `reads older CLIs' long-lived token, and nothing when signed out`() throws {
        let legacy = #"{"user": {"token": "legacy"}}"#
        let signIn = try #require(RailwayCLISignIn(configJSON: Data(legacy.utf8)))
        #expect(signIn.accessToken == "legacy")
        #expect(signIn.expiresAt == nil)
        #expect(!signIn.needsRenewal(at: .now))

        #expect(RailwayCLISignIn(configJSON: Data(#"{"user": {"accessToken": null, "token": null}}"#.utf8)) == nil)
        #expect(RailwayCLISignIn(configJSON: Data(#"{"projects": {}}"#.utf8)) == nil)
        #expect(RailwayCLISignIn(configJSON: Data("not json".utf8)) == nil)
    }

    // MARK: Status page

    @Test func `reads active incidents and ongoing maintenance from the status page`() throws {
        let json = """
            {"activeIncidents": [{"id": "i1", "slug": "31JU4V10", "title": "Builds are slow", "status": "MONITORING",
                "createdAt": "2026-10-10T01:34:56.813655+00:00",
                "components": [{"name": "Builds", "impact": "DEGRADED_PERFORMANCE"}]}],
             "recentIncidents": [{"id": "old", "title": "Resolved", "status": "RESOLVED"}],
             "maintenances": [{"id": "m1", "title": "Database upgrade", "status": "IN_PROGRESS"},
                              {"id": "m2", "title": "Next week", "status": "SCHEDULED"}],
             "entries": [], "generatedAt": "2026-10-10T20:30:53.982Z"}
            """
        let incidents = try #require(RailwayStatusPage.incidents(from: Data(json.utf8)))
        #expect(incidents.map(\.id) == ["i1", "m1"])
        #expect(incidents[0].title == "Builds are slow")
        #expect(incidents[0].components == ["Builds"])
        #expect(incidents[0].startedAt == Date(timeIntervalSince1970: 1_791_596_096))
        #expect(!incidents[0].isMaintenance)
        #expect(incidents[1].isMaintenance)
        #expect(RailwayStatusPage.incidents(from: Data("[]".utf8)) == nil)
    }

    // MARK: Settings

    @Test func `settings saved without options load with the defaults`() throws {
        let settings = try JSONDecoder().decode(RailwaySettings.self, from: Data("{}".utf8))
        #expect(settings == RailwaySettings())
        #expect(settings.blocks.shownBlocks == [.summary, .services, .usage, .incidents])
    }

    @Test func `unknown choices fall back rather than failing the configuration`() throws {
        let json = """
            {"account": "carrierPigeon", "glance": "vibes", "refreshMinutes": 0,
             "blocks": [{"block": "services", "shown": true}, {"block": "logs", "shown": true}],
             "blockOptions": {"services": {"order": "random", "maximumRows": 99}}}
            """
        let settings = try JSONDecoder().decode(RailwaySettings.self, from: Data(json.utf8))
        #expect(settings.account == .automatic)
        #expect(settings.glance == .health)
        #expect(settings.refreshMinutes == 1)
        #expect(settings.blocks.shownBlocks == [.services])
        #expect(settings.blockOptions.services.order == .attention)
        #expect(settings.blockOptions.services.maximumRows == RailwayServicesOptions.rowCountRange.upperBound)
    }

    @Test func `a Railway widget round-trips through the configuration`() throws {
        var settings = RailwaySettings(account: .token, refreshMinutes: 5)
        settings.projectID = "p1"
        settings.environmentName = "staging"
        settings.blocks = BlockLayout(shown: [.usage, .services])
        settings.blockOptions.services.showsCommit = false
        let widget = WidgetInstance(settings: .railway(settings))
        let decoded = try JSONDecoder().decode(WidgetInstance.self, from: JSONEncoder().encode(widget))
        #expect(decoded == widget)
    }

    @Test func `fetches only what the shown blocks need`() {
        var settings = RailwaySettings()
        #expect(settings.needs == RailwayNeeds(usage: true, incidents: true, commits: true, workspaceIDs: [nil]))

        settings.blocks = BlockLayout(shown: [.services])
        settings.blockOptions.services.showsCommit = false
        #expect(settings.needs == RailwayNeeds(workspaceIDs: [nil]))

        settings.glance = .usage
        #expect(settings.needs.usage)
    }

    @Test func `merges widgets' needs by sign-in, automatic winning over a fixed pace`() {
        var first = RailwaySettings(refreshMinutes: 5, blocks: BlockLayout(shown: [.services]))
        first.workspaceID = "ws1"
        let second = RailwaySettings(refreshMinutes: nil, blocks: BlockLayout(shown: [.usage]))
        let third = RailwaySettings(account: .token, refreshMinutes: 15, blocks: BlockLayout(shown: [.incidents]))
        let needs = ServiceDemand.railwayNeeds(
            of: [first, second, third].map { WidgetInstance(settings: .railway($0)) } + [WidgetInstance(kind: .clock)])

        let automatic = needs[.automatic]
        #expect(automatic?.usage == true)
        #expect(automatic?.commits == true)
        #expect(automatic?.incidents == false)
        #expect(automatic?.refreshMinutes == nil)
        #expect(automatic?.workspaceIDs == ["ws1", nil])
        #expect(needs[.token] == RailwayNeeds(incidents: true, refreshMinutes: 15, workspaceIDs: [nil]))
        #expect(needs[.cli] == nil)
    }

    @Test func `two fixed paces merge to the quicker one`() {
        let five = RailwayNeeds(refreshMinutes: 5)
        let two = RailwayNeeds(refreshMinutes: 2)
        #expect(five.merged(with: two).refreshMinutes == 2)
    }

    // MARK: Service blocks

    @Test func `a Service block's ID survives the configuration`() throws {
        let id = UUID()
        #expect(RailwayBlock(rawValue: "service:\(id.uuidString)") == .service(id))
        #expect(RailwayBlock.service(id).rawValue == "service:\(id.uuidString)")
        #expect(RailwayBlock(rawValue: "service:not-a-uuid") == nil)
        #expect(!RailwayBlock.service(id).isFixed)
        #expect(RailwayBlock.usage.isFixed)
    }

    @Test func `Service blocks are added with their options and removed with them`() throws {
        var settings = RailwaySettings()
        let block = settings.addServiceBlock(.init(projectID: "p1", serviceID: "s1", serviceName: "API"))
        guard case .service(let id) = block else {
            Issue.record("Not a Service block")
            return
        }
        #expect(settings.blocks.shownBlocks.last == block)
        #expect(settings.serviceOptions(id).serviceName == "API")

        let decoded = try JSONDecoder().decode(RailwaySettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)

        settings.removeBlock(block)
        #expect(!settings.blocks.contains(block))
        #expect(settings.serviceBlocks.isEmpty)
        settings.removeBlock(.usage)
        #expect(settings.blocks.contains(.usage))
    }

    @Test func `options of Service blocks the layout lacks are dropped on load`() throws {
        let kept = UUID()
        let json = """
            {"blocks": [{"block": "service:\(kept.uuidString)", "shown": true}],
             "serviceBlocks": {"\(kept.uuidString)": {"serviceID": "s1"}, "\(UUID().uuidString)": {"serviceID": "s2"}}}
            """
        let settings = try JSONDecoder().decode(RailwaySettings.self, from: Data(json.utf8))
        #expect(settings.serviceBlocks.keys.sorted() == [kept.uuidString])
        #expect(settings.serviceOptions(kept).serviceID == "s1")
        #expect(settings.serviceOptions(kept).showsMetrics)
    }

    @Test func `a shown Service block asks for its service's details and commit`() {
        var settings = RailwaySettings(blocks: BlockLayout(shown: [.usage]))
        settings.environmentName = "staging"
        let block = settings.addServiceBlock(.init(projectID: "p1", serviceID: "s1"))
        #expect(
            settings.needs.services == [
                RailwayServiceTarget(projectID: "p1", serviceID: "s1", environmentName: "staging")
            ])
        #expect(settings.needs.commits)

        settings.blocks.setShown(block, false)
        #expect(settings.needs.services.isEmpty)
        #expect(!settings.needs.commits)

        _ = settings.addServiceBlock()
        #expect(settings.needs.services.isEmpty)
    }

    @Test func `places a service in the environment its block names`() throws {
        let snapshot = try Self.snapshot()
        let staging = snapshot.detailRequest(
            for: RailwayServiceTarget(projectID: "p1", serviceID: "s1", environmentName: "staging"))
        #expect(staging == RailwayAPI.DetailRequest(projectID: "p1", serviceID: "s1", environmentID: "env-stg"))
        let primary = snapshot.detailRequest(for: RailwayServiceTarget(projectID: "p1", serviceID: "s1"))
        #expect(primary?.environmentID == "env-prod")
        #expect(snapshot.detailRequest(for: RailwayServiceTarget(projectID: "nope", serviceID: "s1")) == nil)
    }

    @Test func `asks for services' details alongside the status, or on their own`() {
        let both = RailwayAPI.statusQuery(workspaceCount: 1, includesUsage: false, detailCount: 2)
        #expect(both.contains("$w0: String!, $p0: String!, $s0: String!, $v0: String!, $p1: String!"))
        #expect(both.contains("$since: DateTime!"))
        #expect(both.contains("m1: metrics(projectId: $p1, serviceId: $s1, environmentId: $v1, startDate: $since"))
        #expect(both.contains("h0: deployments(first: 6, input: { projectId: $p0"))

        let alone = RailwayAPI.statusQuery(workspaceCount: 0, includesUsage: false, detailCount: 1)
        #expect(alone.hasPrefix("query SidelightStatus($p0: String!"))
        #expect(!alone.contains("workspace("))

        let now = Date(timeIntervalSince1970: 1_791_666_000)
        let variables = RailwayAPI.statusVariables(
            workspaceIDs: ["ws1"], details: [.init(projectID: "p1", serviceID: "s1", environmentID: "e1")], now: now)
        #expect(variables == ["w0": "ws1", "p0": "p1", "s0": "s1", "v0": "e1", "since": "2026-10-10T20:00:00Z"])
    }

    @Test func `reads services' metrics and recent deploys`() throws {
        let json = """
            {"data": {
              "m0": [{"measurement": "CPU_USAGE", "values": [{"ts": 1, "value": 0.001}, {"ts": 2, "value": 0.02}]},
                     {"measurement": "MEMORY_USAGE_GB", "values": [{"ts": 1, "value": 0.22}, {"ts": 2, "value": 0.23}]}],
              "h0": {"edges": [{"node": {"id": "d9", "status": "SUCCESS", "createdAt": "2026-10-09T07:38:19.230Z"}},
                               {"node": {"id": "d8", "status": "REMOVED", "createdAt": "2026-10-08T07:38:19Z"}}]},
              "m1": null, "h1": null
            }}
            """
        let status = try RailwayAPI.status(status: 200, body: Data(json.utf8), workspaceCount: 0, detailCount: 2).get()
        #expect(status.details.count == 2)
        let detail = try #require(status.details[0])
        #expect(detail.cpu == [0.001, 0.02])
        #expect(detail.memoryGB == [0.22, 0.23])
        #expect(detail.recentDeploys.map(\.id) == ["d9", "d8"])
        #expect(detail.recentDeploys.map(\.status) == [.success, .removed])
        #expect(status.details[1] == nil)
    }

    @Test func `a newly shown service counts as new data, so it's fetched soon`() {
        let before = RailwayNeeds(commits: true, workspaceIDs: [nil])
        var after = before
        after.services = [RailwayServiceTarget(projectID: "p1", serviceID: "s1")]
        #expect(!after.isCovered(by: before))
        #expect(before.isCovered(by: after))

        var hidden = before
        hidden.commits = false
        #expect(hidden.isCovered(by: before))
        #expect(!RailwayNeeds(usage: true).isCovered(by: before))
    }
}
