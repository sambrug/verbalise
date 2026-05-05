import Foundation

// Resolve project directory from this binary's location
// Binary is at: .app/Contents/MacOS/launcher
// Project dir is the .app's parent directory
let binaryPath = CommandLine.arguments[0]
let binaryURL = URL(fileURLWithPath: binaryPath).standardized
let macosDir = binaryURL.deletingLastPathComponent()
let contentsDir = macosDir.deletingLastPathComponent()
let appDir = contentsDir.deletingLastPathComponent()

// The .app lives inside the project directory
var projectDir = appDir.deletingLastPathComponent()
if FileManager.default.fileExists(atPath: appDir.appendingPathComponent("menubar.py").path) {
    projectDir = appDir
} else if FileManager.default.fileExists(atPath: appDir.deletingLastPathComponent().appendingPathComponent("menubar.py").path) {
    projectDir = appDir.deletingLastPathComponent()
}

let venvPython = projectDir.appendingPathComponent(".venv/bin/python3").path
let menubarScript = projectDir.appendingPathComponent("menubar.py").path
let requirements = projectDir.appendingPathComponent("requirements.txt").path
let venvDir = projectDir.appendingPathComponent(".venv").path

// Auto-setup: create venv if missing
if !FileManager.default.fileExists(atPath: venvPython) {
    // Find system python3
    let whichTask = Process()
    let whichPipe = Pipe()
    whichTask.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    whichTask.arguments = ["python3"]
    whichTask.standardOutput = whichPipe
    try? whichTask.run()
    whichTask.waitUntilExit()
    let sysPython = String(data: whichPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    if sysPython.isEmpty {
        // Show alert
        let alertScript = "display alert \"Python 3 not found\" message \"Install Python 3.11+ from python.org or via Homebrew.\" as critical"
        Process.launchedProcess(launchPath: "/usr/bin/osascript", arguments: ["-e", alertScript]).waitUntilExit()
        exit(1)
    }

    // Create venv
    let venvTask = Process()
    venvTask.executableURL = URL(fileURLWithPath: sysPython)
    venvTask.arguments = ["-m", "venv", venvDir]
    try? venvTask.run()
    venvTask.waitUntilExit()

    // Install pip + deps
    let pipUpgrade = Process()
    pipUpgrade.executableURL = URL(fileURLWithPath: projectDir.appendingPathComponent(".venv/bin/pip").path)
    pipUpgrade.arguments = ["install", "--quiet", "--upgrade", "pip"]
    try? pipUpgrade.run()
    pipUpgrade.waitUntilExit()

    let pipInstall = Process()
    pipInstall.executableURL = URL(fileURLWithPath: projectDir.appendingPathComponent(".venv/bin/pip").path)
    pipInstall.arguments = ["install", "--quiet", "-r", requirements]
    try? pipInstall.run()
    pipInstall.waitUntilExit()

    if pipInstall.terminationStatus != 0 {
        try? FileManager.default.removeItem(atPath: venvDir)
        let alertScript = "display alert \"Setup failed\" message \"Could not install dependencies. Check your internet connection.\" as critical"
        Process.launchedProcess(launchPath: "/usr/bin/osascript", arguments: ["-e", alertScript]).waitUntilExit()
        exit(1)
    }
}

// Launch menubar.py and wait
let task = Process()
task.executableURL = URL(fileURLWithPath: venvPython)
task.arguments = [menubarScript]
try! task.run()
task.waitUntilExit()
