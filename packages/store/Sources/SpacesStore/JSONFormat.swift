import Foundation
import SpacesDomain

/// How the data folder writes JSON: pretty-printed, sorted keys, ISO 8601 dates, UTF-8,
/// one trailing newline.
enum LibraryJSON {
  static func encode<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(Timestamp.string(from: date))
    }
    do {
      var data = try encoder.encode(value)
      data.append(0x0A)
      return data
    } catch {
      throw SpacesError.storage("Something in it could not be written as JSON.")
    }
  }

  static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let text = try container.decode(String.self)
      guard let date = Timestamp.date(from: text) else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Not an ISO 8601 date: \(text)"
        )
      }
      return date
    }
    return try decoder.decode(type, from: data)
  }

  /// True when the file holds nothing but white space. Such a file counts as missing.
  static func isBlank(_ data: Data) -> Bool {
    data.allSatisfy { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
  }

  /// The entries of a JSON array that can still be read, leaving out the ones that cannot.
  /// `nil` when the data is not a JSON array at all.
  static func salvageArray<Element: Decodable>(_ type: Element.Type, from data: Data) -> [Element]? {
    (try? decode(Salvaged<Element>.self, from: data))?.elements
  }

  /// A JSON object read without the top-level keys that stop it from loading. A key the
  /// type cannot do without is not recoverable. `nil` when nothing can be saved.
  static func salvageObject<Value: Decodable>(_ type: Value.Type, from data: Data) -> Value? {
    guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    while true {
      guard let cleaned = try? JSONSerialization.data(withJSONObject: object) else { return nil }
      do {
        return try decode(type, from: cleaned)
      } catch let error as DecodingError {
        guard let key = error.topLevelKey, object.removeValue(forKey: key) != nil else { return nil }
      } catch {
        return nil
      }
    }
  }

  /// A task list with only its unreadable tasks left out. Categories that cannot be read are
  /// treated as missing. `nil` when the data is not a JSON object at all.
  static func salvageTaskList(from data: Data) -> TaskList? {
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    var list = TaskList()
    if let names = object["categories"] as? [String], !names.isEmpty { list.categories = names }
    if let tasks = object["tasks"], let raw = try? JSONSerialization.data(withJSONObject: tasks) {
      list.tasks = salvageArray(DailyTask.self, from: raw) ?? []
    }
    return list
  }

  private struct Salvaged<Element: Decodable>: Decodable {
    var elements: [Element] = []

    init(from decoder: any Decoder) throws {
      var container = try decoder.unkeyedContainer()
      while !container.isAtEnd {
        if let element = try? container.decode(Element.self) {
          elements.append(element)
        } else {
          // A failed decode does not move on, so step over the bad entry.
          _ = try container.decode(Skipped.self)
        }
      }
    }
  }

  private struct Skipped: Decodable {
    init(from decoder: any Decoder) throws {}
  }
}

/// ISO 8601 dates in UTC, such as `2026-11-17T09:30:00Z`.
///
/// Writing adds a fraction of a second (3, 6 or 9 digits) only when the date needs it, and
/// always enough to read back as exactly the same `Date`. Reading accepts any fraction, a
/// time zone offset, and a date with no time.
enum Timestamp {
  /// Seconds from 1970 to 2001, the instant `Date` counts from.
  private static let referenceOffset: Int64 = 978_307_200
  /// 0001-01-01 and 9999-12-31, in seconds from 2001. Dates outside are pinned to the edge.
  private static let range: ClosedRange<Double> = -63_113_904_000...252_423_993_599
  private static let fractions: [(digits: Int, scale: Double)] = [(0, 1), (3, 1e3), (6, 1e6), (9, 1e9)]

  static func string(from date: Date) -> String {
    let raw = date.timeIntervalSinceReferenceDate
    let interval = raw.isNaN ? 0 : min(max(raw, range.lowerBound), range.upperBound)
    let whole = interval.rounded(.down)
    let fraction = interval - whole

    // The shortest fraction that reads back as the same instant.
    var digits = 9
    var units = (fraction * 1e9).rounded()
    for (candidateDigits, scale) in fractions {
      let candidate = (fraction * scale).rounded()
      if candidate < scale, whole + candidate / scale == interval {
        (digits, units) = (candidateDigits, candidate)
        break
      }
    }
    var seconds = Int64(whole) + referenceOffset
    if units >= 1e9 {
      seconds += 1
      (digits, units) = (0, 0)
    }

    let days = seconds.floorDivided(by: 86_400)
    let secondOfDay = Int(seconds - days * 86_400)
    let (year, month, day) = civil(fromDays: days)
    var text = pad(Int(year), 4) + "-" + pad(month, 2) + "-" + pad(day, 2) + "T"
    text += pad(secondOfDay / 3_600, 2) + ":" + pad(secondOfDay / 60 % 60, 2) + ":" + pad(secondOfDay % 60, 2)
    if digits > 0 { text += "." + pad(Int(units), digits) }
    return text + "Z"
  }

  static func date(from text: String) -> Date? {
    var scan = Scan(bytes: Array(text.utf8))
    guard let year = scan.number(4), scan.skip("-"), let month = scan.number(2), scan.skip("-"),
      let day = scan.number(2), (1...12).contains(month), (1...daysIn(month, of: year)).contains(day)
    else { return nil }
    var seconds = daysFromCivil(year: Int64(year), month: month, day: day) * 86_400
    var fraction = 0.0

    if !scan.atEnd {
      guard scan.skip("T") || scan.skip("t") || scan.skip(" "),
        let hour = scan.number(2), scan.skip(":"), let minute = scan.number(2),
        hour <= 23, minute <= 59
      else { return nil }
      seconds += Int64(hour * 3_600 + minute * 60)
      if scan.skip(":") {
        // 60 is a leap second; it lands on the next minute.
        guard let second = scan.number(2), second <= 60 else { return nil }
        seconds += Int64(second)
        if scan.skip(".") || scan.skip(",") {
          guard let (units, scale) = scan.fraction() else { return nil }
          fraction = units / scale
        }
      }
      if scan.skip("Z") || scan.skip("z") {
        // UTC.
      } else if let sign = scan.sign() {
        guard let hours = scan.number(2), hours <= 23 else { return nil }
        _ = scan.skip(":")
        let minutes = scan.atEnd ? 0 : scan.number(2)
        guard let minutes, minutes <= 59 else { return nil }
        seconds -= Int64(sign * (hours * 3_600 + minutes * 60))
      }
      guard scan.atEnd else { return nil }
    }
    return Date(timeIntervalSinceReferenceDate: Double(seconds - referenceOffset) + fraction)
  }

  private static func pad(_ value: Int, _ width: Int) -> String {
    let digits = String(max(value, 0))
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
  }

  private static func daysIn(_ month: Int, of year: Int) -> Int {
    switch month {
    case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
    case 4, 6, 9, 11: 30
    default: 31
    }
  }

  // Calendar arithmetic on the Gregorian calendar, counting days from 1970-01-01. Years
  // are grouped into 400-year eras that start on 1 March, so the leap day falls last.

  private static func daysFromCivil(year: Int64, month: Int, day: Int) -> Int64 {
    let shifted = month <= 2 ? year - 1 : year
    let era = shifted.floorDivided(by: 400)
    let yearOfEra = shifted - era * 400
    let dayOfYear = Int64((153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1)
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }

  private static func civil(fromDays days: Int64) -> (year: Int64, month: Int, day: Int) {
    let shifted = days + 719_468
    let era = shifted.floorDivided(by: 146_097)
    let dayOfEra = shifted - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let marchMonth = (5 * dayOfYear + 2) / 153
    let day = Int(dayOfYear - (153 * marchMonth + 2) / 5 + 1)
    let month = Int(marchMonth < 10 ? marchMonth + 3 : marchMonth - 9)
    return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
  }

  /// Walks over the bytes of a date string.
  private struct Scan {
    let bytes: [UInt8]
    var index = 0

    var atEnd: Bool { index == bytes.count }

    mutating func skip(_ character: Character) -> Bool {
      guard index < bytes.count, bytes[index] == character.asciiValue else { return false }
      index += 1
      return true
    }

    /// Exactly `count` digits.
    mutating func number(_ count: Int) -> Int? {
      guard index + count <= bytes.count else { return nil }
      var value = 0
      for byte in bytes[index..<index + count] {
        guard (0x30...0x39).contains(byte) else { return nil }
        value = value * 10 + Int(byte - 0x30)
      }
      index += count
      return value
    }

    /// One or more digits after the decimal point. Digits past the ninth are dropped.
    mutating func fraction() -> (units: Double, scale: Double)? {
      var units = 0.0
      var scale = 1.0
      var count = 0
      while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
        if count < 9 {
          units = units * 10 + Double(bytes[index] - 0x30)
          scale *= 10
        }
        count += 1
        index += 1
      }
      return count > 0 ? (units, scale) : nil
    }

    mutating func sign() -> Int? {
      if skip("+") { return 1 }
      if skip("-") { return -1 }
      return nil
    }
  }
}

extension DecodingError {
  /// The top-level key of the document that this error is about, when there is one.
  fileprivate var topLevelKey: String? {
    switch self {
    case .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context),
      .dataCorrupted(let context):
      context.codingPath.first?.stringValue
    @unknown default: nil
    }
  }
}

extension Int64 {
  /// Division that rounds toward negative infinity.
  fileprivate func floorDivided(by divisor: Int64) -> Int64 {
    let quotient = self / divisor
    return self % divisor < 0 ? quotient - 1 : quotient
  }
}
