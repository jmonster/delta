import Foundation
@main enum TVRealROMImportPolicyTests {
    static func main() throws {
        guard let path = ProcessInfo.processInfo.environment["LOCAL_IMPORT_ROM_DIRECTORY"] else {
            print("SKIP: set LOCAL_IMPORT_ROM_DIRECTORY to an authorized local cartridge directory")
            return
        }
        let inputs = URL(fileURLWithPath: path, isDirectory: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DeltaTVRealImport-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var count = 0
        for url in try FileManager.default.contentsOfDirectory(at: inputs, includingPropertiesForKeys: nil) where TVSystem.system(forExtension: url.pathExtension) != nil {
            try TVROMImportPolicy.validateROM(at: url)
            let bad = temporary.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: bad)
            let file = try FileHandle(forWritingTo: bad)
            try file.truncate(atOffset: 8); try file.close()
            do { try TVROMImportPolicy.validateROM(at: bad); fatalError("Truncated actual ROM was accepted") }
            catch TVROMImportError.invalidROM {}
            print("PASS: real \(url.pathExtension) header and truncated-copy rejection")
            count += 1
        }
        guard count > 0 else { fatalError("Missing actual system inputs") }
        if let rejected = ProcessInfo.processInfo.environment["LOCAL_IMPORT_REJECTED_ROM"] {
            do { try TVROMImportPolicy.validateROM(at: URL(fileURLWithPath: rejected)); fatalError("Unsupported actual input was accepted") }
            catch TVROMImportError.invalidROM { print("PASS: unsupported actual cartridge/firmware rejection") }
        }
    }
}
