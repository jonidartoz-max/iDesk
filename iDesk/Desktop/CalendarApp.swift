import Foundation
import EventKit
import UIKit

/// The Calendar app's data: the months and days the calendar page shows, from the iPhone's calendars
/// (the same access the widgets use), and adding and deleting its events.
enum CalendarApp {
    private static let store = EKEventStore()
    /// The month the page shows and the day selected in it (page state, kept here so every calendar window agrees).
    private(set) static var cursor = Date()
    private(set) static var selected = Date()

    /// A message for the page when calendars cannot be read; empty when all is well.
    static var note: String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: return ""
        case .notDetermined: return String(localized: "iDesk needs access to the calendars.")
        default: return String(localized: "Allow Calendars for iDesk in the iPhone's Settings.")
        }
    }

    static func requestAccess(_ done: @escaping () -> Void) {
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { done(); return }
        store.requestFullAccessToEvents { _, _ in DispatchQueue.main.async { done() } }
    }

    static func show(month delta: Int) {
        cursor = Calendar.current.date(byAdding: .month, value: delta, to: cursor) ?? cursor
        selected = cursor
    }

    static func showToday() {
        cursor = Date()
        selected = Date()
    }

    static func select(day: Date) { selected = day }

    struct Item {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var allDay: Bool
        var color: String        // "rgb(r,g,b)" of the source calendar
        var day: Int             // day-of-month in the shown month (cells use it)
    }

    /// The events of the month the cursor is in, for the page's grid.
    static func month() -> (year: Int, month: Int, items: [Item]) {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: cursor)
        guard let first = cal.date(from: comps),
              cal.range(of: .day, in: .month, for: first) != nil,
              let next = cal.date(byAdding: .month, value: 1, to: first) else { return (0, 0, []) }
        var items: [Item] = []
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess || EKEventStore.authorizationStatus(for: .event) == .authorized {
            let found = store.events(matching: store.predicateForEvents(withStart: first, end: next, calendars: nil))
            items = found.map { e in
                Item(id: e.eventIdentifier ?? "", title: e.title ?? "", start: e.startDate,
                     end: e.endDate, allDay: e.isAllDay, color: rgb(e.calendar.cgColor),
                     day: cal.component(.day, from: e.startDate))
            }
        }
        return (comps.year ?? 0, comps.month ?? 0, items)
    }

    /// The selected day's events, soonest first.
    static func day() -> [Item] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: selected)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess || EKEventStore.authorizationStatus(for: .event) == .authorized else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
            .map { e in Item(id: e.eventIdentifier ?? "", title: e.title ?? "", start: e.startDate,
                             end: e.endDate, allDay: e.isAllDay, color: rgb(e.calendar.cgColor),
                             day: cal.component(.day, from: e.startDate)) }
    }

    /// Adds an event to the default calendar. `day` is "yyyy-MM-dd", `start`/`end` "HH:mm" ("" = all day).
    static func add(title: String, day: String, start: String, end: String) -> String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return String(localized: "Give the event a name.") }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess || EKEventStore.authorizationStatus(for: .event) == .authorized
        else { return String(localized: "Allow Calendars for iDesk in the iPhone's Settings.") }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.timeZone = .current
        guard let dayDate = df.date(from: day + " 00:00") else { return String(localized: "That date did not work.") }
        let e = EKEvent(eventStore: store)
        e.title = title
        e.calendar = store.defaultCalendarForNewEvents
        if start.isEmpty {
            e.isAllDay = true
            e.startDate = dayDate
            e.endDate = dayDate
        } else {
            guard let s = df.date(from: day + " " + start) else { return String(localized: "That start time did not work.") }
            let en = df.date(from: day + " " + end) ?? s.addingTimeInterval(3600)
            e.startDate = s
            e.endDate = en > s ? en : s.addingTimeInterval(3600)
        }
        do {
            try store.save(e, span: .thisEvent)
            return nil
        } catch {
            return String(localized: "Could not save the event.")
        }
    }

    static func delete(id: String) {
        guard let e = store.event(withIdentifier: id) else { return }
        try? store.remove(e, span: .thisEvent)
    }

    private static func rgb(_ color: CGColor?) -> String {
        guard let color, let c = color.components, c.count >= 3 else { return "rgb(120,160,255)" }
        return "rgb(\(Int(c[0] * 255)),\(Int(c[1] * 255)),\(Int(c[2] * 255)))"
    }
}
