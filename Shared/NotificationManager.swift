import Foundation
import UserNotifications

struct HealthNotificationDescriptor: Equatable {
    let identifier: String
    let title: String
    let message: String
}

func parsedTailscaleTimestamp(_ value: String?) -> Date? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractionalFormatter.date(from: trimmed) {
        return date
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: trimmed)
}

private func stableNotificationIdentifierComponent(_ value: String) -> String {
    // FNV-1a gives us a deterministic, compact identifier without retaining
    // arbitrary server-provided notification text in system request IDs.
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(format: "%016llx", hash)
}

func healthNotificationIdentifier(
    for warningCode: String,
    title: String = "",
    message: String = ""
) -> String {
    let payload = "\(warningCode)\u{0}\(title)\u{0}\(message)"
    return "health-warning-\(stableNotificationIdentifierComponent(payload))"
}

func highSeverityHealthNotifications(from health: HealthState?) -> [HealthNotificationDescriptor] {
    guard let warnings = health?.Warnings else { return [] }

    return warnings.compactMap { code, warning in
        guard warning.Severity?.lowercased() == "high" else { return nil }
        let title = warning.Title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = warning.Text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = title?.isEmpty == false ? title! : "Network Health Warning"
        let resolvedMessage = message?.isEmpty == false
            ? message!
            : "AwgScale reported a high-severity network health warning."
        return HealthNotificationDescriptor(
            identifier: healthNotificationIdentifier(
                for: code,
                title: resolvedTitle,
                message: resolvedMessage
            ),
            title: resolvedTitle,
            message: resolvedMessage
        )
    }
    .sorted { $0.identifier < $1.identifier }
}

/// Notification manager for AwgScale.
/// Handles key expiration reminders, health warnings, and file transfer notifications.
@MainActor
class NotificationManager: ObservableObject {
    
    static let shared = NotificationManager()
    
    @Published var isAuthorized: Bool = false
    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined
    
    private let center = UNUserNotificationCenter.current()
    private var stateSyncGeneration: UInt64 = 0
    private var latestDesiredKeyExpiryIdentifier: String?
    private var latestDesiredHealthIdentifiers: Set<String> = []
    private var submittedNotificationIdentifiers: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(
                Array(submittedNotificationIdentifiers).sorted(),
                forKey: Self.submittedIdentifiersDefaultsKey
            )
        }
    }

    private static let legacyKeyExpiryWarningIdentifier = "key-expiry-warning"
    private static let legacyKeyExpiredIdentifier = "key-expired"
    private static let keyExpiryWarningIdentifierPrefix = "key-expiry-warning-"
    private static let keyExpiredIdentifierPrefix = "key-expired-"
    private static let keyExpiryFingerprintDefaultsKey =
        "top.yesican.awgscale.notifications.key-expiry.v1"
    private static let submittedIdentifiersDefaultsKey =
        "top.yesican.awgscale.notifications.submitted-identifiers.v1"
    private static let healthIdentifierPrefix = "health-warning-"
    
    // MARK: - Notification Categories
    
    static let keyExpiryCategory = "KEY_EXPIRY"
    static let healthWarningCategory = "HEALTH_WARNING"
    static let taildropCategory = "TAILDROP"
    static let reauthCategory = "REAUTH"
    
    // MARK: - Initialization
    
    init() {
        submittedNotificationIdentifiers = Set(
            UserDefaults.standard.stringArray(forKey: Self.submittedIdentifiersDefaultsKey) ?? []
        )
        Task {
            await checkAuthorizationStatus()
            setupCategories()
        }
    }
    
    // MARK: - Authorization
    
    func checkAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
        isAuthorized = Self.allowsNotificationDelivery(settings.authorizationStatus)
    }
    
    func requestAuthorization() async -> Bool {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            await checkAuthorizationStatus()
            return isAuthorized
        } catch {
            return false
        }
    }

    func requestAuthorizationIfNeeded() async {
        await checkAuthorizationStatus()
        guard authorizationStatus == .notDetermined else { return }
        _ = await requestAuthorization()
    }
    
    // MARK: - Categories Setup
    
    private func setupCategories() {
        // Key expiry actions
        let renewAction = UNNotificationAction(
            identifier: "RENEW_KEY",
            title: "Renew Now",
            options: [.foreground]
        )
        let dismissAction = UNNotificationAction(
            identifier: "DISMISS",
            title: "Remind Later"
        )
        
        let keyExpiryCategory = UNNotificationCategory(
            identifier: Self.keyExpiryCategory,
            actions: [renewAction, dismissAction],
            intentIdentifiers: []
        )
        
        // Health warning actions
        let viewAction = UNNotificationAction(
            identifier: "VIEW_HEALTH",
            title: "View Details",
            options: [.foreground]
        )
        
        let healthCategory = UNNotificationCategory(
            identifier: Self.healthWarningCategory,
            actions: [viewAction, dismissAction],
            intentIdentifiers: []
        )
        
        // Taildrop actions
        let openAction = UNNotificationAction(
            identifier: "OPEN_TAILDROP",
            title: "View Files",
            options: [.foreground]
        )
        
        let taildropCategory = UNNotificationCategory(
            identifier: Self.taildropCategory,
            actions: [openAction],
            intentIdentifiers: []
        )
        
        // Reauth actions
        let reauthAction = UNNotificationAction(
            identifier: "REAUTH",
            title: "Re-authenticate",
            options: [.foreground]
        )
        
        let reauthCategory = UNNotificationCategory(
            identifier: Self.reauthCategory,
            actions: [reauthAction, dismissAction],
            intentIdentifiers: []
        )
        
        center.setNotificationCategories([
            keyExpiryCategory,
            healthCategory,
            taildropCategory,
            reauthCategory
        ])
    }
    
    // MARK: - Key Expiry Notifications

    /// Reconciles notifications with the latest NetMap and health snapshot.
    /// Stable identifiers plus cancellation of stale requests prevent repeated
    /// Notify events from producing duplicate user notifications.
    func synchronizeState(keyExpiry: Date?, health: HealthState?) async {
        stateSyncGeneration &+= 1
        latestDesiredKeyExpiryIdentifier = nil
        latestDesiredHealthIdentifiers.removeAll()
        let generation = stateSyncGeneration
        let settings = await center.notificationSettings()
        guard isCurrentStateSync(generation) else { return }

        authorizationStatus = settings.authorizationStatus
        isAuthorized = Self.allowsNotificationDelivery(settings.authorizationStatus)

        await synchronizeKeyExpiry(
            expiresAt: keyExpiry,
            daysWarning: 7,
            notificationsAllowed: isAuthorized,
            generation: generation
        )
        guard isCurrentStateSync(generation) else { return }
        await synchronizeHealthWarnings(
            health,
            notificationsAllowed: isAuthorized,
            generation: generation
        )
    }
    
    func scheduleKeyExpiryReminder(expiresAt: Date, daysWarning: Int = 7) async {
        stateSyncGeneration &+= 1
        latestDesiredKeyExpiryIdentifier = nil
        let generation = stateSyncGeneration
        let settings = await center.notificationSettings()
        guard isCurrentStateSync(generation) else { return }
        await synchronizeKeyExpiry(
            expiresAt: expiresAt,
            daysWarning: daysWarning,
            notificationsAllowed: Self.allowsNotificationDelivery(settings.authorizationStatus),
            generation: generation
        )
    }
    
    func scheduleKeyExpiredNotification() async {
        stateSyncGeneration &+= 1
        latestDesiredKeyExpiryIdentifier = nil
        let generation = stateSyncGeneration
        let settings = await center.notificationSettings()
        guard isCurrentStateSync(generation) else { return }
        await synchronizeKeyExpiry(
            expiresAt: .distantPast,
            daysWarning: 7,
            notificationsAllowed: Self.allowsNotificationDelivery(settings.authorizationStatus),
            generation: generation
        )
    }
    
    // MARK: - Health Notifications
    
    func notifyHealthWarning(title: String, message: String, severity: String) async {
        guard isAuthorized else { return }
        
        // Only notify for high severity
        guard severity.lowercased() == "high" else { return }
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default
        content.categoryIdentifier = Self.healthWarningCategory
        
        let identifier = healthNotificationIdentifier(
            for: "manual",
            title: title,
            message: message
        )
        let existing = await managedNotificationIdentifiers()
        guard !existing.contains(identifier),
              !submittedNotificationIdentifiers.contains(identifier) else {
            return
        }
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        
        do {
            try await center.add(request)
            submittedNotificationIdentifiers.insert(identifier)
        } catch {
            // Authorization and delivery errors are reflected by system settings.
        }
    }
    
    // MARK: - Taildrop Notifications
    
    func notifyFileReceived(fileName: String, sender: String) async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized ||
              settings.authorizationStatus == .provisional ||
              settings.authorizationStatus == .ephemeral else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "Taildrop File Received"
        content.body = "\(sender) sent you \(fileName)"
        content.sound = .default
        content.categoryIdentifier = Self.taildropCategory
        
        let request = UNNotificationRequest(
            identifier: "taildrop-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        
        try? await center.add(request)
    }
    
    // MARK: - Clear Notifications
    
    func clearAllNotifications() {
        stateSyncGeneration &+= 1
        latestDesiredKeyExpiryIdentifier = nil
        latestDesiredHealthIdentifiers.removeAll()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
        submittedNotificationIdentifiers.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.keyExpiryFingerprintDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.submittedIdentifiersDefaultsKey)
    }
    
    func clearNotifications(withIdentifiers ids: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
        submittedNotificationIdentifiers.subtract(ids)
    }

    // MARK: - State Reconciliation

    private static func allowsNotificationDelivery(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }

    private func isCurrentStateSync(_ generation: UInt64) -> Bool {
        !Task.isCancelled && generation == stateSyncGeneration
    }

    private func synchronizeKeyExpiry(
        expiresAt: Date?,
        daysWarning: Int,
        notificationsAllowed: Bool,
        generation: UInt64
    ) async {
        guard isCurrentStateSync(generation) else { return }

        let defaults = UserDefaults.standard
        let normalizedDaysWarning = max(daysWarning, 0)
        let fingerprint = expiresAt.map {
            "\(String(format: "%.3f", $0.timeIntervalSince1970))|\(normalizedDaysWarning)"
        }
        let previousFingerprint = defaults.string(forKey: Self.keyExpiryFingerprintDefaultsKey)
        if let fingerprint {
            defaults.set(fingerprint, forKey: Self.keyExpiryFingerprintDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.keyExpiryFingerprintDefaultsKey)
        }

        let now = Date()
        let desiredIdentifier: String?
        if let expiresAt, let fingerprint {
            let prefix = expiresAt <= now
                ? Self.keyExpiredIdentifierPrefix
                : Self.keyExpiryWarningIdentifierPrefix
            desiredIdentifier = prefix + stableNotificationIdentifierComponent(fingerprint)
        } else {
            desiredIdentifier = nil
        }

        let existingIdentifiers = await managedNotificationIdentifiers()
        guard isCurrentStateSync(generation) else { return }

        let managedKeyIdentifiers = existingIdentifiers
            .union(submittedNotificationIdentifiers)
            .filter(Self.isManagedKeyExpiryIdentifier)
        let identifiersToKeep: Set<String> = notificationsAllowed
            ? Set(desiredIdentifier.map { [$0] } ?? [])
            : []
        let staleIdentifiers = Set(managedKeyIdentifiers).subtracting(identifiersToKeep)
        if fingerprint != previousFingerprint || !staleIdentifiers.isEmpty {
            let stale = Array(staleIdentifiers)
            center.removePendingNotificationRequests(withIdentifiers: stale)
            center.removeDeliveredNotifications(withIdentifiers: stale)
            submittedNotificationIdentifiers.subtract(staleIdentifiers)
        }

        latestDesiredKeyExpiryIdentifier =
            notificationsAllowed ? desiredIdentifier : nil
        guard let expiresAt, let desiredIdentifier else { return }

        let content = UNMutableNotificationContent()
        let trigger: UNNotificationTrigger?

        if expiresAt <= now {
            content.title = "Key Expired"
            content.body = "Your device key has expired. Please re-authenticate to restore access."
            content.categoryIdentifier = Self.reauthCategory
            trigger = nil
        } else {
            content.title = "Key Expiring Soon"
            content.body = "Your device key expires soon. Renew to maintain access."
            content.categoryIdentifier = Self.keyExpiryCategory

            let warningDate = Calendar.current.date(
                byAdding: .day,
                value: -normalizedDaysWarning,
                to: expiresAt
            ) ?? expiresAt
            if warningDate > now {
                trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: max(1, warningDate.timeIntervalSince(now)),
                    repeats: false
                )
            } else {
                trigger = nil
            }
        }
        content.sound = .default

        guard notificationsAllowed else {
            center.removePendingNotificationRequests(withIdentifiers: [desiredIdentifier])
            submittedNotificationIdentifiers.remove(desiredIdentifier)
            return
        }

        guard isCurrentStateSync(generation),
              !existingIdentifiers.contains(desiredIdentifier),
              !submittedNotificationIdentifiers.contains(desiredIdentifier) else {
            return
        }

        let request = UNNotificationRequest(
            identifier: desiredIdentifier,
            content: content,
            trigger: trigger
        )
        do {
            try await center.add(request)
            if isCurrentStateSync(generation) ||
                latestDesiredKeyExpiryIdentifier == desiredIdentifier {
                submittedNotificationIdentifiers.insert(desiredIdentifier)
            } else {
                center.removePendingNotificationRequests(withIdentifiers: [desiredIdentifier])
                center.removeDeliveredNotifications(withIdentifiers: [desiredIdentifier])
                submittedNotificationIdentifiers.remove(desiredIdentifier)
            }
        } catch {
            // A later authoritative state update will retry if delivery is allowed.
        }
    }

    private static func isManagedKeyExpiryIdentifier(_ identifier: String) -> Bool {
        identifier == legacyKeyExpiryWarningIdentifier ||
            identifier == legacyKeyExpiredIdentifier ||
            identifier.hasPrefix(keyExpiryWarningIdentifierPrefix) ||
            identifier.hasPrefix(keyExpiredIdentifierPrefix)
    }

    private func synchronizeHealthWarnings(
        _ health: HealthState?,
        notificationsAllowed: Bool,
        generation: UInt64
    ) async {
        let descriptors = highSeverityHealthNotifications(from: health)
        let desiredIdentifiers = Set(descriptors.map(\.identifier))
        guard isCurrentStateSync(generation) else { return }
        latestDesiredHealthIdentifiers =
            notificationsAllowed ? desiredIdentifiers : []
        let existingIdentifiers = await managedNotificationIdentifiers()
        guard isCurrentStateSync(generation) else { return }

        let managedHealthIdentifiers = existingIdentifiers.filter {
            $0.hasPrefix(Self.healthIdentifierPrefix)
        }.union(submittedNotificationIdentifiers.filter {
            $0.hasPrefix(Self.healthIdentifierPrefix)
        })
        let staleIdentifiers = managedHealthIdentifiers.subtracting(desiredIdentifiers)
        if !staleIdentifiers.isEmpty {
            let stale = Array(staleIdentifiers)
            center.removePendingNotificationRequests(withIdentifiers: stale)
            center.removeDeliveredNotifications(withIdentifiers: stale)
            submittedNotificationIdentifiers.subtract(staleIdentifiers)
        }

        guard notificationsAllowed else {
            let pendingDesired = Array(desiredIdentifiers)
            center.removePendingNotificationRequests(withIdentifiers: pendingDesired)
            submittedNotificationIdentifiers.subtract(desiredIdentifiers)
            return
        }

        for descriptor in descriptors {
            guard isCurrentStateSync(generation) else { return }
            guard !existingIdentifiers.contains(descriptor.identifier),
                  !submittedNotificationIdentifiers.contains(descriptor.identifier) else {
                continue
            }

            let content = UNMutableNotificationContent()
            content.title = descriptor.title
            content.body = descriptor.message
            content.sound = .default
            content.categoryIdentifier = Self.healthWarningCategory
            let request = UNNotificationRequest(
                identifier: descriptor.identifier,
                content: content,
                trigger: nil
            )
            do {
                try await center.add(request)
                if isCurrentStateSync(generation) ||
                    latestDesiredHealthIdentifiers.contains(descriptor.identifier) {
                    submittedNotificationIdentifiers.insert(descriptor.identifier)
                } else {
                    center.removePendingNotificationRequests(
                        withIdentifiers: [descriptor.identifier]
                    )
                    center.removeDeliveredNotifications(
                        withIdentifiers: [descriptor.identifier]
                    )
                    submittedNotificationIdentifiers.remove(descriptor.identifier)
                }
            } catch {
                // A later authoritative state update will retry if delivery is allowed.
            }
        }
    }

    private func managedNotificationIdentifiers() async -> Set<String> {
        async let pending = pendingNotificationIdentifiers()
        async let delivered = deliveredNotificationIdentifiers()
        return await pending.union(delivered)
    }

    private func pendingNotificationIdentifiers() async -> Set<String> {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: Set(requests.map(\.identifier)))
            }
        }
    }

    private func deliveredNotificationIdentifiers() async -> Set<String> {
        await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notifications in
                continuation.resume(
                    returning: Set(notifications.map { $0.request.identifier })
                )
            }
        }
    }
}
