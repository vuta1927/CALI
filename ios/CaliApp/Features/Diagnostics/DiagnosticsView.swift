#if DEBUG
import ActivityKit
import CaliCore
import Foundation
import OSLog
import SwiftUI
import UserNotifications

/// IOS-012, dev build only (the whole file is compiled out of Release): database state, sync outbox, pending
/// notifications, current Live Activity, the unified log of this process, dev API credentials, and an export.
/// It shows counts and states, never row content; the export is redacted again as a whole (AGENTS rule 6).
struct DiagnosticsView: View {
    @Environment(AppStore.self) private var store
    @State private var sections: [DiagnosticsSection] = []
    @State private var exportURL: URL?
    @State private var baseURL = DevCredentialStore.read(.baseURL) ?? ""
    @State private var tokenDraft = ""
    @State private var hasToken = DevCredentialStore.read(.token) != nil
    @State private var loading = false

    var body: some View {
        List {
            Section("API dev") {
                TextField("Base URL (https://…)", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit { DevCredentialStore.write(.baseURL, baseURL) }
                SecureField(hasToken ? "JWT đã lưu trong Keychain" : "Dán JWT dev", text: $tokenDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Button("Lưu") {
                        DevCredentialStore.write(.baseURL, baseURL)
                        if !tokenDraft.isEmpty { DevCredentialStore.write(.token, tokenDraft) }
                        tokenDraft = ""
                        hasToken = DevCredentialStore.read(.token) != nil
                    }
                    Spacer()
                    Button("Xoá JWT", role: .destructive) {
                        DevCredentialStore.clear(.token)
                        hasToken = false
                    }
                    .disabled(!hasToken)
                }
                .buttonStyle(.borderless) // two buttons in one List row must not fire together
                Text(hasToken ? "Token có trong Keychain; không hiện lại, không vào log hay file xuất." : "Chưa có token.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                Section(section.title) {
                    if section.lines.isEmpty {
                        Text("(trống)").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { Task { await reload() } } label: { Label("Làm mới", systemImage: "arrow.clockwise") }
            }
            ToolbarItem(placement: .primaryAction) {
                if let exportURL {
                    ShareLink(item: exportURL) { Label("Export", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .task { await reload() }
        .overlay { if loading && sections.isEmpty { ProgressView() } }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        var all = [header()]
        if let snapshot = try? store.databaseDiagnostics() {
            all += DiagnosticsReport.lines(for: snapshot)
        } else {
            all.append(DiagnosticsSection(title: "Database", lines: ["Không đọc được cơ sở dữ liệu."]))
        }
        all.append(await notifications())
        all.append(await liveActivities())
        all.append(logSection())
        sections = all
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coami-diagnostics.txt")
        try? DiagnosticsReport.render(all, generatedAt: Date()).write(to: url, atomically: true, encoding: .utf8)
        exportURL = url
    }

    private func header() -> DiagnosticsSection {
        let info = Bundle.main.infoDictionary ?? [:]
        let size = (try? FileManager.default.attributesOfItem(atPath: AppDatabase.databaseURL.path)[.size] as? Int64) ?? nil
        return DiagnosticsSection(title: "App", lines: [
            "Version: \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))",
            "Build SHA: \(info["CaliBuildSHA"] as? String ?? "?")",
            "Database file: \(size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "in-memory")",
            "Time zone: \(TimeZone.current.identifier)",
            "API base URL set: \((DevCredentialStore.read(.baseURL) ?? "").isEmpty ? "no" : "yes"), JWT set: \(hasToken ? "yes" : "no")",
        ])
    }

    /// Identifier and fire date only; the title and body are not read.
    private func notifications() async -> DiagnosticsSection {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let pending = await center.pendingNotificationRequests()
        let lines = ["Authorization: \(settings.authorizationStatus.diagnosticName)"] + pending.map { request in
            let fire = (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate().map { $0.formatted(.iso8601) } ?? "no date"
            return "\(request.identifier) → \(fire)"
        }
        return DiagnosticsSection(title: "Pending notifications (\(pending.count))", lines: lines)
    }

    private func liveActivities() async -> DiagnosticsSection {
        let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
        let lines = ["Live Activities enabled: \(enabled ? "yes" : "no")"] + Activity<WorkoutAttributes>.activities.map {
            "\($0.id.prefix(8)) state \(String(describing: $0.activityState)) revision \($0.content.state.revision)"
        }
        return DiagnosticsSection(title: "Live Activity", lines: lines)
    }

    /// The last 150 entries of this process from our two subsystems, oldest first.
    private func logSection() -> DiagnosticsSection {
        guard let logStore = try? OSLogStore(scope: .currentProcessIdentifier) else {
            return DiagnosticsSection(title: "Log", lines: ["OSLogStore không khả dụng."])
        }
        let entries = ((try? logStore.getEntries()) ?? AnySequence([])).compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == "com.cali.app" || $0.subsystem == "cali.poc" }
        let lines = entries.suffix(150).map { "\($0.date.formatted(.iso8601)) [\($0.category)] \($0.composedMessage)" }
        return DiagnosticsSection(title: "Log (\(lines.count))", lines: Array(lines))
    }
}

private extension UNAuthorizationStatus {
    var diagnosticName: String {
        switch self {
        case .notDetermined: "not determined"
        case .denied: "denied"
        case .authorized: "authorized"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        @unknown default: "unknown"
        }
    }
}
#endif
