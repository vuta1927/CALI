import AppIntents
import Foundation

/// POC-001 Lock Screen / Dynamic Island button (docs/20 phase 0, test T-11).
///
/// Compiled into BOTH targets (ios/Shared). iOS performs a `LiveActivityIntent` in the app process, so
/// only the app copy (`CALI_APP_PROCESS`, set in ios/project.yml) calls the single-writer coordinator
/// (ADR-013). The widget-extension copy exists so `Button(intent:)` can be built there; it never touches
/// the database.
///
/// Locked device: `authenticationPolicy = .requiresAuthentication` asks the system to require unlock
/// before `perform()` runs. Whether iOS honours this for Live Activity buttons is exactly what POC-001
/// must observe on a real iPhone; the app also refuses taps while protected data is unavailable
/// (`POCRuntime.lockedTapGuardEnabled`). COAMI never promises a locked-device bypass.
/// TODO(IOS-001): replace with production intents after the GO decision.
struct POCLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "COAMI POC: thao tác trên màn khoá" }
    static var isDiscoverable: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    /// `WorkoutAttributes.ContentState.sessionId` (UUID string).
    @Parameter(title: "Session")
    var sessionId: String

    /// Revision the Lock Screen snapshot was rendered from; drives the deterministic `commandId`.
    @Parameter(title: "Revision")
    var revision: Int

    /// `LiveActivityAction` raw value: `extend_rest_30` or `confirm_current_set`.
    @Parameter(title: "Action")
    var action: String

    init() {}

    init(sessionId: String, revision: Int, action: String) {
        self.sessionId = sessionId
        self.revision = revision
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        #if CALI_APP_PROCESS
        await POCRuntime.shared.handleLiveActivityTap(sessionId: sessionId, revision: revision, action: action)
        #endif
        return .result()
    }
}
