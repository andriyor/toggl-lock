import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LockWidgetBundle: WidgetBundle {
  var body: some Widget { LockLiveActivity() }
}

struct LockLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: LockAttributes.self) { ctx in
      LockView(ctx: ctx)
        .foregroundStyle(.white)
        .activityBackgroundTint(.black)  // opaque: a translucent tint shows through in StandBy
        .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { ctx in
      DynamicIsland {
        DynamicIslandExpandedRegion(.center) { Text(ctx.state.message) }
      } compactLeading: {
        TimerIcon(running: ctx.state.startedAt != nil)
      } compactTrailing: {
        if let startedAt = ctx.state.startedAt {
          Text(startedAt, style: .timer).frame(width: 50)
        }
      } minimal: {
        TimerIcon(running: ctx.state.startedAt != nil)
      }
    }
    .supplementalActivityFamilies([.small])  // own layout in the Apple Watch Smart Stack
  }
}

// .small is the Apple Watch Smart Stack; everything else is the Lock Screen.
struct LockView: View {
  let ctx: ActivityViewContext<LockAttributes>
  @Environment(\.activityFamily) var family

  var body: some View {
    let title = ctx.state.project ?? ctx.attributes.title
    if family == .small {
      HStack {
        TimerIcon(running: ctx.state.startedAt != nil).font(.title2)
        VStack(alignment: .leading) {
          Text(title).font(.headline).lineLimit(1)
          if let startedAt = ctx.state.startedAt {
            Text(startedAt, style: .timer).font(.title3.monospacedDigit())
          } else {
            Text(ctx.state.message).font(.subheadline)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(8)
    } else {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.headline)
          Text(ctx.state.message).font(.title3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let startedAt = ctx.state.startedAt {
          // A .timer Text takes all the width it's offered, so give it a fixed one; scales down past 9:59:59
          Text(startedAt, style: .timer)
            .font(.system(size: 40, weight: .semibold).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .multilineTextAlignment(.trailing)
            .frame(width: 150, alignment: .trailing)
        }
      }
      .padding()
    }
  }
}

// Green play while a timer runs, grey stop when none does.
struct TimerIcon: View {
  let running: Bool
  var body: some View {
    Image(systemName: running ? "play.circle.fill" : "stop.circle")
      .foregroundStyle(running ? .green : .gray)
  }
}
