import SwiftUI

struct MacSetupView: View {
    @EnvironmentObject private var setup: MacSetupChecker
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        PageScaffold(
            title: "Mac Setup",
            subtitle: "A few macOS settings help everything work, especially trackpad swipes. Each check turns green as soon as its setting is right."
        ) {
            MacSetupChecklist()
            guideLink
        }
        .onAppear {
            setup.refresh()
            setup.beginMonitoring()
            preferences.macSetupIntroduced = true
        }
        .onDisappear { setup.endMonitoring() }
    }

    private var guideLink: some View {
        FlowLayout(spacing: 6, lineSpacing: 4) {
            Image(systemName: "book")
            Text("The same guide, step by step, is on the website:")
            Link(guideLabel, destination: AppPaths.setupGuideURL)
                .foregroundStyle(Theme.accent)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textSecondary)
    }

    private var guideLabel: String {
        let url = AppPaths.setupGuideURL
        return "\(url.host ?? "github.com")/\(AppPaths.repository)/…/docs/setup.md"
    }
}

/// Shared with the Mac Setup step of onboarding.
struct MacSetupChecklist: View {
    @EnvironmentObject private var setup: MacSetupChecker
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var confirmation: MacSetupConfirmation?

    private var checks: [SetupCheck] {
        #if DEBUG
        if isSnapshot, let samples = MacSetupSnapshotSamples.checks { return samples }
        #endif
        return setup.checks
    }

    private var groups: [SetupGroup] {
        #if DEBUG
        if isSnapshot, MacSetupSnapshotSamples.checks != nil {
            return SetupGroup.allCases.filter { group in checks.contains { $0.group == group } }
        }
        #endif
        return setup.groups
    }

    private var failureCount: Int {
        checks.filter { !$0.isRecommendation && ($0.state == .fail || $0.state == .warning) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            MacSetupSummary(failureCount: failureCount)
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: group.title, systemImage: group.systemImage)
                    Card {
                        DividedRows(data: checks.filter { $0.group == group }) { check in
                            MacSetupCheckRow(check: check) { action in
                                if let prompt = MacSetupConfirmation(action: action, check: check) {
                                    confirmation = prompt
                                } else {
                                    setup.perform(action, for: check.id)
                                }
                            }
                        }
                    }
                }
            }
        }
        .alert(item: $confirmation) { prompt in
            Alert(
                title: Text(prompt.title),
                message: Text(prompt.message),
                primaryButton: .destructive(Text(prompt.action.label)) {
                    setup.perform(prompt.action, for: prompt.checkID)
                },
                secondaryButton: .cancel(Text("Cancel"))
            )
        }
    }
}

private struct MacSetupSummary: View {
    let failureCount: Int
    private var ready: Bool { failureCount == 0 }
    private var tint: Color { ready ? Theme.success : Theme.warning }

    var body: some View {
        Card(
            padding: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 16),
            fill: tint.opacity(0.07), stroke: tint.opacity(0.24)
        ) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().strokeBorder(tint, lineWidth: 4)
                    Image(systemName: ready ? "checkmark" : "exclamationmark")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(tint)
                }
                .frame(width: 50, height: 50)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(ready
                         ? "Every setting \(AppPaths.appName) needs is right. Come back here whenever you need."
                         : "Work down the list. Each button opens the right page in System Settings.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if ready { return "Your Mac is ready for \(AppPaths.appName)" }
        return failureCount == 1 ? "1 setting needs changing" : "\(failureCount) settings need changing"
    }
}

private struct MacSetupCheckRow: View {
    let check: SetupCheck
    let perform: (SetupAction) -> Void
    private var expanded: Bool { check.state != .pass }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CheckGlyph(state: check.isRecommendation && expanded ? .warning : check.state)
                .padding(.top, 1)
                .accessibilityLabel(check.state == .pass ? "Passed" : (check.isRecommendation ? "Recommended" : "Needs attention"))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(check.title)
                        .font(Theme.Font.rowTitleEmphasis)
                        .foregroundStyle(Theme.textPrimary)
                    if check.isRecommendation { Badge(text: "Recommended") }
                }
                Text(check.detail)
                    .font(Theme.Font.rowSubtitle)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if expanded { instructions.padding(.top, 7) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let instruction = check.instruction, !instruction.isEmpty {
                Text(instruction)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
            }
            if let path = check.settingPath, !path.isEmpty {
                Text(path)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            if check.needsLogout, check.instruction != "Then log out and back in." {
                InfoNote(text: "Then log out and back in.", systemImage: "arrow.right.square")
            }
            if !check.actions.isEmpty {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(check.actions) { action in
                        if action.isPrimary {
                            Button(action.label) { perform(action) }
                                .buttonStyle(PrimaryButtonStyle())
                        } else {
                            Button(action.label) { perform(action) }
                                .buttonStyle(SecondaryButtonStyle(compact: true))
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MacSetupConfirmation: Identifiable {
    var id: String { "\(checkID)-\(action.id)" }
    let action: SetupAction
    let checkID: String
    let title: String
    let message: String

    init?(action: SetupAction, check: SetupCheck) {
        self.action = action
        checkID = check.id
        switch action.kind {
        case .automaticFix:
            title = "Stop macOS reordering your desktops?"
            message = "This turns off automatic desktop reordering and briefly restarts the Dock. The Dock and desktop may disappear for a moment."
        case .quitApps:
            title = "\(action.label)?"
            message = "These apps will be asked to quit so only one window manager controls your windows. Save any work in them first."
        default:
            return nil
        }
    }
}
