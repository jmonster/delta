//
//  TVROMImportPolicy.swift
//  DeltaTV
//
//  Copyright © 2026 Delta contributors. Licensed under AGPL-3.0.
//

import Foundation

enum TVROMImportPolicy
{
    static let maximumBytes = 16 * 1024 * 1024

    static func validatedURL(_ text: String, allowedExtensions: Set<String>) throws -> URL
    {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), isSecureURL(url),
              url.fragment == nil else
        {
            throw TVROMImportError.invalidURL
        }
        guard allowedExtensions.contains(url.pathExtension.lowercased()) else
        {
            throw TVROMImportError.unsupportedFile
        }
        return url
    }

    static func isSecureURL(_ url: URL) -> Bool
    {
        url.scheme?.lowercased() == "https" && !(url.host?.isEmpty ?? true)
            && url.user == nil && url.password == nil
    }

    /// Validate cartridge structure without requiring Nintendo's copyrighted
    /// logo, so independently produced homebrew remains importable.
    static func validateGameBoyROM(at url: URL) throws
    {
        // Foundation caches URL metadata; validate the current file after download or replacement.
        var currentURL = url
        currentURL.removeAllCachedResourceValues()
        let values = try currentURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let byteCount = values.fileSize, byteCount >= 0x150,
              byteCount <= maximumBytes else
        {
            throw TVROMImportError.invalidROM
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 0x150), header.count == 0x150 else
        {
            throw TVROMImportError.invalidROM
        }

        let expectedBytes: Int
        switch header[0x148]
        {
        case 0...8: expectedBytes = 32 * 1024 << Int(header[0x148])
        case 0x52: expectedBytes = 72 * 16 * 1024
        case 0x53: expectedBytes = 80 * 16 * 1024
        case 0x54: expectedBytes = 96 * 16 * 1024
        default: throw TVROMImportError.invalidROM
        }
        guard byteCount >= expectedBytes, byteCount.isMultiple(of: 16 * 1024) else
        {
            throw TVROMImportError.invalidROM
        }

        var checksum: UInt8 = 0
        for byte in header[0x134...0x14C]
        {
            checksum = checksum &- byte &- 1
        }
        guard checksum == header[0x14D] else { throw TVROMImportError.invalidROM }
    }
}

enum TVROMImportError: LocalizedError
{
    case invalidURL
    case unsupportedFile
    case invalidResponse
    case httpStatus(Int)
    case tooLarge
    case invalidROM

    var errorDescription: String?
    {
        switch self
        {
        case .invalidURL:
            return "Enter a complete https:// address without a username, password, or fragment."
        case .unsupportedFile:
            return "Use a direct .gb or .gbc download link. Compressed archives and web pages cannot be imported."
        case .invalidResponse:
            return "The address did not return a secure ROM download. Use a direct HTTPS file link."
        case .httpStatus(let code):
            return "The download server returned HTTP \(code). Check the link and try again."
        case .tooLarge:
            return "The download exceeds the 16 MB import limit."
        case .invalidROM:
            return "The file is not a complete Game Boy or Game Boy Color ROM with a valid cartridge header."
        }
    }
}

