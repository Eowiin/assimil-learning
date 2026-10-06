import Foundation
import UIKit

/// Le jour calendaire local, tenu à jour même quand l'app reste ouverte à minuit.
///
/// Le système prévient du changement de jour (`NSCalendarDayChanged`), d'un
/// changement d'heure ou de fuseau, et du retour au premier plan — la notification
/// de minuit peut arriver pendant que l'app est suspendue. L'accueil se recalcule
/// sur `today`, sans minuteur.
@MainActor
final class DayClock: ObservableObject {
    @Published private(set) var today: Date

    private let clock: () -> Date
    private let fixedCalendar: Calendar?
    private var observers: [NSObjectProtocol] = []

    private var calendar: Calendar { fixedCalendar ?? .current }

    init(now: @escaping () -> Date = DayClock.systemNow,
         calendar: Calendar? = nil,
         center: NotificationCenter = .default) {
        self.clock = now
        self.fixedCalendar = calendar
        self.today = (calendar ?? .current).startOfDay(for: now())

        let names: [Notification.Name] = [
            .NSCalendarDayChanged,
            .NSSystemTimeZoneDidChange,
            UIApplication.significantTimeChangeNotification,
            UIApplication.willEnterForegroundNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
    }

    func now() -> Date { clock() }

    func refresh() {
        let day = calendar.startOfDay(for: clock())
        if day != today { today = day }
    }

    nonisolated static func systemNow() -> Date {
        Date.now.addingTimeInterval(Double(AppEnvironment.dayOffset) * 86_400)
    }
}

/// Crochets de vérification, lus **en Debug seulement** : ils permettent de faire
/// tourner l'app dans le simulateur sur des données fictives et à une autre date,
/// sans toucher au contenu Assimil ni au stockage réel. Sans effet en Release.
enum AppEnvironment {
    private static var values: [String: String] {
        #if DEBUG
        ProcessInfo.processInfo.environment
        #else
        [:]
        #endif
    }

    /// Dossier de textes remplaçant `Resources/text`.
    static var textDirectory: URL? {
        values["ASSIMIL_TEXT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Décale « maintenant » de N jours, pour vérifier le lendemain.
    static var dayOffset: Int {
        values["ASSIMIL_DAY_OFFSET"].flatMap(Int.init) ?? 0
    }

    /// Stockage SwiftData isolé, pour ne pas toucher aux données réelles.
    static var storeURL: URL? {
        values["ASSIMIL_STORE"].map { URL(fileURLWithPath: $0) }
    }
}
