import SwiftUI

/// 试说一句: the same recording pill as in daily use. Click it or press the dictation key to
/// start; ✓ finishes, ✕ cancels. The result is shown here only.
struct OnboardingPracticeView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var practice: OnboardingPracticeController

    var body: some View {
        VStack(spacing: 18) {
            Text(L10n.text("试说一句")).font(.system(size: 24, weight: .bold))
            Text(L10n.text("按 {0} 或点下面的录音条，读这句话。", model.hotkeyLabel))
                .font(.system(size: 14)).foregroundColor(Theme.secondary).multilineTextAlignment(.center)
            Text(practice.sample)
                .font(.system(size: 15, weight: .medium)).multilineTextAlignment(.center)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                .fixedSize(horizontal: false, vertical: true)
            PracticePill(practice: practice).padding(.top, 4)
            if !practice.status.isEmpty {
                Text(practice.status).font(.system(size: 13, weight: .medium))
                    .foregroundColor(practice.complete ? Theme.success : Theme.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            if !practice.output.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("整理结果")).font(.caption).foregroundColor(Theme.secondary)
                    Text(practice.output).font(.system(size: 14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
            }
        }
        .onAppear { practice.acceptsShortcut = true }
        .onDisappear { practice.acceptsShortcut = false; practice.cancel() }
    }
}

/// The dark capsule: idle it invites a click; recording shows ✕, the live waveform and ✓;
/// while cleaning up, three breathing dots.
private struct PracticePill: View {
    @ObservedObject var practice: OnboardingPracticeController
    @State private var breathe = false

    var body: some View {
        HStack(spacing: 10) {
            switch practice.phase {
            case .idle:
                Image(systemName: "mic.fill").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                    .frame(width: 28, height: 28).background(Circle().fill(Color.white.opacity(0.22)))
                Text(practice.complete ? L10n.text("再试一次") : L10n.text("点这里开始"))
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(.white).padding(.trailing, 10)
            case .recording:
                circleButton(symbol: "xmark", filled: false) { practice.cancel() }
                    .help(L10n.text("取消"))
                HStack(spacing: 3) {
                    ForEach(Array(practice.levels.enumerated()), id: \.offset) { _, level in
                        Capsule().fill(Color.white)
                            .frame(width: 2.4, height: max(3, CGFloat(level) * 22))
                    }
                }
                .frame(height: 24)
                .animation(.linear(duration: 0.05), value: practice.levels)
                circleButton(symbol: "checkmark", filled: true) { practice.stop() }
                    .help(L10n.text("结束并整理"))
            case .thinking:
                HStack(spacing: 7) {
                    ForEach(0..<3) { index in
                        Circle().fill(Color.white).frame(width: 6, height: 6)
                            .opacity(breathe ? 1 : 0.35)
                            .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(index) * 0.2), value: breathe)
                    }
                }
                .padding(.horizontal, 22).frame(height: 28)
                .onAppear { breathe = true }.onDisappear { breathe = false }
            }
        }
        .padding(4)
        .background(Capsule().fill(Color(white: 0.09)))
        .overlay(Capsule().stroke(Color.white.opacity(0.12)))
        .contentShape(Capsule())
        .onTapGesture { if practice.phase == .idle { practice.toggle() } }
        .animation(.easeInOut(duration: 0.18), value: practice.phase)
    }

    private func circleButton(symbol: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(filled ? Color(white: 0.09) : .white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(filled ? Color.white : Color.white.opacity(0.22)))
        }
        .buttonStyle(.plain)
    }
}
