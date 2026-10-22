import SwiftUI

/// Snapshot-only OYM_ONBOARDING_STEP: 0 Welcome, 1 permission, 2 setup,
/// 3 strip, 4 completion. Debug snapshots also accept
/// OYM_ONBOARDING_PERMISSION=missing; normal launches ignore both hooks.
struct OnboardingView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var preferences: Preferences
    @EnvironmentObject private var setup: MacSetupChecker
    @EnvironmentObject private var engine: EngineController
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: OnboardingStep = .welcome
    @State private var openedPermissionSettings = false
    @State private var monitoringSetup = false
    @State private var confirmsRepair = false

    var body: some View {
        ZStack {
            Theme.contentBackground
            VStack(spacing: 0) {
                progress
                    .padding(.top, 32)
                    .padding(.bottom, 24)
                GeometryReader { proxy in
                    ScrollView(.vertical) {
                        VStack(spacing: 22) {
                            header
                            stepContent
                        }
                        .id(step)
                        .transition(.opacity)
                        .frame(maxWidth: 520)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 20)
                        // Centre the step when it fits; scroll when it does not.
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
                    }
                }
                footer
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 28)
                    .padding(.top, 16)
                    .padding(.bottom, 28)
                    .layoutPriority(1)
            }
        }
        .onAppear {
            if isSnapshot,
               let value = ProcessInfo.processInfo.environment["OYM_ONBOARDING_STEP"],
               let number = Int(value), let initial = OnboardingStep(rawValue: number) {
                step = initial
            }
            enterStep()
        }
        .onChange(of: step) { _ in enterStep() }
        .onChange(of: permissionTrusted) { trusted in
            if trusted, step == .permission, !isSnapshot { advance() }
        }
        .onDisappear { stopSetupMonitoring() }
        .alert("Reset \(AppPaths.appName)'s Accessibility permission?", isPresented: $confirmsRepair) {
            Button("Reset and Grant Again", role: .destructive) {
                guard !isSnapshot else { return }
                permissions.repair()
                permissions.waitForGrant(onGranted: permissionGranted)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Use this only if the app is already enabled in Accessibility but still shows as missing. macOS will remove the old entry and ask you to allow the app again.")
        }
    }

    private var progress: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingStep.allCases) { item in
                Capsule()
                    .fill(item == step ? Theme.accent : Theme.separator)
                    .frame(width: item == step ? 24 : 8, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of 5")
    }

    private var header: some View {
        VStack(spacing: 14) {
            Group {
                if step == .welcome {
                    BrandMark(size: 84)
                } else {
                    IconDisc(systemImage: headerSymbol, diameter: 64, tint: headerTint)
                }
            }
            .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
            }
        }
        .multilineTextAlignment(.center)
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .welcome:
            VStack(spacing: 18) {
                OnboardingStripIllustration(height: 140)
                Card(inset: 16) {
                    feature("A strip of windows", detail: "New windows join the strip. The others keep their useful size.", symbol: "rectangle.split.3x1")
                    CardDivider().padding(.vertical, 12)
                    feature("Keyboard first", detail: "Every action has a shortcut that you can change.", symbol: "keyboard")
                }
            }
        case .permission:
            permissionContent
        case .macSetup:
            MacSetupChecklist()
        case .strip:
            VStack(spacing: 18) {
                OnboardingStripIllustration(height: 132)
                Card(inset: 16) {
                    feature("Focus moves the strip", detail: "Switch to another window and the strip slides so the window is on screen. Your current shortcuts are below.", symbol: "arrow.left.and.right")
                    CardDivider().padding(.vertical, 12)
                    feature("New windows join next to you", detail: "A new window opens beside the one you're using. Nothing gets squeezed.", symbol: "plus.rectangle.on.rectangle")
                    CardDivider().padding(.vertical, 12)
                    feature("One strip per display", detail: "Each display scrolls on its own. Use Next Display to send a window to another strip.", symbol: "display.2")
                }
                OnboardingShortcutsCard(stripLesson: true)
            }
        case .completion:
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Try it now")
                OnboardingShortcutsCard()
                Text("Find every shortcut in Help. Make them your own in Shortcuts.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var permissionContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(inset: 16) {
                HStack(spacing: 12) {
                    IconDisc(systemImage: "app.badge", diameter: 36)
                    RowLabel(title: AppPaths.appName, subtitle: "Move and resize your windows", emphasized: true)
                    CheckGlyph(state: permissionTrusted ? .pass : .unknown)
                    Text(permissionTrusted ? "Allowed" : "Waiting for permission")
                        .font(.system(size: 11))
                        .foregroundStyle(permissionTrusted ? Theme.success : Theme.textSecondary)
                }
            }
            InfoNote(text: "Open Accessibility settings and turn on \(AppPaths.appName). If a window helper is listed too, allow it as well. This page checks for permission automatically.")
            if !permissionTrusted {
                HStack(spacing: 6) {
                    Text("Already on, but still not ticked?")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Button("Repair Permission…") { confirmsRepair = true }
                        .buttonStyle(LinkButtonStyle())
                }
            }
        }
    }

    private func feature(_ title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            IconDisc(systemImage: symbol, diameter: 34)
            RowLabel(title: title, subtitle: detail, emphasized: true)
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Button(action: primaryAction) {
                HStack(spacing: 8) {
                    Text(primaryTitle)
                    if step == .welcome || step == .completion { Image(systemName: "arrow.right") }
                }
                .frame(minWidth: 190)
            }
            .buttonStyle(PrimaryButtonStyle(large: true))
            .keyboardShortcut(.defaultAction)

            if step == .permission, !permissionTrusted {
                if openedPermissionSettings {
                    Button("Set Up Later") { advance() }
                        .buttonStyle(LinkButtonStyle())
                }
                Text("Window control needs this permission. You can allow it later in Mac Setup.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            } else if step == .macSetup, !macSetupReady {
                Text("You can finish this later in Mac Setup.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .multilineTextAlignment(.center)
    }

    private var title: String {
        switch step {
        case .welcome: return "Welcome to \(AppPaths.appName)"
        case .permission: return "Allow \(AppPaths.appName) to Move Windows"
        case .macSetup: return "Set Up Your Mac"
        case .strip: return "Your Windows Live on a Strip"
        case .completion: return ready ? "You're All Set" : "Almost There"
        }
    }

    private var subtitle: String {
        switch step {
        case .welcome:
            return "Your windows sit side by side on a strip you can scroll. A minute of setup, then you're ready."
        case .permission:
            return "Accessibility permission lets the app move and resize windows. You can turn it off in macOS settings at any time."
        case .macSetup:
            return macSetupReady
                ? "The macOS settings \(AppPaths.appName) needs are ready."
                : "A few settings need attention. Each check turns green when its setting is right."
        case .strip:
            return "Your screen shows part of a wider strip. Switch to a window and the strip slides to bring it into view."
        case .completion:
            if ready, engine.state.isRunning { return "\(AppPaths.appName) is running. Try these shortcuts now." }
            if !permissionTrusted { return "Allow Accessibility before moving windows. Mac Setup will help you finish whenever you're ready." }
            if !separateSpacesReady { return "Turn on “Displays have separate Spaces”, then log out and back in. Mac Setup shows you where." }
            return preferences.startEngineAutomatically
                ? "Click below to start \(AppPaths.appName). Then try these shortcuts."
                : "You're ready. Start the window manager from Overview whenever you like."
        }
    }

    private var headerSymbol: String {
        switch step {
        case .welcome: return "rectangle.3.offgrid"
        case .permission: return permissionTrusted ? "checkmark.shield.fill" : "hand.raised.fill"
        case .macSetup: return macSetupReady ? "checkmark.circle" : "gearshape.2"
        case .strip: return "rectangle.split.3x1"
        case .completion: return ready ? "checkmark.circle" : "exclamationmark.triangle"
        }
    }

    private var headerTint: Color {
        if step == .completion { return ready ? Theme.success : Theme.warning }
        if step == .permission, permissionTrusted { return Theme.success }
        return Theme.accent
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return "Get Started"
        case .permission: return permissionTrusted ? "Continue" : "Allow \(AppPaths.appName) to Move Windows"
        case .macSetup: return macSetupReady ? "Continue" : "Continue Without Fixing"
        case .strip: return "Continue"
        case .completion: return "Start Using \(AppPaths.appName)"
        }
    }

    private var permissionTrusted: Bool {
        #if DEBUG
        if isSnapshot, ProcessInfo.processInfo.environment["OYM_ONBOARDING_PERMISSION"] == "missing" { return false }
        #endif
        return permissions.isTrusted
    }

    private var macSetupReady: Bool {
        #if DEBUG
        if isSnapshot, let checks = MacSetupSnapshotSamples.checks {
            return !checks.contains { !$0.isRecommendation && ($0.state == .fail || $0.state == .warning) }
        }
        #endif
        return setup.allPassing
    }

    private var separateSpacesReady: Bool {
        #if DEBUG
        if isSnapshot, let checks = MacSetupSnapshotSamples.checks {
            return !checks.contains { $0.id == "separateSpaces" && $0.state != .pass }
        }
        #endif
        return setup.separateSpacesReady
    }

    private var ready: Bool { permissionTrusted && separateSpacesReady }

    private func primaryAction() {
        guard !isSnapshot else { return }
        if step == .permission, !permissionTrusted {
            openedPermissionSettings = true
            permissions.request()
            permissions.openAccessibilitySettings()
            permissions.waitForGrant(onGranted: permissionGranted)
        } else if step == .completion {
            permissions.refresh()
            setup.refresh()
            state.completeOnboarding()
            if ready, preferences.startEngineAutomatically, !engine.state.isRunning, !engine.state.isBusy {
                state.startEngineFromUI()
            }
        } else {
            advance()
        }
    }

    private func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { step = next }
    }

    private func permissionGranted() {
        if step == .permission, !isSnapshot { advance() }
    }

    private func enterStep() {
        if step != .macSetup { stopSetupMonitoring() }
        guard !isSnapshot else { return }
        if step == .permission {
            permissions.refresh()
            if !permissionTrusted { permissions.waitForGrant(onGranted: permissionGranted) }
        } else if step == .macSetup {
            preferences.macSetupIntroduced = true
            setup.refresh()
            if !monitoringSetup {
                setup.beginMonitoring()
                monitoringSetup = true
            }
        }
    }

    private func stopSetupMonitoring() {
        if monitoringSetup {
            setup.endMonitoring()
            monitoringSetup = false
        }
    }
}

private enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome, permission, macSetup, strip, completion
    var id: Int { rawValue }
}
