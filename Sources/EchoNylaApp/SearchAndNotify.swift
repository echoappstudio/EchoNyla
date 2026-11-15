import AppKit
import Foundation
import EchoNylaCore
import UserNotifications

struct SearchResult: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let name: String
    let modified: Date?
    /// Why it came up, like “Name has “dentist” · Text inside has “invoice””.
    var reason = ""
}

/// Runs a Spotlight query in your home folder (the index Finder search uses), or in one folder and
/// the folders inside it, and returns up to `limit` files, newest first. Starting a new search ends
/// the one before it with no results, so a search typed over another never waits forever.
@MainActor
final class FileSearcher {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    /// The search still waiting for Spotlight, answered by `finish` exactly once.
    private var waiting: CheckedContinuation<[SearchResult], Never>?

    func run(_ queryString: String, in scope: URL? = nil, limit: Int = 60) async -> [SearchResult] {
        stop()
        guard let predicate = NSPredicate(fromMetadataQueryString: queryString) else { return [] }
        return await withCheckedContinuation { continuation in
            waiting = continuation
            let query = NSMetadataQuery()
            query.predicate = predicate
            query.searchScopes = scope.map { [$0] } ?? [NSMetadataQueryUserHomeScope]
            query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
            let thisQuery = ObjectIdentifier(query)
            observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Only the search still running answers (an older one was stopped).
                    guard let self, let query = self.query, ObjectIdentifier(query) == thisQuery else { return }
                    query.disableUpdates()
                    var results: [SearchResult] = []
                    for index in 0..<min(query.resultCount, limit) {
                        guard let item = query.result(at: index) as? NSMetadataItem,
                              let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                        let url = URL(fileURLWithPath: path)
                        let name = item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String ?? url.lastPathComponent
                        let date = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
                        results.append(SearchResult(url: url, name: name, modified: date))
                    }
                    self.stop(answering: results)
                }
            }
            self.query = query
            if !query.start() { stop() }
        }
    }

    /// Ends the current search; whoever is still waiting for it gets `results` (none when it was replaced).
    private func stop(answering results: [SearchResult] = []) {
        query?.stop()
        query = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        let continuation = waiting
        waiting = nil
        continuation?.resume(returning: results)
    }
}

/// Notifications for files EchoNyla moved or has a suggestion for, with Undo / Move buttons.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private let movedCategory = "EchoNyla.moved"
    private let suggestedCategory = "EchoNyla.suggested"
    private var configured = false

    func requestPermissionIfNeeded(enabled: Bool) {
        guard enabled else { return }
        let center = UNUserNotificationCenter.current()
        if !configured {
            configured = true
            center.delegate = self
            let undo = UNNotificationAction(identifier: "undo", title: "Undo")
            let move = UNNotificationAction(identifier: "move", title: "Move")
            center.setNotificationCategories([
                UNNotificationCategory(identifier: movedCategory, actions: [undo], intentIdentifiers: []),
                UNNotificationCategory(identifier: suggestedCategory, actions: [move], intentIdentifiers: [])
            ])
        }
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ entry: ActivityEntry, enabled: Bool) {
        guard enabled else { return }
        requestPermissionIfNeeded(enabled: true)
        let content = UNMutableNotificationContent()
        switch entry.kind {
        case .suggested:
            content.title = entry.destinationName.map { "Move to \($0)?" } ?? "A new file has a suggestion"
            content.categoryIdentifier = suggestedCategory
        default:
            content.title = "Moved to \(entry.destinationName ?? "a folder")"
            content.categoryIdentifier = movedCategory
        }
        content.body = "\(entry.fileName) — \(entry.detail)"
        content.userInfo = ["entry": entry.id.uuidString]
        let request = UNNotificationRequest(identifier: entry.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let idText = response.notification.request.content.userInfo["entry"] as? String
        Task { @MainActor in
            if let idText, let id = UUID(uuidString: idText) {
                switch action {
                case "undo": AppModel.shared.undo(id)
                case "move": AppModel.shared.acceptSuggestion(id)
                default: StatusItemController.shared.showPanel()
                }
            }
        }
        // The click is handled on the main thread above; macOS only needs to hear it arrived.
        completionHandler()
    }
}
