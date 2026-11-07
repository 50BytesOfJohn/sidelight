import Foundation
import Testing

@testable import SidelightCore

struct GitHubSettingsTests {
    @Test func `a new widget shows reviews, your pull requests and GitHub's incidents`() {
        let settings = GitHubSettings()
        #expect(settings.blocks.shownBlocks == [.reviewRequests, .pullRequests, .status])
        #expect(settings.refresh == .minutes(2))
        #expect(settings.blockOptions.reviewRequests.list.hidesWhenEmpty)
        #expect(settings.blockOptions.reviewRequests.list.rowStyle == .singleLine)
    }

    @Test func `missing, unknown and hand-edited options load as what the settings offer`() throws {
        let json = """
            {"repositories": ["https://github.com/acme/api.git", "nope nope", "Acme/API", "@acme-labs"],
             "refresh": 600, "glance": "somethingNew",
             "blocks": [{"block": "issues", "shown": true}, {"block": "fromTheFuture", "shown": true}],
             "blockOptions": {"issues": {"list": {"maximumRows": 99}, "scope": "everything"}}}
            """
        let settings = try JSONDecoder().decode(GitHubSettings.self, from: Data(json.utf8))
        #expect(settings.repositories == ["acme/api", "acme-labs"])
        #expect(settings.refresh == .minutes(60))
        #expect(settings.glance == .attention)
        #expect(settings.blocks.shownBlocks == [.issues])
        #expect(settings.blocks.entries.count == GitHubBlock.fixedBlocks.count)
        #expect(settings.blockOptions.issues.list.maximumRows == GitHubListOptions.rowCountRange.upperBound)
        #expect(settings.blockOptions.issues.scope == .assigned)
        #expect(settings.blockOptions.reviewRequests == GitHubReviewOptions())
    }

    @Test func `settings survive a round trip, repository blocks included`() throws {
        var settings = GitHubSettings(account: .gitHubCLI, repositories: ["acme/api"], preset: .everything)
        let block = settings.addRepositoryBlock(GitHubRepositoryBlockOptions(repository: "cli/cli"))
        settings.blockOptions.notifications.includesCIActivity = true
        let decoded = try JSONDecoder().decode(GitHubSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        guard case .repository(let id) = block else {
            Issue.record("Not a repository block")
            return
        }
        #expect(decoded.repositoryOptions(id).repository == "cli/cli")
        settings.removeBlock(block)
        #expect(!settings.blocks.contains(block))
        #expect(settings.repositoryOptions(id) == GitHubRepositoryBlockOptions())
    }

    @Test func `options of a repository block the layout lacks are dropped`() throws {
        let orphan = UUID()
        let json = """
            {"repositoryBlocks": {"\(orphan.uuidString)": {"repository": "acme/api"}}}
            """
        let settings = try JSONDecoder().decode(GitHubSettings.self, from: Data(json.utf8))
        #expect(settings.repositoryOptions(orphan).repository == nil)
    }

    @Test(
        arguments: [
            ("acme/api", "acme/api"),
            ("  https://github.com/acme/api/pull/12  ", "acme/api"),
            ("git@github.com:acme/api.git", nil),
            ("github.com/acme", "acme"),
            ("acme/api.js", "acme/api.js"),
            ("acme//api", nil),
            ("acme/a pi", nil),
            ("", nil),
        ] as [(String, String?)])
    func `filter entries are read the way people paste them`(text: String, expected: String?) {
        #expect(GitHubSettings.normalizedFilterEntry(text) == expected)
    }

    @Test func `searches carry the block's options and the widget's filter`() throws {
        var settings = GitHubSettings(repositories: ["acme/api", "acme-labs"])
        settings.blockOptions.reviewRequests.includesTeamRequests = false
        settings.blockOptions.pullRequests.includesDrafts = false
        settings.blockOptions.issues.scope = .mentioned
        let reviews = try #require(settings.search(for: .reviewRequests))
        #expect(
            reviews.query
                == "is:open is:pr archived:false user-review-requested:@me repo:acme/api user:acme-labs sort:updated-desc"
        )
        #expect(reviews.kind == .pullRequest)
        #expect(try #require(settings.search(for: .pullRequests)).query.contains("author:@me draft:false"))
        let issues = try #require(settings.search(for: .issues))
        #expect(issues.kind == .issue && issues.query.contains("is:issue") && issues.query.contains("mentions:@me"))
        #expect(settings.search(for: .notifications) == nil)
        let url = try #require(GitHubSettings.webURL(for: issues))
        #expect(url.absoluteString.hasPrefix("https://github.com/issues?q=is:open%20is:issue"))
    }
}

struct GitHubDemandTests {
    private let side = ShownPanel(position: .right, density: .regular)
    private let minimal = ShownPanel(position: .right, density: .minimal)

    private func configuration(_ widgets: [GitHubSettings]) -> AppConfiguration {
        var configuration = AppConfiguration()
        configuration.sections = [PanelSection(widgets: widgets.map { WidgetInstance(settings: .gitHub($0)) })]
        return configuration
    }

    @Test func `nothing is fetched until the GitHub CLI signs in, but the widget still counts as shown`() {
        let demand = configuration([GitHubSettings()]).gitHubDemand(panels: [side])
        #expect(demand.isShown)
        #expect(demand.accounts.isEmpty)
    }

    @Test func `shown blocks decide what's fetched, and the minimal size only its glance`() throws {
        let configuration = configuration([GitHubSettings(preset: .focus)])
        let blocks = try #require(
            configuration.gitHubDemand(panels: [side], signedIn: [.gitHubCLI]).accounts[.gitHubCLI])
        #expect(blocks.searches.count == 2)
        #expect(blocks.status && !blocks.contributions && blocks.notifications == nil)
        let glance = try #require(
            configuration.gitHubDemand(panels: [minimal], signedIn: [.gitHubCLI]).accounts[.gitHubCLI])
        #expect(glance.searches.count == 2 && !glance.status)
    }

    @Test func `two widgets on one account share one request`() throws {
        var triage = GitHubSettings(refresh: .minutes(15), preset: .triage)
        triage.blockOptions.reviewRequests.list.maximumRows = 9
        let focus = GitHubSettings(refresh: .minutes(5), preset: .focus)
        let needs = try #require(
            configuration([triage, focus]).gitHubDemand(panels: [side], signedIn: [.gitHubCLI]).accounts[.gitHubCLI])
        let reviews = try #require(focus.search(for: .reviewRequests))
        #expect(needs.searches[reviews] == 9)
        #expect(needs.searches.count == 3)
        #expect(needs.notifications != nil)
        #expect(needs.cadence == .minutes(5))
    }

    @Test func `the summary needs one result of each search, and the inbox`() {
        let needs = GitHubSettings(preset: .glance).blockNeeds()
        #expect(needs.searches.values.allSatisfy { $0 == 1 } && needs.searches.count == 3)
        #expect(needs.notifications != nil)
    }

    @Test func `only the status page needs no GraphQL`() {
        var needs = GitHubNeeds()
        needs.status = true
        #expect(!needs.isEmpty && !needs.needsGraphQL)
        needs.repositories = ["cli/cli"]
        #expect(needs.needsGraphQL)
    }
}

struct GitHubAPITests {
    private let pullRequests = GitHubSearch(query: "is:pr author:@me", kind: .pullRequest)
    private let issues = GitHubSearch(query: "is:issue assignee:@me", kind: .issue)

    @Test func `one request asks for every search, repository and the calendar, with values as variables`() {
        let request = GitHubRequest(
            searches: [pullRequests: 4, issues: 80], repositories: ["cli/cli"], contributions: true)
        let document = request.document
        #expect(document.hasPrefix("query($s0: String!, $s1: String!, $r0o: String!, $r0n: String!)"))
        // Capped: no block lists that many.
        #expect(document.contains("s0: search(query: $s0, type: ISSUE, first: 50)"))
        #expect(document.contains("s1: search(query: $s1, type: ISSUE, first: 4)"))
        #expect(document.contains("... on PullRequest"))
        #expect(document.contains("r0: repository(owner: $r0o, name: $r0n)"))
        #expect(document.contains("c: viewer { contributionsCollection"))
        #expect(request.variables == ["s0": issues.query, "s1": pullRequests.query, "r0o": "cli", "r0n": "cli"])
        #expect(!document.contains("author:@me"))
    }

    @Test func `an empty request asks only who's signed in`() {
        #expect(GitHubRequest().document == "query { viewer { login } rateLimit { remaining limit resetAt } }")
        #expect(GitHubRequest().variables.isEmpty)
    }

    @Test func `an answer with a missing repository still reads the rest`() throws {
        let request = GitHubRequest(
            searches: [issues: 3, pullRequests: 3], repositories: ["acme/gone", "cli/cli"], contributions: true)
        let body = """
            {"data": {
              "viewer": {"login": "octo"},
              "rateLimit": {"remaining": 4990, "limit": 5000, "resetAt": "2026-11-07T14:00:00Z"},
              "s0": {"issueCount": 7, "nodes": [
                {"number": 3, "title": "Crash", "url": "https://github.com/a/b/issues/3", "createdAt": "2026-11-01T10:00:00Z",
                 "updatedAt": "2026-11-06T10:00:00Z", "author": {"login": "sam"}, "repository": {"nameWithOwner": "a/b"},
                 "comments": {"totalCount": 2}, "labels": {"nodes": [{"name": "bug", "color": "d73a4a"}]}},
                {"title": "No number"}, {}
              ]},
              "s1": {"issueCount": 1, "nodes": [
                {"number": 12, "title": "Speed up", "url": "https://github.com/a/b/pull/12", "isDraft": false,
                 "author": {"login": "octo"}, "repository": {"nameWithOwner": "a/b"}, "reviewDecision": "CHANGES_REQUESTED",
                 "mergeable": "CONFLICTING", "headRefName": "speed", "additions": 10, "deletions": 3,
                 "comments": {"totalCount": 0},
                 "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "ERROR"}}}]}}
              ]},
              "r0": null,
              "r1": {"nameWithOwner": "cli/cli", "url": "https://github.com/cli/cli", "isPrivate": false,
                     "stargazerCount": 40000, "pullRequests": {"totalCount": 50}, "issues": {"totalCount": 700},
                     "defaultBranchRef": {"name": "trunk", "target": {"messageHeadline": "Fix", "committedDate": "2026-11-06T09:00:00Z",
                       "statusCheckRollup": {"state": "SUCCESS"}}},
                     "latestRelease": {"tagName": "v2.103.3", "publishedAt": "2026-10-26T00:00:00Z", "url": "https://github.com/cli/cli/releases/tag/v2.103.3"}},
              "c": {"contributionsCollection": {"contributionCalendar": {"totalContributions": 5, "weeks": [
                {"contributionDays": [{"date": "2026-11-01", "contributionCount": 0, "contributionLevel": "NONE"},
                                      {"date": "2026-11-02", "contributionCount": 5, "contributionLevel": "FOURTH_QUARTILE"}]}]}}}
            },
            "errors": [{"type": "NOT_FOUND", "path": ["r0"], "message": "Could not resolve to a Repository with the name 'acme/gone'."}]}
            """
        let response = try GitHubAPI.response(to: request, body: Data(body.utf8)).get()
        #expect(response.login == "octo")
        #expect(response.rateLimit?.remaining == 4990)
        #expect(response.errors.count == 1)

        let issue = try #require(response.searches[issues]?.items.first)
        #expect(response.searches[issues]?.totalCount == 7)
        #expect(response.searches[issues]?.items.count == 1)
        #expect(issue.kind == .issue && issue.labels == [GitHub.Label(name: "bug", color: "d73a4a")])
        #expect(issue.comments == 2 && issue.author == "sam" && issue.repositoryName == "b")

        let pull = try #require(response.searches[pullRequests]?.items.first)
        #expect(pull.kind == .pullRequest)
        #expect(pull.checks == .failure && pull.reviewDecision == .changesRequested && pull.hasConflicts)
        #expect(pull.needsAuthor && !pull.isReadyToMerge)
        #expect(pull.headBranch == "speed" && pull.additions == 10)

        #expect(response.repositories["acme/gone"] == .some(nil))
        let cli = try #require(response.repositories["cli/cli"] ?? nil)
        #expect(cli.branchChecks == .success && cli.defaultBranch == "trunk" && cli.openIssues == 700)
        #expect(cli.latestRelease?.tag == "v2.103.3")

        #expect(response.contributions?.days.map(\.level) == [0, 4])
    }

    @Test func `an answer without data says why`() {
        let limited = #"{"errors": [{"type": "RATE_LIMITED", "message": "API rate limit exceeded"}]}"#
        #expect(
            GitHubAPI.response(to: GitHubRequest(), body: Data(limited.utf8)).failure == .rateLimited(until: nil))
        let other = #"{"errors": [{"message": "Something broke"}]}"#
        #expect(GitHubAPI.response(to: GitHubRequest(), body: Data(other.utf8)).failure == .failed("Something broke"))
        #expect(GitHubAPI.response(to: GitHubRequest(), body: Data("<html>".utf8)).failure == .unreadable)
    }

    @Test func `HTTP statuses read as problems`() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(GitHubAPI.problem(status: 200, headers: [:], body: Data(), now: now) == nil)
        #expect(GitHubAPI.problem(status: 401, headers: [:], body: Data(), now: now) == .rejected)
        #expect(
            GitHubAPI.problem(
                status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "2000"], body: Data(),
                now: now)
                == .rateLimited(until: Date(timeIntervalSince1970: 2000)))
        #expect(
            GitHubAPI.problem(status: 403, headers: [:], body: Data(#"{"message": "SSO required"}"#.utf8), now: now)
                == .notPermitted("SSO required"))
        #expect(GitHubAPI.problem(status: 502, headers: [:], body: Data(), now: now) == .unreachable)
    }

    @Test func `notifications open where they point on github.com`() throws {
        let body = """
            [{"id": "1", "reason": "review_requested", "updated_at": "2026-11-07T10:00:00Z",
              "subject": {"title": "Speed up", "url": "https://api.github.com/repos/a/b/pulls/12", "type": "PullRequest"},
              "repository": {"full_name": "a/b"}},
             {"id": "2", "reason": "ci_activity", "subject": {"title": "Run failed", "url": null, "type": "CheckSuite"},
              "repository": {"full_name": "a/b"}},
             {"id": "3", "reason": "subscribed", "subject": {"title": "v1", "url": "https://api.github.com/repos/a/b/releases/99", "type": "Release"},
              "repository": {"full_name": "a/b"}},
             {"nonsense": true}]
            """
        let threads = try #require(GitHubAPI.notifications(from: Data(body.utf8)))
        #expect(threads.map(\.id) == ["1", "2", "3"])
        #expect(threads[0].url?.absoluteString == "https://github.com/a/b/pull/12")
        #expect(threads[0].subject == .pullRequest && !threads[0].isCIActivity)
        #expect(threads[1].url?.absoluteString == "https://github.com/a/b" && threads[1].isCIActivity)
        #expect(threads[2].url?.absoluteString == "https://github.com/a/b/releases")
        #expect(
            GitHubAPI.webURL(subject: "https://api.github.com/repos/a/b/issues/4", repository: "a/b")?.absoluteString
                == "https://github.com/a/b/issues/4")
    }

    @Test func `the status page lists what's going on, not what's over or still to come`() throws {
        let body = """
            {"incidents": [{"id": "i1", "name": "Actions delayed", "status": "investigating", "impact": "minor",
                            "shortlink": "https://stspg.io/x"},
                           {"id": "i2", "name": "Old", "status": "resolved"}],
             "scheduled_maintenances": [{"id": "m1", "name": "Now", "status": "in_progress"},
                                        {"id": "m2", "name": "Later", "status": "scheduled"}]}
            """
        let incidents = try #require(GitHubAPI.incidents(from: Data(body.utf8)))
        #expect(incidents.map(\.id) == ["i1", "m1"])
        #expect(incidents[1].isMaintenance)
    }
}

struct GitHubCLITests {
    @Test func `gh's own words tell signed out, rejected, offline and limited apart`() {
        func problem(_ stderr: String, status: Int32 = 1, stdout: String = "") -> GitHubFetchProblem? {
            GitHubCLI.problem(status: status, output: Data(stdout.utf8), error: Data(stderr.utf8))
        }
        #expect(problem("To get started with GitHub CLI, please run:  gh auth login", status: 4) == .cliNotSignedIn)
        #expect(problem("gh: Bad credentials (HTTP 401)") == .rejected)
        #expect(problem("gh: API rate limit exceeded for user (HTTP 403)") == .rateLimited(until: nil))
        #expect(problem("error connecting to api.github.com\ncheck your internet connection") == .unreachable)
        #expect(problem("gh: Resource protected by organization SAML enforcement (HTTP 403)") != nil)
        #expect(problem("gh: something odd") == .failed("something odd"))
        // A GraphQL answer with an error alongside its data is read, not failed.
        #expect(problem("gh: Could not resolve to a Repository", stdout: #"{"data":{"r0":null},"errors":[]}"#) == nil)
        #expect(problem("", status: 0, stdout: "[]") == nil)
        #expect(problem("", status: 0, stdout: "oops") == .unreadable)
    }

    @Test func `who gh is signed in as comes from hosts.yml, never its token`() {
        let signedIn = """
            github.com:
                users:
                    octo:
                git_protocol: https
                user: octo
            enterprise.example.com:
                user: someone-else
            """
        #expect(GitHubCLI.signedInUser(hostsYAML: signedIn) == "octo")
        #expect(GitHubCLI.signedInUser(hostsYAML: "enterprise.example.com:\n    user: x\n") == nil)
        #expect(GitHubCLI.signedInUser(hostsYAML: "") == nil)
        #expect(GitHubCLI.signedInUser(hostsYAML: "github.com:\n    users:\n        octo:\n") == "")
    }

    @Test func `requests pass every value as its own argument`() {
        let request = GitHubRequest(searches: [GitHubSearch(query: "is:pr x=y", kind: .pullRequest): 2])
        let arguments = GitHubCLI.graphQLArguments(request)
        #expect(arguments.prefix(3) == ["api", "graphql", "-f"])
        #expect(arguments.contains("s0=is:pr x=y"))
        #expect(GitHubCLI.restArguments(path: "notifications").last == "notifications")
    }

    @Test func `gh's settings folder follows its environment variables`() {
        #expect(GitHubCLI.configDirectory(environment: ["GH_CONFIG_DIR": "/tmp/gh"]).path() == "/tmp/gh/")
        #expect(GitHubCLI.configDirectory(environment: ["XDG_CONFIG_HOME": "/tmp/x"]).path() == "/tmp/x/gh/")
        #expect(GitHubCLI.configDirectory(environment: [:]).path().hasSuffix("/.config/gh/"))
    }
}

struct GitHubContributionTests {
    private func calendar(_ counts: [Int]) -> GitHub.Contributions {
        GitHub.Contributions(
            total: counts.reduce(0, +),
            days: counts.enumerated().map { .init(date: "d\($0.offset)", count: $0.element, level: min($0.element, 4)) }
        )
    }

    @Test func `today without a contribution doesn't break the streak yet`() {
        #expect(calendar([1, 0, 2, 3, 0]).currentStreak == 2)
        #expect(calendar([1, 0, 2, 3, 1]).currentStreak == 3)
        #expect(calendar([1, 0, 0]).currentStreak == 0)
        #expect(calendar([1, 1, 1, 0, 2, 2]).longestStreak == 3)
        #expect(calendar([]).currentStreak == 0)
    }

    @Test func `weeks are seven days from the calendar's start, the latest maybe partial`() {
        let weeks = calendar(Array(repeating: 1, count: 17)).weeks(2)
        #expect(weeks.map(\.count) == [7, 3])
        #expect(weeks.last?.first?.date == "d14")
    }
}

extension Result {
    fileprivate var failure: Failure? {
        if case .failure(let failure) = self { failure } else { nil }
    }
}
