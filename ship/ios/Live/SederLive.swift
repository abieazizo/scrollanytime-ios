import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SederLiveBundle: WidgetBundle {
    var body: some Widget {
        SederLiveActivity()
    }
}

struct SederLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SederAttributes.self) { context in
            LockView(state: context.state, stale: context.isStale)
                .background(LinearGradient(colors: [brand, brandDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                .activityBackgroundTint(brandDeep)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let t = span(context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NOW")
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(1.2)
                            .foregroundStyle(sky)
                        Text(context.state.title)
                            .font(.system(size: 16, weight: .bold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Remaining(state: context.state, stale: context.isStale)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(width: 104, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        if context.isStale || t.end <= Date() {
                            ProgressView(value: 1).progressViewStyle(.linear).tint(sky)
                        } else {
                            ProgressView(timerInterval: t.start...t.end, countsDown: false, label: { EmptyView() }, currentValueLabel: { EmptyView() })
                                .progressViewStyle(.linear)
                                .tint(sky)
                        }
                        HStack {
                            Text(t.start, style: .time)
                            Spacer()
                            if let next = context.state.next, !next.isEmpty {
                                Text("Next: \(next)").lineLimit(1)
                            }
                            Spacer()
                            Text(t.end, style: .time)
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "book.closed.fill").foregroundStyle(sky)
            } compactTrailing: {
                Remaining(state: context.state, stale: context.isStale)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(sky)
                    .frame(width: 56, alignment: .trailing)
            } minimal: {
                Image(systemName: "timer").foregroundStyle(sky)
            }
            .keylineTint(sky)
        }
    }
}
