import AppKit

// `OpenYourMac --snapshot <dir>` renders every page to PNG files and exits
// without starting the engine or showing UI. Used to check the design.
if let index = CommandLine.arguments.firstIndex(of: "--snapshot") {
    let dir = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : "snapshots"
    // Fixed viewport snapshots use the normal scrolling layout, e.g. 860x560.
    var viewport: CGSize?
    if let sizeIndex = CommandLine.arguments.firstIndex(of: "--snapshot-size") {
        let parts = CommandLine.arguments.dropFirst(sizeIndex + 1).first?.split(separator: "x") ?? []
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
              width.isFinite, height.isFinite, (860...4000).contains(width), (560...8000).contains(height) else {
            fputs("--snapshot-size requires WIDTHxHEIGHT (minimum 860x560).\n", stderr)
            exit(2)
        }
        viewport = CGSize(width: width, height: height)
    }
    MainActor.assumeIsolated {
        SnapshotRenderer.run(outputDirectory: URL(fileURLWithPath: dir), viewport: viewport)
    }
    exit(0)
}

if MainActor.assumeIsolated({ CoreDiagnostics.runIfRequested() }) { exit(0) }

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
