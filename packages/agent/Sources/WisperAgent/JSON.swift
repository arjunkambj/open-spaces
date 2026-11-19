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

extension JSONValue: Decodable {
  private struct Field: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  init(from decoder: any Decoder) throws {
    if let keyed = try? decoder.container(keyedBy: Field.self) {
      var object = JSONObject()
      for key in keyed.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
        object[key.stringValue] = try keyed.decode(JSONValue.self, forKey: key)
      }
      self = .object(object)
      return
    }
    if var list = try? decoder.unkeyedContainer() {
      var items: [JSONValue] = []
      while !list.isAtEnd { items.append(try list.decode(JSONValue.self)) }
      self = .array(items)
      return
    }
    let single = try decoder.singleValueContainer()
    if single.decodeNil() {
      self = .null
    } else if let value = try? single.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? single.decode(Int.self) {
      self = .int(value)
    } else if let value = try? single.decode(Double.self) {
      self = .double(value)
    } else {
      self = .string(try single.decode(String.self))
    }
  }

  /// Reads one JSON document. Throws when `text` is not valid JSON.
  static func parse(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
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
        // Control characters, and the Unicode line separators some readers split lines on.
        if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) || scalar.value == 0x2028
          || scalar.value == 0x2029
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
