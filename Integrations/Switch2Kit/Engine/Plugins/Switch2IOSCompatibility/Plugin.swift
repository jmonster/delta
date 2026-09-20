import Foundation
import PackagePlugin

/// Generate one reviewed compatibility source without dirtying the pinned SDK.
/// The command's declared inputs/outputs let SwiftPM and Xcode rebuild it when
/// needed; the Python tool refuses any unexpected upstream source revision.
@main
struct Switch2IOSCompatibility: BuildToolPlugin
{
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command]
    {
        let script = context.package.directoryURL.appendingPathComponent("Compatibility/patch_session.py")
        let source = context.package.directoryURL.appendingPathComponent("Vendor/Switch2Kit/Sources/Switch2Kit/Bluetooth/ControllerSession.swift")
        let output = context.pluginWorkDirectoryURL.appendingPathComponent("ControllerSession.swift")
        return [.buildCommand(
            displayName: "Generate pinned Switch2Kit Apple-platform compatibility source",
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [script.path, source.path, output.path],
            inputFiles: [script, source],
            outputFiles: [output]
        )]
    }
}
