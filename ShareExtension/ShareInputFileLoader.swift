import Foundation
import UniformTypeIdentifiers

enum ShareInputError: LocalizedError {
    case noFiles
    case sharedContainerUnavailable
    case unsupportedItem
    case vpnPermissionRequired
    case systemVPNModeRequired
    case loginRequired
    case machineAuthRequired
    case vpnUnavailable(String)
    case backendUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noFiles: return "No files were shared"
        case .sharedContainerUnavailable: return "Shared app container is unavailable"
        case .unsupportedItem: return "This item cannot be sent as a file"
        case .vpnPermissionRequired:
            return "AwgScale needs VPN permission before Share Sheet sending can start it. Open AwgScale, tap Connect, and allow the VPN prompt."
        case .systemVPNModeRequired:
            return "Share Sheet Taildrop requires System VPN mode. Open AwgScale and switch Connection Mode to System VPN, then share again."
        case .loginRequired:
            return "AwgScale is not logged in. Open AwgScale and sign in, then share again."
        case .machineAuthRequired:
            return "This device is waiting for tailnet approval. Open AwgScale to view the approval status, or approve it from the admin console."
        case .vpnUnavailable(let message): return "VPN could not be started automatically: \(message). Open AwgScale to finish connecting, then share again."
        case .backendUnavailable(let message): return "Taildrop devices are not ready yet: \(message). Open AwgScale to finish connecting, then share again."
        }
    }

    var opensContainingApp: Bool {
        switch self {
        case .vpnPermissionRequired, .systemVPNModeRequired, .loginRequired, .machineAuthRequired, .vpnUnavailable, .backendUnavailable:
            return true
        case .noFiles, .sharedContainerUnavailable, .unsupportedItem:
            return false
        }
    }

    var recoveryButtonTitle: String? {
        switch self {
        case .vpnPermissionRequired:
            return "Open AwgScale to Allow VPN"
        case .systemVPNModeRequired:
            return "Open AwgScale to Use System VPN"
        case .loginRequired:
            return "Open AwgScale to Log In"
        case .machineAuthRequired:
            return "Open AwgScale for Approval"
        case .vpnUnavailable, .backendUnavailable:
            return "Open AwgScale"
        case .noFiles, .sharedContainerUnavailable, .unsupportedItem:
            return nil
        }
    }
}

enum ShareInputFileLoader {
    static func copyInputFiles(from extensionContext: NSExtensionContext?) async throws -> [URL] {
        guard let containerURL = sharedContainerURL else {
            throw ShareInputError.sharedContainerUnavailable
        }
        let destinationDirectory = containerURL
            .appendingPathComponent("share-extension-input", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []

        do {
            var copiedFiles: [URL] = []
            for provider in providers {
                try Task.checkCancellation()
                if let fileURL = try await copyFile(from: provider, to: destinationDirectory) {
                    try Task.checkCancellation()
                    copiedFiles.append(fileURL)
                }
            }

            try Task.checkCancellation()
            guard !copiedFiles.isEmpty else {
                throw ShareInputError.noFiles
            }
            return copiedFiles
        } catch {
            try? FileManager.default.removeItem(at: destinationDirectory)
            throw error
        }
    }

    private static func copyFile(from provider: NSItemProvider, to directory: URL) async throws -> URL? {
        guard let typeIdentifier = fileTypeIdentifier(from: provider) else {
            return nil
        }
        let suggestedName = provider.suggestedName

        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { temporaryURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let temporaryURL else {
                    continuation.resume(returning: nil)
                    return
                }

                do {
                    let destination = try uniqueDestinationURL(
                        in: directory,
                        suggestedName: suggestedName,
                        fallbackName: temporaryURL.lastPathComponent
                    )
                    try FileManager.default.copyItem(at: temporaryURL, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func fileTypeIdentifier(from provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .item)
        }
    }

    private static func uniqueDestinationURL(in directory: URL, suggestedName: String?, fallbackName: String) throws -> URL {
        let safeName = safeSharedFileName(suggestedName: suggestedName, fallbackName: fallbackName)
        let baseName = (safeName as NSString).deletingPathExtension
        let pathExtension = (safeName as NSString).pathExtension

        var candidate = directory.appendingPathComponent(safeName, isDirectory: false)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let nextName = pathExtension.isEmpty ? "\(baseName)-\(suffix)" : "\(baseName)-\(suffix).\(pathExtension)"
            candidate = directory.appendingPathComponent(nextName, isDirectory: false)
            suffix += 1
        }
        return candidate
    }
}
