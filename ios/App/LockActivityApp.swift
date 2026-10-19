import ActivityKit
import SwiftUI

@main
struct LockActivityApp: App {
  init() { PushSync.start() }

  // the server owns the activity (it mirrors Toggl); just show it
  var body: some Scene {
    WindowGroup { RunningTimerView() }
  }
}

/// What the Live Activity currently shows, kept live as server pushes arrive.
struct RunningTimerView: View {
  @State private var activity = Activity<LockAttributes>.activities.first {
    $0.activityState == .active
  }
  @State private var state: LockAttributes.ContentState?

  var body: some View {
    VStack(spacing: 8) {
      if let state {
        if let project = state.project { Text(project).font(.headline) }
        Text(state.message).font(.title2)
        if let startedAt = state.startedAt {
          Text(startedAt, style: .timer).font(.largeTitle.monospacedDigit())
        }
      } else {
        Text("No Live Activity yet").foregroundStyle(.secondary)
      }
    }
    .multilineTextAlignment(.center)
    .padding()
    .task {
      for await a in Activity<LockAttributes>.activityUpdates { activity = a }
    }
    .task(id: activity?.id) {
      guard let activity else { return }
      state = activity.content.state
      for await content in activity.contentUpdates { state = content.state }
    }
  }
}
