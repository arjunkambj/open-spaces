import Foundation

/// A JSON value. Objects remember the order their keys were added in, so what
/// the tool prints is stable and reads the way it was written.
enum JSONValue: Sendable, Equatable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object(JSONObject)

  static func strings(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }

  var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  var objectValue: JSONObject? {
    if case .object(let value) = self { return value }
    return nil
  }

  var arrayValue: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  var intValue: Int? {
    if case .int(let value) = self { return value }
    return nil
  }

  subscript(key: String) -> JSONValue? { objectValue?[key] }

  subscript(index: Int) -> JSONValue? {
    guard let items = arrayValue, items.indices.contains(index) else { return nil }
    return items[index]
  }
}

/// A JSON object that keeps its keys in insertion order. Setting a key to `nil` removes it.
struct JSONObject: Sendable, Equatable, ExpressibleByDictionaryLiteral {
  private(set) var keys: [String] = []
  private var storage: [String: JSONValue] = [:]

  init() {}

  /// A `nil` value leaves the key out, which keeps optional fields short to write.
  init(dictionaryLiteral elements: (String, JSONValue?)...) {
    for (key, value) in elements { self[key] = value }
  }

  subscript(key: String) -> JSONValue? {
    get { storage[key] }
    set {
      if let newValue {
        if storage[key] == nil { keys.append(key) }
        storage[key] = newValue
      } else if storage.removeValue(forKey: key) != nil {
        keys.removeAll { $0 == key }
      }
    }
  }

  var pairs: [(key: String, value: JSONValue)] { keys.map { ($0, storage[$0] ?? .null) } }

  static func == (lhs: JSONObject, rhs: JSONObject) -> Bool { lhs.storage == rhs.storage }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringInterpolation {
  init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
  init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
  init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
  init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
  init(dictionaryLiteral elements: (String, JSONValue?)...) {
    var object = JSONObject()
    for (key, value) in elements { object[key] = value }
    self = .object(object)
  }
}

// MARK: - Reading

extension JSONValue {
  /// Thrown for JSON that is valid but shaped to cost a lot: nested very deep, or holding
  /// a very large number of values.
  struct TooComplex: Error {}

  /// Reads one JSON document. Throws `TooComplex` when it is nested deeper than
  /// `Limits.depth` or holds more than `Limits.values` values, and another error when
  /// `text` is not valid JSON. Object keys come out in alphabetical order.
  ///
  /// The shape is checked in one pass over the bytes before anything is built, so input
  /// made to be expensive is turned away for the price of reading it once.
  static func parse(_ text: String) throws -> JSONValue {
    let data = Data(text.utf8)
    var depth = 0
    var commas = 0
    var inText = false
    var escaped = false
    for byte in data {
      if inText {
        if escaped {
          escaped = false
        } else if byte == 0x5C {
          escaped = true
        } else if byte == 0x22 {
          inText = false
        }
        continue
      }
      switch byte {
      case 0x22: inText = true
      case 0x5B, 0x7B:
        depth += 1
        guard depth <= Limits.depth else { throw TooComplex() }
      case 0x5D, 0x7D: depth -= 1
      case 0x2C:
        commas += 1
        guard commas <= Limits.values else { throw TooComplex() }
      default: break
      }
    }
    return JSONValue(foundation: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
  }

  /// A value as `JSONSerialization` hands it over.
  private init(foundation value: Any) {
    switch value {
    case let text as String:
      self = .string(text)
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        self = .bool(number.boolValue)
      } else if let whole = Int(exactly: number) {
        // Also a whole number written with a fraction or an exponent, such as 5.0 or 1e2.
        self = .int(whole)
      } else {
        self = .double(number.doubleValue)
      }
    case let items as [Any]:
      self = .array(items.map(JSONValue.init(foundation:)))
    case let fields as [String: Any]:
      var object = JSONObject()
      for key in fields.keys.sorted() { object[key] = fields[key].map(JSONValue.init(foundation:)) }
      self = .object(object)
    default:
      self = .null
    }
  }
}

// MARK: - Writing

extension JSONValue {
  /// The value as JSON text. Compact output is always a single line, which is
  /// what the MCP stdio transport needs. `pretty` indents by two spaces.
  func serialized(pretty: Bool = false) -> String {
    var out = ""
    write(to: &out, pretty: pretty, depth: 0)
    return out
  }

  private func write(to out: inout String, pretty: Bool, depth: Int) {
    switch self {
    case .null: out += "null"
    case .bool(let value): out += value ? "true" : "false"
    case .int(let value): out += String(value)
    case .double(let value): out += value.isFinite ? String(value) : "null"
    case .string(let value): JSONValue.write(string: value, to: &out)
    case .array(let items):
      guard !items.isEmpty else {
        out += "[]"
        return
      }
      out += "["
      for (index, item) in items.enumerated() {
        if index > 0 { out += "," }
        JSONValue.newline(&out, pretty: pretty, depth: depth + 1)
        item.write(to: &out, pretty: pretty, depth: depth + 1)
      }
      JSONValue.newline(&out, pretty: pretty, depth: depth)
      out += "]"
    case .object(let object):
      guard !object.keys.isEmpty else {
        out += "{}"
        return
      }
      out += "{"
      for (index, pair) in object.pairs.enumerated() {
        if index > 0 { out += "," }
        JSONValue.newline(&out, pretty: pretty, depth: depth + 1)
        JSONValue.write(string: pair.key, to: &out)
        out += pretty ? ": " : ":"
        pair.value.write(to: &out, pretty: pretty, depth: depth + 1)
      }
      JSONValue.newline(&out, pretty: pretty, depth: depth)
      out += "}"
    }
  }

  private static func newline(_ out: inout String, pretty: Bool, depth: Int) {
    guard pretty else { return }
    out += "\n" + String(repeating: "  ", count: depth)
  }

  private static func write(string: String, to out: inout String) {
    out += "\""
    for scalar in string.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        // Control characters, the Unicode line separators some readers split lines on, and
        // the characters that turn the reading direction around: all written as escapes, so
        // JSON printed on a terminal shows what is really there.
        if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) || scalar.value == 0x2028
          || scalar.value == 0x2029 || scalar.reordersText
        {
          let hex = String(scalar.value, radix: 16, uppercase: false)
          out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    out += "\""
  }
}
