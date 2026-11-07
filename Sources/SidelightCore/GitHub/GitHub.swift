import Foundation

/// What GitHub widgets show: pull requests and issues found by searches, the inbox, repositories, the contribution
/// calendar and GitHub's own incidents. Read-only: Sidelight never writes to GitHub.
public enum GitHub {
    /// How a commit's checks and statuses are doing, as GitHub rolls them up.
    public enum CheckState: String, Hashable, Sendable {
        case success
        case failure
        /// Queued, running, or expected and not reported yet.
        case pending

        /// GitHub's `StatusState`: `SUCCESS`, `FAILURE`, `ERROR`, `PENDING`, `EXPECTED`.
        public init?(graphQL value: String?) {
            switch value?.uppercased() {
            case "SUCCESS": self = .success
            case "FAILURE", "ERROR": self = .failure
            case "PENDING", "EXPECTED": self = .pending
            default: return nil
            }
        }
    }

    /// What reviewers decided about a pull request, when its branch rules ask for reviews.
    public enum ReviewDecision: String, Hashable, Sendable {
        case approved
        case changesRequested
        case reviewRequired

        public init?(graphQL value: String?) {
            switch value?.uppercased() {
            case "APPROVED": self = .approved
            case "CHANGES_REQUESTED": self = .changesRequested
            case "REVIEW_REQUIRED": self = .reviewRequired
            default: return nil
            }
        }
    }

    public struct Label: Hashable, Sendable {
        public var name: String
        /// `d73a4a`, without the `#`.
        public var color: String?

        public init(name: String, color: String? = nil) {
            self.name = name
            self.color = color
        }
    }

    /// A pull request or an issue, as a search finds it.
    public struct Item: Hashable, Sendable, Identifiable {
        public enum Kind: Hashable, Sendable {
            case pullRequest
            case issue
        }

        public var kind: Kind
        /// `owner/name`
        public var repository: String
        public var number: Int
        public var title: String
        public var url: URL?
        public var author: String?
        public var createdAt: Date?
        public var updatedAt: Date?
        public var comments: Int = 0
        public var labels: [Label] = []
        // Pull requests only.
        public var isDraft = false
        public var checks: CheckState?
        public var reviewDecision: ReviewDecision?
        /// It can't merge until its conflicts are resolved.
        public var hasConflicts = false
        /// The branch it merges from, to check it out.
        public var headBranch: String?
        public var additions: Int?
        public var deletions: Int?

        public var id: String { "\(repository)#\(number)" }

        public init(
            kind: Kind, repository: String, number: Int, title: String, url: URL? = nil, author: String? = nil,
            createdAt: Date? = nil, updatedAt: Date? = nil
        ) {
            self.kind = kind
            self.repository = repository
            self.number = number
            self.title = title
            self.url = url
            self.author = author
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        /// The repository's name without its owner: `sidelight`.
        public var repositoryName: String {
            repository.split(separator: "/").last.map(String.init) ?? repository
        }

        /// Something only its author can move forward: failing checks, changes asked for, or conflicts.
        public var needsAuthor: Bool {
            checks == .failure || reviewDecision == .changesRequested || hasConflicts
        }

        /// Ready to merge as far as Sidelight can tell: approved, checks green, no conflicts.
        public var isReadyToMerge: Bool {
            !isDraft && reviewDecision == .approved && checks != .failure && checks != .pending && !hasConflicts
        }
    }

    /// What a search found: the first few results, newest activity first, and how many there are in all.
    public struct SearchResult: Hashable, Sendable {
        public var totalCount: Int
        public var items: [Item]

        public init(totalCount: Int, items: [Item]) {
            self.totalCount = totalCount
            self.items = items
        }
    }

    /// One repository at a glance.
    public struct Repository: Hashable, Sendable {
        /// `owner/name`, as GitHub spells it.
        public var name: String
        public var url: URL?
        public var isPrivate = false
        public var stars = 0
        public var openPullRequests = 0
        public var openIssues = 0
        public var defaultBranch: String?
        /// The checks on the default branch's latest commit.
        public var branchChecks: CheckState?
        public var lastCommitTitle: String?
        public var lastCommitDate: Date?
        public var latestRelease: Release?

        public init(name: String, url: URL? = nil) {
            self.name = name
            self.url = url
        }
    }

    public struct Release: Hashable, Sendable {
        public var tag: String
        public var publishedAt: Date?
        public var url: URL?

        public init(tag: String, publishedAt: Date? = nil, url: URL? = nil) {
            self.tag = tag
            self.publishedAt = publishedAt
            self.url = url
        }
    }

    /// A year of contributions, a day at a time, oldest first.
    public struct Contributions: Hashable, Sendable {
        public struct Day: Hashable, Sendable {
            /// `2026-11-07`, the day in the account's time zone, as GitHub counts it.
            public var date: String
            public var count: Int
            /// 0 for none, then 1 to 4 for each quartile of the account's busiest days.
            public var level: Int

            public init(date: String, count: Int, level: Int) {
                self.date = date
                self.count = count
                self.level = level
            }
        }

        public var total: Int
        public var days: [Day]

        public init(total: Int, days: [Day]) {
            self.total = total
            self.days = days
        }

        /// Days in a row with a contribution, up to the latest day. A latest day without one doesn't break it
        /// yet: the day isn't over.
        public var currentStreak: Int {
            var days = self.days[...]
            if days.last?.count == 0 { days = days.dropLast() }
            return days.reversed().prefix { $0.count > 0 }.count
        }

        /// The longest run of days with a contribution in the year.
        public var longestStreak: Int {
            var longest = 0
            var current = 0
            for day in days {
                current = day.count > 0 ? current + 1 : 0
                longest = max(longest, current)
            }
            return longest
        }

        /// The last `count` weeks, each Sunday to Saturday; the latest may be partial.
        public func weeks(_ count: Int) -> [[Day]] {
            guard !days.isEmpty else { return [] }
            // GitHub's calendar starts on a Sunday, so weeks are every seven days from the start.
            let all = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
            return Array(all.suffix(count))
        }
    }

    /// A thread in the account's notifications inbox.
    public struct Notification: Hashable, Sendable, Identifiable {
        public enum Subject: Hashable, Sendable {
            case pullRequest
            case issue
            case release
            case discussion
            case commit
            case checkSuite
            case other(String)

            public init(_ type: String) {
                switch type {
                case "PullRequest": self = .pullRequest
                case "Issue": self = .issue
                case "Release": self = .release
                case "Discussion": self = .discussion
                case "Commit": self = .commit
                case "CheckSuite": self = .checkSuite
                default: self = .other(type)
                }
            }
        }

        public var id: String
        public var title: String
        public var subject: Subject
        /// Why it's in the inbox: `review_requested`, `mention`, `ci_activity`…
        public var reason: String
        /// `owner/name`
        public var repository: String
        public var updatedAt: Date?
        /// Where it opens on github.com.
        public var url: URL?

        public init(
            id: String, title: String, subject: Subject, reason: String, repository: String, updatedAt: Date? = nil,
            url: URL? = nil
        ) {
            self.id = id
            self.title = title
            self.subject = subject
            self.reason = reason
            self.repository = repository
            self.updatedAt = updatedAt
            self.url = url
        }

        /// A workflow run finishing: busy and rarely worth a look, so it's left out unless asked for.
        public var isCIActivity: Bool { reason == "ci_activity" || subject == .checkSuite }
    }

    /// An incident or maintenance on githubstatus.com.
    public struct Incident: Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        /// `investigating`, `identified`, `monitoring`…
        public var status: String?
        /// `minor`, `major`, `critical`…
        public var impact: String?
        public var isMaintenance: Bool
        public var url: URL?

        public init(
            id: String, title: String, status: String? = nil, impact: String? = nil, isMaintenance: Bool = false,
            url: URL? = nil
        ) {
            self.id = id
            self.title = title
            self.status = status
            self.impact = impact
            self.isMaintenance = isMaintenance
            self.url = url
        }
    }
}
