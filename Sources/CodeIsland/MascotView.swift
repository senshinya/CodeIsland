import SwiftUI
import CodeIslandCore

// MARK: - Mascot Animation Speed Environment

private struct MascotSpeedKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    var mascotSpeed: Double {
        get { self[MascotSpeedKey.self] }
        set { self[MascotSpeedKey.self] = newValue }
    }
}

/// Routes a CLI source identifier to the correct pixel mascot view.
struct MascotView: View {
    let source: String
    let status: AgentStatus
    var size: CGFloat = 27
    @AppStorage(SettingsKey.mascotSpeed) private var globalSpeedPct = SettingsDefaults.mascotSpeed
    @AppStorage(SettingsKey.mascotSpeedProcessing) private var processingSpeedPct = SettingsDefaults.mascotSpeedProcessing
    @AppStorage(SettingsKey.mascotSpeedIdle) private var idleSpeedPct = SettingsDefaults.mascotSpeedIdle
    @AppStorage(SettingsKey.mascotSpeedWaiting) private var waitingSpeedPct = SettingsDefaults.mascotSpeedWaiting

    /// Effective speed percentage for the current status (-1 means use global)
    private var effectiveSpeedPct: Int {
        let perStatus: Int
        switch status {
        case .processing, .running: perStatus = processingSpeedPct
        case .idle:                 perStatus = idleSpeedPct
        case .waitingApproval, .waitingQuestion: perStatus = waitingSpeedPct
        }
        return perStatus >= 0 ? perStatus : globalSpeedPct
    }

    var body: some View {
        Group {
            switch source {
            case "codex":
                DexView(status: status, size: size)
            default:
                ClawdView(status: status, size: size)
            }
        }
        .environment(\.mascotSpeed, Double(effectiveSpeedPct) / 100.0)
    }
}
