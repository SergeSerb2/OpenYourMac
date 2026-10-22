import AppKit
import SwiftUI

struct HelpAbout: View {
    var body: some View {
        PageSection("About \(AppPaths.appName)", caption: "Free, open-source window management for macOS") {
            Card(inset: 16) {
                HStack(spacing: 14) {
                    BrandMark(size: 56)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(AppPaths.appName).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.textPrimary)
                        Text("Version \(AppPaths.appVersion)").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        Text("Horizontal window tiling for macOS").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    }
                }
                CardDivider().padding(.vertical, 16)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Philosophy").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("A workspace should give your windows room to breathe. \(AppPaths.appName) keeps them at readable sizes on a horizontal strip that you can scroll. This is especially useful on smaller screens, where fitting everything at once would make each window too narrow.")
                    Text("Open Source").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary).padding(.top, 8)
                    Text("\(AppPaths.appName) is free software under the MIT License. Its window engine is built on Paneru by Karinushka, also released under the MIT License.")
                    DisclosureRow("MIT License") {
                        Text(Self.license).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                    FlowLayout(spacing: 10, lineSpacing: 10) {
                        link("\(AppPaths.appName) on GitHub", icon: "chevron.left.forwardslash.chevron.right", url: AppPaths.repositoryURL)
                        link("Paneru on GitHub", icon: "chevron.left.forwardslash.chevron.right", url: AppPaths.paneruURL)
                        link("Report Issue", icon: "envelope", url: AppPaths.issuesURL)
                    }
                }
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func link(_ title: String, icon: String, url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: { Label(title, systemImage: icon) }
            .buttonStyle(TintedButtonStyle())
    }

    private static let license = """
    MIT License

    Copyright (c) 2026 OpenYourMac contributors

    Paneru notice:
    Copyright (c) 2025 Karinushka@github

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in
    all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
    THE SOFTWARE.
    """
}
