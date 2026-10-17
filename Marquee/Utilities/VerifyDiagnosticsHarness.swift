//
//  VerifyDiagnosticsHarness.swift
//  Marquee
//
//  DEBUG-only verification for crash-report diagnostics export.
//  Activated by `--verify-diagnostics`.
//

#if DEBUG

import Foundation

enum VerifyDiagnosticsHarness {
    static let launchArgument = "--verify-diagnostics"

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }

        do {
            let detail = try runScenario()
            FileHandle.standardError.write(Data("verify-diagnostics: PASS collectsRecentCrashReports: \(detail)\n".utf8))
            FileHandle.standardError.write(Data("verify-diagnostics: outcome=verified passed=1/1\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("verify-diagnostics: FAIL collectsRecentCrashReports: \(error)\n".utf8))
            FileHandle.standardError.write(Data("verify-diagnostics: outcome=failed passed=0/1\n".utf8))
            exit(1)
        }
    }

    private static func runScenario() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("marquee-diagnostics-\(UUID().uuidString)", isDirectory: true)
        let crashDir = root.appendingPathComponent("DiagnosticReports", isDirectory: true)
        let outputDir = root.appendingPathComponent("Output", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: crashDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let crash = """
        {"app_name":"Marquee","timestamp":"2026-04-30 19:59:38.00 -0500","name":"Marquee"}
        {
          "captureTime" : "2026-04-30 19:58:51.0530 -0500",
          "incident" : "INCIDENT-123",
          "procPath" : "\(home)/Library/Developer/Xcode/DerivedData/Marquee.app/Contents/MacOS/Marquee",
          "exception" : {"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},
          "faultingThread" : 4
        }
        """
        let crashURL = crashDir.appendingPathComponent("Marquee-2026-04-30-195938.ips")
        try crash.write(to: crashURL, atomically: true, encoding: .utf8)

        let snapshot = DiagnosticsCollector.collect(
            crashReportDirectory: crashDir,
            maxCrashReports: 5
        )
        guard snapshot.recentCrashReports.count == 1 else {
            throw HarnessError.assertion("expected 1 crash report, got \(snapshot.recentCrashReports.count)")
        }
        let report = snapshot.recentCrashReports[0]
        guard report.incidentID == "INCIDENT-123" else {
            throw HarnessError.assertion("incidentID=\(String(describing: report.incidentID))")
        }
        guard report.exceptionType == "EXC_BAD_ACCESS", report.signal == "SIGSEGV" else {
            throw HarnessError.assertion("exception=\(String(describing: report.exceptionType)) signal=\(String(describing: report.signal))")
        }
        guard report.redactedProcessPath == "~/Library/Developer/Xcode/DerivedData/Marquee.app/Contents/MacOS/Marquee" else {
            throw HarnessError.assertion("process path was not redacted: \(String(describing: report.redactedProcessPath))")
        }

        let exportURL = try DiagnosticsCollector.writeSnapshot(
            to: outputDir,
            crashReportDirectory: crashDir,
            maxCrashReports: 5
        )
        guard FileManager.default.fileExists(atPath: exportURL.path) else {
            throw HarnessError.assertion("export missing at \(exportURL.path)")
        }

        let exportData = try Data(contentsOf: exportURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exported = try decoder.decode(DiagnosticsSnapshot.self, from: exportData)
        guard exported.recentCrashReports.count == 1 else {
            throw HarnessError.assertion("expected 1 exported crash report, got \(exported.recentCrashReports.count)")
        }
        guard exported.recentCrashReports[0].incidentID == "INCIDENT-123" else {
            throw HarnessError.assertion("exported incidentID=\(String(describing: exported.recentCrashReports[0].incidentID))")
        }

        return "incident parsed, home path redacted, export decoded"
    }

    private enum HarnessError: Error, CustomStringConvertible {
        case assertion(String)

        var description: String {
            switch self {
            case .assertion(let message): return message
            }
        }
    }
}

#endif
