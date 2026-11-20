import EventKit
import Foundation
import SpacesDomain

/// The calls on the calendars of this Mac, read with EventKit. Nothing is sent anywhere:
/// EventKit reads what the Calendar app already has on the device.
///
/// Reads nothing and asks nothing until calendar access is allowed (`MacPermissions`).
public final class MacCalendar: MeetingCalendar, @unchecked Sendable {
  private let lock = NSLock()
  /// Made on the first read after access is allowed: a store made before that sees no events.
  private var store: EKEventStore?

  /// Text in an event's link, place or notes that says it is a video call.
  private static let callLinks = [
    "zoom.us/", "zoom.com/", "meet.google.com/", "teams.microsoft.com/", "teams.live.com/", "webex.com/",
  ]

  public init() {}

  public func calls(at date: Date) async -> [CalendarEvent] {
    guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
    return lock.withLock {
      let store = self.store ?? EKEventStore()
      self.store = store
      // Events that overlap the minute around `date`; the filter below keeps those going on at `date`.
      let range = store.predicateForEvents(
        withStart: date.addingTimeInterval(-60),
        end: date.addingTimeInterval(60),
        calendars: nil
      )
      return store.events(matching: range)
        .filter { event in
          !event.isAllDay && event.status != .canceled && event.startDate <= date && date < event.endDate
            && !MacCalendar.declined(event)
        }
        .compactMap(MacCalendar.call)
        .sorted { $0.start > $1.start }
    }
  }

  /// The event as a call, or `nil` when it does not look like one.
  private static func call(_ event: EKEvent) -> CalendarEvent? {
    let others = attendees(of: event)
    let text = [event.url?.absoluteString, event.location, event.notes]
      .compactMap { $0?.lowercased() }
      .joined(separator: " ")
    guard !others.isEmpty || callLinks.contains(where: text.contains) else { return nil }
    // A repeating event has one identifier for all its meetings: the start tells them apart.
    let series = event.eventIdentifier ?? event.calendarItemIdentifier
    return CalendarEvent(
      id: "\(series)@\(Int(event.startDate.timeIntervalSince1970))",
      title: (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
      start: event.startDate,
      end: event.endDate,
      attendees: others
    )
  }

  /// The people invited, without the person using this Mac and without rooms. By name, or
  /// by email address when the calendar has no name.
  private static func attendees(of event: EKEvent) -> [String] {
    var people = event.attendees ?? []
    // Some calendars leave the organizer out of the list. An event with nobody invited is no call,
    // even when someone else organised it (a shared calendar).
    if !people.isEmpty, let organizer = event.organizer { people.insert(organizer, at: 0) }
    var seen: Set<String> = []
    return people.compactMap { person in
      guard !person.isCurrentUser, person.participantType != .room, person.participantType != .resource
      else { return nil }
      let address = person.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
      let name = (person.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let shown = name.isEmpty ? address : name
      guard !shown.isEmpty, seen.insert(address.lowercased()).inserted else { return nil }
      return shown
    }
  }

  private static func declined(_ event: EKEvent) -> Bool {
    event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
  }
}
