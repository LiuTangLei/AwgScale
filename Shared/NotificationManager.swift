import Foundation
import UserNotifications

/// Notification manager for Tailscale iOS app.
/// Handles key expiration reminders, health warnings, and file transfer notifications.
@MainActor
class NotificationManager: ObservableObject {
    
    static let shared = NotificationManager()
    
    @Published var isAuthorized: Bool = false
    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined
    
    private let center = UNUserNotificationCenter.current()
    
    // MARK: - Notification Categories
    
    static let keyExpiryCategory = "KEY_EXPIRY"
    static let healthWarningCategory = "HEALTH_WARNING"
    static let taildropCategory = "TAILDROP"
    static let reauthCategory = "REAUTH"
    
    // MARK: - Initialization
    
    init() {
        Task {
            await checkAuthorizationStatus()
            setupCategories()
        }
    }
    
    // MARK: - Authorization
    
    func checkAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        await MainActor.run {
            authorizationStatus = settings.authorizationStatus
            isAuthorized = settings.authorizationStatus == .authorized
        }
    }
    
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            await MainActor.run {
                isAuthorized = granted
                authorizationStatus = granted ? .authorized : .denied
            }
            return granted
        } catch {
            return false
        }
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
    
    func scheduleKeyExpiryReminder(expiresAt: Date, daysWarning: Int = 7) async {
        guard isAuthorized else { return }
        
        // Remove existing key expiry notifications
        center.removePendingNotificationRequests(withIdentifiers: ["key-expiry-warning"])
        
        let warningDate = Calendar.current.date(byAdding: .day, value: -daysWarning, to: expiresAt)!
        
        // Only schedule if warning date is in the future
        guard warningDate > Date() else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "Key Expiring Soon"
        content.body = "Your Tailscale key expires in \(daysWarning) days. Renew to maintain access."
        content.sound = .default
        content.categoryIdentifier = Self.keyExpiryCategory
        
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour], from: warningDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        
        let request = UNNotificationRequest(
            identifier: "key-expiry-warning",
            content: content,
            trigger: trigger
        )
        
        try? await center.add(request)
    }
    
    func scheduleKeyExpiredNotification() async {
        guard isAuthorized else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "Key Expired"
        content.body = "Your Tailscale key has expired. Please re-authenticate to restore access."
        content.sound = .default
        content.categoryIdentifier = Self.reauthCategory
        
        let request = UNNotificationRequest(
            identifier: "key-expired",
            content: content,
            trigger: nil // Immediate
        )
        
        try? await center.add(request)
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
        
        let request = UNNotificationRequest(
            identifier: "health-warning-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        
        try? await center.add(request)
    }
    
    // MARK: - Taildrop Notifications
    
    func notifyFileReceived(fileName: String, sender: String) async {
        guard isAuthorized else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "File Received"
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
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }
    
    func clearNotifications(withIdentifiers ids: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}
