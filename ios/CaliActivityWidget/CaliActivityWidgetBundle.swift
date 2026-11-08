import SwiftUI
import WidgetKit

/// Widget extension entry point. The extension only renders Live Activity snapshots
/// (ADR-013 single writer): no database access, no workout state changes. The POC-001 Lock Screen
/// buttons use `POCLiveActivityIntent` (ios/Shared), which iOS performs in the app process; the copy
/// compiled into this extension is a no-op.
@main
struct CaliActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        WorkoutLiveActivity()
    }
}
