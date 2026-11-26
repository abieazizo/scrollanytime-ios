import SwiftUI

/// Launched with "-sederDemo": draws the Lock Screen countdown inside the app, with the very same
/// view, so a picture can be taken of it on the build machine. Never seen in normal use.
struct DemoScreen: View {
    private func card(_ state: SederAttributes.ContentState, stale: Bool) -> some View {
        LockView(state: state, stale: stale)
            .background(LinearGradient(colors: [brand, brandDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .padding(.horizontal, 10)
    }

    var body: some View {
        let now = Date().timeIntervalSince1970
        ZStack {
            LinearGradient(colors: [Color(red: 0.42, green: 0.47, blue: 0.55), Color(red: 0.16, green: 0.24, blue: 0.42)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                Text("12:21")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.top, 40)
                Spacer()
                card(.init(title: "Masechet Kiddushin", sub: "with Rabbi Resnick", startAt: now - 2820, endAt: now + 4380, next: "Mincha"), stale: false)
                card(.init(title: "Daily word practice", sub: nil, startAt: now - 150, endAt: now + 450, next: "Masechet Berachot"), stale: false)
                card(.init(title: "Gather unknown words and upload them", sub: nil, startAt: now - 1200, endAt: now - 1, next: "Derech Hashem or Halacha"), stale: true)
                Spacer().frame(height: 60)
            }
        }
    }
}
