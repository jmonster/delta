//
//  TVROMDownloader.swift
//  DeltaTV
//
//  Copyright © 2026 Delta contributors. Licensed under AGPL-3.0.
//

import Foundation

/// A download is a temporary input, not the authoritative library. The caller
/// must import it into TVLibraryStore, then remove the returned temporary file.
enum TVROMDownloader
{
    // Keep streaming, file writes, and cartridge validation off the UI actor,
    // including when the caller enables Swift's nonisolated-nonsending mode.
    @concurrent
    static func download(_ url: URL, allowedExtensions: Set<String> = ["gb", "gbc"]) async throws -> URL
    {
        let validatedURL = try TVROMImportPolicy.validatedURL(url.absoluteString, allowedExtensions: allowedExtensions)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: TVHTTPSRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: validatedURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              let responseURL = response.url, TVROMImportPolicy.isSecureURL(responseURL) else
        {
            throw TVROMImportError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else
        {
            throw TVROMImportError.httpStatus(response.statusCode)
        }
        guard response.expectedContentLength <= Int64(TVROMImportPolicy.maximumBytes) else
        {
            throw TVROMImportError.tooLarge
        }
        if let mimeType = response.mimeType?.lowercased(),
           mimeType.hasPrefix("text/") || mimeType == "application/json" || mimeType == "application/xhtml+xml"
        {
            throw TVROMImportError.invalidResponse
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DeltaTVImports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(validatedURL.pathExtension.lowercased())
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else
        {
            throw CocoaError(.fileWriteUnknown)
        }

        var completed = false
        defer
        {
            if !completed { try? FileManager.default.removeItem(at: destination) }
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var byteCount = 0
        for try await byte in bytes
        {
            try Task.checkCancellation()
            byteCount += 1
            guard byteCount <= TVROMImportPolicy.maximumBytes else { throw TVROMImportError.tooLarge }
            buffer.append(byte)
            if buffer.count == 64 * 1024
            {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        try handle.synchronize()
        try Task.checkCancellation()
        try TVROMImportPolicy.validateGameBoyROM(at: destination)
        completed = true
        return destination
    }
}

/// Refuse HTTP downgrade and URL credentials on every redirect. The ephemeral
/// session neither saves credentials/cookies nor exposes a local file server.
private final class TVHTTPSRedirectDelegate: NSObject, URLSessionTaskDelegate
{
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        guard let url = request.url, TVROMImportPolicy.isSecureURL(url) else
        {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
