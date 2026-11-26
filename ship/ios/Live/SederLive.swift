import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SederLiveBundle: WidgetBundle {
    var body: some Widget {
        SederLiveActivity()
    }
}

private let brand = Color(red: 0.114, green: 0.329, blue: 0.886)
private let brandDeep = Color(red: 0.063, green: 0.204, blue: 0.667)
private let sky = Color(red: 0.62, green: 0.77, blue: 1.0)

private func span(_ s: SederAttributes.ContentState) -> (start: Date, end: Date) {
    let start = Date(timeIntervalSince1970: s.startAt)
    // A range must run forward, whatever arrives.
    let end = Date(timeIntervalSince1970: max(s.endAt, s.startAt + 1))
    return (start, end)
}

/// The time left, ticking on its own: the phone counts, nothing has to be sent.
struct Remaining: View {
    let state: SederAttributes.ContentState
    let stale: Bool

    var body: some View {
        let t = span(state)
        if stale || t.end <= Date() {
            Text("0:00")
        } else {
            Text(timerInterval: t.start...t.end, countsDown: true)
        }
    }
}

struct LockView: View {
    let state: SederAttributes.ContentState
    let stale: Bool

    var body: some View {
        let t = span(state)
        let over = stale || t.end <= Date()
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(over ? "TIME IS UP" : "NOW")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(1.4)
                        .foregroundStyle(sky)
                    Text(state.title)
                        .font(.system(size: 21, weight: .bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                    if let sub = state.sub, !sub.isEmpty {
                        Text(sub)
                            .font(.system(size: 13, weight: .medium))
                            .opacity(0.8)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Remaining(state: state, stale: stale)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: 150, alignment: .trailing)
            }

            if over {
                ProgressView(value: 1).progressViewStyle(.linear).tint(.white)
            } else {
                ProgressView(timerInterval: t.start...t.end, countsDown: false, label: { EmptyView() }, currentValueLabel: { EmptyView() })
                    .progressViewStyle(.linear)
                    .tint(.white)
            }

            HStack(spacing: 8) {
                Text(t.start, style: .time)
                Spacer(minLength: 4)
                if over {
                    Text("Open Seder to mark it").lineLimit(1)
                } else if let next = state.next, !next.isEmpty {
                    Text("Next: \(next)").lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(t.end, style: .time)
            }
            .font(.system(size: 12, weight: .semibold))
            .opacity(0.8)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
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
