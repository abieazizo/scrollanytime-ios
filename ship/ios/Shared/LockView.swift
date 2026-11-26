import SwiftUI

// The countdown as it is drawn on the Lock Screen. Shared, so the app can show the very same view.

let brand = Color(red: 0.114, green: 0.329, blue: 0.886)
let brandDeep = Color(red: 0.063, green: 0.204, blue: 0.667)
let sky = Color(red: 0.62, green: 0.77, blue: 1.0)

func span(_ s: SederAttributes.ContentState) -> (start: Date, end: Date) {
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
