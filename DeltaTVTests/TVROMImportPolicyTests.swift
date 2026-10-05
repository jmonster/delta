import Foundation

private enum ImportTestFailure: Error
{
    case failed(String)
}

private func require(_ value: @autoclosure () -> Bool, _ message: String) throws
{
    if !value() { throw ImportTestFailure.failed(message) }
}

private func rejects(_ message: String, _ operation: () throws -> Void) throws
{
    do { try operation() }
    catch is TVROMImportError { return }
    throw ImportTestFailure.failed(message)
}

@main
struct TVROMImportPolicyTests
{
    static func main() throws
    {
        let allowed: Set<String> = ["gb", "gbc"]
        let valid = try TVROMImportPolicy.validatedURL(" https://example.com/homebrew.GBC?download=1 \n", allowedExtensions: allowed)
        try require(valid.pathExtension == "GBC", "URL normalization lost the filename")
        for invalid in ["http://example.com/a.gb", "file:///tmp/a.gb", "https://user:secret@example.com/a.gb", "https://example.com/a.gb#fragment", "example.com/a.gb", "https:///a.gb"]
        {
            try rejects("Unsafe URL accepted: \(invalid)") { _ = try TVROMImportPolicy.validatedURL(invalid, allowedExtensions: allowed) }
        }
        for invalid in ["https://example.com/a.zip", "https://example.com/download", "https://example.com/a.nes"]
        {
            try rejects("Unsupported extension accepted") { _ = try TVROMImportPolicy.validatedURL(invalid, allowedExtensions: allowed) }
        }
        try rejects("An unlinked core could import ROMs") { _ = try TVROMImportPolicy.validatedURL("https://example.com/a.gb", allowedExtensions: []) }
        try require(!TVROMImportPolicy.isSecureURL(URL(string: "http://example.com/redirect")!), "Redirect policy allowed HTTP")
        try require(!TVROMImportPolicy.isSecureURL(URL(string: "https://user:password@example.com/redirect")!), "Redirect policy allowed credentials")
        try require(TVROMImportPolicy.isSecureURL(URL(string: "https://cdn.example.com/redirect")!), "Secure CDN redirect rejected")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DeltaTVImportTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rom = directory.appendingPathComponent("homebrew.gb")

        // Synthetic cartridge structure, not an executable copyrighted game.
        // No Nintendo logo is copied into the fixture.
        var bytes = Data(repeating: 0, count: 32 * 1024)
        updateChecksum(&bytes)
        try bytes.write(to: rom)
        try TVROMImportPolicy.validateGameBoyROM(at: rom)

        try Data(bytes.prefix(0x100)).write(to: rom)
        try rejects("A missing header was accepted") { try TVROMImportPolicy.validateGameBoyROM(at: rom) }

        try Data(bytes.prefix(16 * 1024)).write(to: rom)
        try rejects("A truncated cartridge was accepted") { try TVROMImportPolicy.validateGameBoyROM(at: rom) }

        bytes[0x134] = 1
        try bytes.write(to: rom)
        try rejects("A corrupt header checksum was accepted") { try TVROMImportPolicy.validateGameBoyROM(at: rom) }
        bytes[0x134] = 0

        bytes[0x148] = 0xFF
        updateChecksum(&bytes)
        try bytes.write(to: rom)
        try rejects("An invalid cartridge size was accepted") { try TVROMImportPolicy.validateGameBoyROM(at: rom) }

        bytes[0x148] = 1
        updateChecksum(&bytes)
        try bytes.write(to: rom)
        try rejects("A declared size larger than the download was accepted") { try TVROMImportPolicy.validateGameBoyROM(at: rom) }

        bytes[0x148] = 0
        updateChecksum(&bytes)
        bytes.append(1)
        try bytes.write(to: rom)
        try rejects("A partial extra ROM bank was accepted") { try TVROMImportPolicy.validateGameBoyROM(at: rom) }

        try Data(repeating: 0, count: TVROMImportPolicy.maximumBytes + 1).write(to: rom)
        try rejects("The maximum ROM size was not enforced") { try TVROMImportPolicy.validateGameBoyROM(at: rom) }

        try rejects("A directory was treated as a ROM") { try TVROMImportPolicy.validateGameBoyROM(at: directory) }
        print("PASS: import URL, redirect, extension, size, header, checksum, and homebrew policy checks")
    }

    private static func updateChecksum(_ bytes: inout Data)
    {
        var checksum: UInt8 = 0
        for byte in bytes[0x134...0x14C] { checksum = checksum &- byte &- 1 }
        bytes[0x14D] = checksum
    }
}
