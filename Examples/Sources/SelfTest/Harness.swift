import Foundation

// How SelfTest runs its groups of checks and reports the results.
//
// - Each group has a deadline (`SelfTest.groupDeadlines`). A group that
//   outlives it fails with its name, and the next group runs.
// - A SKIP carries a category: `environment` when this machine could not
//   run the check (offline, no visible window, an assistive app running),
//   `limitation` when CEF cannot do what the check needs. The summary
//   counts each; `SELFTEST_STRICT=1`, which CI sets, makes environment
//   skips, and skips without a category, count as failures.
// - `SELFTEST_ISOLATED=1` runs each group in a process of its own, with its
//   own cache directory, and kills one that outlives its deadline.
// - `SELFTEST_JSON=<path>` writes every result as JSON.

/// Every line the checks print passes through here, so that results
/// printed directly, such as SKIP lines and a child process's lines, are
/// recorded too.
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let text = items.map { "\($0)" }.joined(separator: separator)
    Swift.print(text, terminator: terminator)
    for line in text.split(separator: "\n") {
        SelfTestResults.shared.record(line: String(line))
    }
}

enum SkipCategory: String, Codable, Sendable {
    /// This machine or network could not run the check.
    case environment
    /// What the check needs is outside what CEF does.
    case limitation
    /// A SKIP line without a category.
    case uncategorized
}

struct CheckResult: Codable, Sendable {
    enum Status: String, Codable, Sendable { case pass, fail, skip }
    var group: String
    var name: String
    var status: Status
    var detail: String?
    var category: SkipCategory?

    /// Reads a `PASS name`, `FAIL name — detail` or
    /// `SKIP [category] name — reason` line.
    init?(line: String, group: String) {
        let status: Status
        switch line.prefix(5) {
        case "PASS ": status = .pass
        case "FAIL ": status = .fail
        case "SKIP ": status = .skip
        default: return nil
        }
        var rest = line.dropFirst(5)
        var category: SkipCategory?
        if status == .skip {
            category = .uncategorized
            if rest.hasPrefix("["), let close = rest.firstIndex(of: "]"),
               let parsed = SkipCategory(rawValue: String(rest[rest.index(after: rest.startIndex)..<close])) {
                category = parsed
                rest = rest[rest.index(after: close)...].drop { $0 == " " }
            }
        }
        // A PASS line is all name; names can contain " — " too, so the
        // detail of a FAIL or SKIP line is what follows the last one.
        let text = String(rest)
        if status != .pass, let separator = text.range(of: " — ", options: .backwards) {
            self.init(group: group, name: String(text[..<separator.lowerBound]), status: status,
                      detail: String(text[separator.upperBound...]), category: category)
        } else {
            self.init(group: group, name: text, status: status, category: category)
        }
    }

    init(group: String, name: String, status: Status, detail: String? = nil, category: SkipCategory? = nil) {
        self.group = group
        self.name = name
        self.status = status
        self.detail = detail
        self.category = category
    }
}

struct GroupRun: Codable, Sendable {
    enum Outcome: String, Codable, Sendable { case finished, timedOut, crashed }
    var name: String
    var outcome: Outcome
    var durationSeconds: Double
}

/// The results so far, from any thread.
final class SelfTestResults: @unchecked Sendable {
    static let shared = SelfTestResults()

    private let lock = NSLock()
    private var checks: [CheckResult] = []
    private var groups: [GroupRun] = []
    private var currentGroup = "startup"

    var group: String {
        get { lock.withLock { currentGroup } }
        set { lock.withLock { currentGroup = newValue } }
    }

    func record(line: String) {
        lock.withLock {
            if let result = CheckResult(line: line, group: currentGroup) { checks.append(result) }
        }
    }

    func record(_ result: CheckResult) { lock.withLock { checks.append(result) } }
    func record(_ run: GroupRun) { lock.withLock { groups.append(run) } }

    var snapshot: (checks: [CheckResult], groups: [GroupRun]) { lock.withLock { (checks, groups) } }
}

enum SelfTestReport {
    static var isStrict: Bool { ProcessInfo.processInfo.environment["SELFTEST_STRICT"] == "1" }

    /// Prints the summary and writes `SELFTEST_JSON`. Returns how many
    /// checks failed, strict skips included.
    @discardableResult
    static func finish(failures: Int, isolated: Bool, started: ContinuousClock.Instant) -> Int {
        let (checks, groups) = SelfTestResults.shared.snapshot
        let skips = checks.filter { $0.status == .skip }
        func count(_ category: SkipCategory) -> Int { skips.filter { $0.category == category }.count }
        var failed = failures
        let strictSkips = skips.filter { $0.category != .limitation }
        if isStrict, !strictSkips.isEmpty {
            failed += strictSkips.count
            Swift.print("FAIL strict: \(strictSkips.count) skip(s) without the limitation category count as " +
                        "failures with SELFTEST_STRICT=1 — " + strictSkips.map(\.name).joined(separator: "; "))
        }
        let passed = checks.filter { $0.status == .pass }.count
        Swift.print("SUMMARY \(passed) passed, \(failed) failed, \(skips.count) skipped (environment " +
                    "\(count(.environment)), limitation \(count(.limitation)), uncategorized " +
                    "\(count(.uncategorized)))" + (isolated ? ", one process per group" : "") +
                    String(format: ", %.0f s", seconds(since: started)))
        if let path = ProcessInfo.processInfo.environment["SELFTEST_JSON"], !path.isEmpty {
            struct Document: Encodable {
                var passed: Int
                var failed: Int
                var skipped: [String: Int]
                var strict: Bool
                var isolated: Bool
                var durationSeconds: Double
                var groups: [GroupRun]
                var checks: [CheckResult]
            }
            let document = Document(
                passed: passed, failed: failed,
                skipped: ["environment": count(.environment), "limitation": count(.limitation),
                          "uncategorized": count(.uncategorized)],
                strict: isStrict, isolated: isolated, durationSeconds: seconds(since: started),
                groups: groups, checks: checks)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            do {
                try encoder.encode(document).write(to: URL(fileURLWithPath: path))
            } catch {
                Swift.print("FAIL results: could not write \(path) — \(error)")
                failed += 1
            }
        }
        Swift.print(failed == 0 ? "ALL CHECKS PASSED" : "\(failed) CHECK(S) FAILED")
        return failed
    }

    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}

extension SelfTest {
    /// How long each group may take; others get `defaultGroupDeadline`.
    /// Several times the longest run seen on an M3 MacBook, and room for
    /// the checks' own timeouts where they wait for the network.
    static let groupDeadlines: [String: Duration] = [
        "lifecycle": .seconds(180),
        "authentication": .seconds(120),
        "localization": .seconds(150),
        "internalPages": .seconds(120),
        "serviceHosts": .seconds(90),
        "protectedMedia": .seconds(120),
        "systemEngine": .seconds(90),
        "discard": .seconds(90),
        "processes": .seconds(120),
        "security": .seconds(120),
    ]
    static let defaultGroupDeadline: Duration = .seconds(60)

    static func deadline(of group: String) -> Duration { groupDeadlines[group] ?? defaultGroupDeadline }

    /// Reports a check that did not run, and why.
    static func skip(_ name: String, because reason: String, _ category: SkipCategory) {
        print("SKIP [\(category.rawValue)] \(name) — \(reason)")
    }

    /// The groups `SELFTEST_ONLY` names, or all of them.
    static var selectedGroups: [(name: String, run: @MainActor () async -> Void)] {
        let only = ProcessInfo.processInfo.environment["SELFTEST_ONLY"]
            .map { Set($0.split(separator: ",").map(String.init)) }
        return checkGroups.filter { only?.contains($0.name) ?? true }
    }

    /// Runs one group; when it outlives its deadline, fails it and returns
    /// while its checks are still waiting.
    static func run(group name: String, _ body: @escaping @MainActor () async -> Void) async {
        SelfTestResults.shared.group = name
        let started = ContinuousClock.now
        let limit = deadline(of: name)
        let finished = await finishes(within: limit, body)
        if !finished {
            check("\(name): the group finishes within \(limit)", false,
                  detail: "a check is still waiting; the rest of the group did not run")
        }
        SelfTestResults.shared.record(GroupRun(
            name: name, outcome: finished ? .finished : .timedOut, durationSeconds: SelfTestReport.seconds(since: started)))
        Swift.print(String(format: "GROUP %@ %.1f s", name, SelfTestReport.seconds(since: started)))
    }

    /// Whether `body` returns within `limit`. When it does not, it is
    /// cancelled and left to finish whenever it does.
    static func finishes(within limit: Duration, _ body: @escaping @MainActor () async -> Void) async -> Bool {
        final class Once {
            var continuation: CheckedContinuation<Bool, Never>?
            func resume(_ value: Bool) {
                continuation?.resume(returning: value)
                continuation = nil
            }
        }
        let once = Once()
        return await withCheckedContinuation { continuation in
            once.continuation = continuation
            let work = Task { @MainActor in
                await body()
                once.resume(true)
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                if once.continuation != nil {
                    work.cancel()
                    once.resume(false)
                }
            }
        }
    }

    // MARK: One process per group

    static var isIsolatedParent: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["SELFTEST_ISOLATED"] == "1"
            && environment[relaunchEnvironmentKey] == nil && environment[widevineProbeEnvironmentKey] == nil
            && environment[probeEnvironmentKey] == nil
            && Benchmarks.requested == nil && !ServiceBenchmark.isRequested
    }

    /// Runs each selected group in a child process and returns the exit
    /// status: the number of failed checks.
    static func runIsolated() -> Int32 {
        let started = ContinuousClock.now
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        var failures = 0
        for group in selectedGroups {
            SelfTestResults.shared.group = group.name
            let groupStarted = ContinuousClock.now
            var environment = ProcessInfo.processInfo.environment
            environment["SELFTEST_ISOLATED"] = nil
            environment["SELFTEST_JSON"] = nil
            environment["SELFTEST_STRICT"] = nil
            environment["SELFTEST_ONLY"] = group.name
            let child = Process()
            child.executableURL = executable
            child.environment = environment
            let output = Pipe()
            child.standardOutput = output
            let reader = ChildOutput(output.fileHandleForReading)
            let exited = DispatchSemaphore(value: 0)
            child.terminationHandler = { _ in exited.signal() }
            do {
                try child.run()
            } catch {
                Swift.print("FAIL \(group.name): the process starts — \(error)")
                SelfTestResults.shared.record(line: "FAIL \(group.name): the process starts — \(error)")
                failures += 1
                continue
            }
            reader.start()
            // Startup and quit on top of the group's own deadline.
            let limit = deadline(of: group.name) + .seconds(45)
            var outcome = GroupRun.Outcome.finished
            if exited.wait(timeout: .now() + .seconds(Int(limit.components.seconds))) == .timedOut {
                outcome = .timedOut
                child.terminate()
                if exited.wait(timeout: .now() + 5) == .timedOut {
                    kill(child.processIdentifier, SIGKILL)
                    exited.wait()
                }
            }
            reader.finish()
            failures += reader.failures
            let status = child.terminationStatus
            if outcome == .timedOut {
                let line = "FAIL \(group.name): the group finishes within \(limit) — the process was killed"
                Swift.print(line)
                SelfTestResults.shared.record(line: line)
                failures += 1
            } else if child.terminationReason == .uncaughtSignal || (status != 0 && reader.failures == 0) {
                outcome = .crashed
                let line = "FAIL \(group.name): the process exits normally — " +
                    (child.terminationReason == .uncaughtSignal ? "signal \(status)" : "status \(status)")
                Swift.print(line)
                SelfTestResults.shared.record(line: line)
                failures += 1
            }
            SelfTestResults.shared.record(GroupRun(
                name: group.name, outcome: outcome, durationSeconds: SelfTestReport.seconds(since: groupStarted)))
            Swift.print(String(format: "GROUP %@ %.1f s (own process)", group.name,
                               SelfTestReport.seconds(since: groupStarted)))
        }
        // 124 is the watchdog's.
        return Int32(min(SelfTestReport.finish(failures: failures, isolated: true, started: started), 123))
    }

    /// Forwards a child's result lines as they arrive and records them;
    /// leaves out its own summary, which the parent prints for all groups.
    final class ChildOutput: @unchecked Sendable {
        private let handle: FileHandle
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var failed = 0

        init(_ handle: FileHandle) { self.handle = handle }

        var failures: Int { lock.withLock { failed } }

        func start() {
            Thread.detachNewThread { [self] in
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                        buffer.removeSubrange(buffer.startIndex...newline)
                        forward(line)
                    }
                }
                if !buffer.isEmpty { forward(String(decoding: buffer, as: UTF8.self)) }
                done.signal()
            }
        }

        private func forward(_ line: String) {
            if line == "ALL CHECKS PASSED" || line.hasSuffix("CHECK(S) FAILED") || line.hasPrefix("SUMMARY ") {
                return
            }
            if line.hasPrefix("FAIL ") { lock.withLock { failed += 1 } }
            Swift.print(line)
            SelfTestResults.shared.record(line: line)
        }

        /// Waits for the rest of the output. Helper processes can hold the
        /// pipe open for a moment after the child exits.
        func finish() {
            if done.wait(timeout: .now() + 10) == .timedOut { try? handle.close() }
        }
    }
}
