//
//  TVROMImportPolicy.swift
//  DeltaTV
//
//  Copyright © 2026 Delta contributors. Licensed under AGPL-3.0.
//

import Foundation

enum TVROMImportPolicy
{
    static let maximumBytes = 512 * 1024 * 1024

    static func validateROM(at url: URL) throws
    {
        guard let system = TVSystem.system(forExtension: url.pathExtension) else { throw TVROMImportError.unsupportedFile }
        if system == .gb || system == .gbc { try validateGameBoyROM(at: url); return }
        var current = url
        current.removeAllCachedResourceValues()
        let values = try current.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 16, size <= system.maximumROMBytes else { throw TVROMImportError.invalidROM }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        func read(_ offset: Int, _ count: Int) throws -> [UInt8] {
            guard offset >= 0, count >= 0, offset <= size, count <= size - offset else { throw TVROMImportError.invalidROM }
            try handle.seek(toOffset: UInt64(offset))
            guard let data = try handle.read(upToCount: count), data.count == count else { throw TVROMImportError.invalidROM }
            return Array(data)
        }
        func little32(_ bytes: [UInt8], _ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
        }
        let header = try read(0, min(0x200, size))
        var valid = false
        switch system {
        case .nes:
            if header.prefix(4) == [0x4E, 0x45, 0x53, 0x1A] {
                let nes2 = header[7] & 0x0C == 0x08
                func bankSize(_ low: UInt8, _ high: UInt8, _ unit: Int) -> Int? {
                    if nes2 && high == 15 {
                        let exponent = Int(low >> 2)
                        guard exponent < 27 else { return nil }
                        return (1 << exponent) * (Int(low & 3) * 2 + 1)
                    }
                    return (Int(low) | (nes2 ? Int(high) << 8 : 0)) * unit
                }
                if let prg = bankSize(header[4], header[9] & 15, 16384), let chr = bankSize(header[5], header[9] >> 4, 8192) {
                    valid = prg > 0 && size >= 16 + (header[6] & 4 == 0 ? 0 : 512) + prg + chr
                }
            }
        case .snes:
            let copier = size % 1024 == 512 ? 512 : 0
            if (size - copier).isMultiple(of: 1024) {
                for offset in [0x7FC0, 0xFFC0, 0x40FFC0] where offset + copier + 64 <= size {
                    let h = try read(offset + copier, 64)
                    let complement = Int(h[28]) | Int(h[29]) << 8
                    let checksum = Int(h[30]) | Int(h[31]) << 8
                    if complement ^ checksum == 0xFFFF && h[21] & 0x20 != 0 && h[61] >= 0x80 { valid = true }
                }
            }
        case .gba:
            if header.count >= 0xC0 {
                let checksum = header[0xA0...0xBC].reduce(UInt8(0)) { $0 &- $1 } &- 0x19
                valid = header[0xB2] == 0x96 && checksum == header[0xBD] && size >= 0xC0
            }
        case .n64:
            valid = [[0x80,0x37,0x12,0x40], [0x37,0x80,0x40,0x12], [0x40,0x12,0x37,0x80]].contains(Array(header.prefix(4))) && size >= 4096 && size.isMultiple(of: 4)
        case .ds:
            if header.count >= 0x160 {
                let arm9 = little32(header, 0x20), arm9Size = little32(header, 0x2C)
                let arm7 = little32(header, 0x30), arm7Size = little32(header, 0x3C)
                valid = arm9 >= 0x200 && arm7 >= 0x200 && arm9Size > 0 && arm7Size > 0
                    && arm9 <= size && arm9Size <= size - arm9 && arm7 <= size && arm7Size <= size - arm7
                    && [0, 2].contains(header[0x12]) // DS and DS-compatible enhanced cartridges; no DSi-only firmware boot.
            }
        case .genesis:
            valid = size >= 0x200 && size.isMultiple(of: 2) && header[0x100..<0x104].elementsEqual("SEGA".utf8)
                && !header[0x180..<0x182].elementsEqual("BR".utf8) // Sega CD boot ROM, not a cartridge.
                && !header[0x100..<0x109].elementsEqual("SEGA PICO".utf8)
        case .gb, .gbc: break
        }
        guard valid else { throw TVROMImportError.invalidROM }
    }

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
              byteCount <= 16 * 1024 * 1024 else
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
            return "Use a direct supported ROM download link. Compressed archives and web pages cannot be imported."
        case .invalidResponse:
            return "The address did not return a secure ROM download. Use a direct HTTPS file link."
        case .httpStatus(let code):
            return "The download server returned HTTP \(code). Check the link and try again."
        case .tooLarge:
            return "The download exceeds this system’s import limit."
        case .invalidROM:
            return "The file does not have a complete supported cartridge header and data."
        }
    }
}
