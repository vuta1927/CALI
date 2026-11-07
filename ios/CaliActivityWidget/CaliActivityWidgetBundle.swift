import SwiftUI
import WidgetKit

/// Widget extension entry point. The extension only renders Live Activity snapshots
/// (ADR-013 single writer): no database access, no workout state changes, no intents yet.
@main
struct CaliActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        WorkoutLiveActivity()
    }
}
