import Foundation

public enum CSVImporter {
  public static func rows(_ text: String) throws -> [[String]] {
    var result: [[String]] = []
    var row: [String] = []
    var field = ""
    var quoted = false
    var input = text.unicodeScalars.makeIterator()
    var current = input.next()
    if current == "\u{FEFF}" { current = input.next() }
    var count = 0
    while let character = current {
      count += 1
      if count % 8192 == 0 { try Task.checkCancellation() }
      if character == "\"" {
        if quoted {
          let next = input.next()
          if next == "\"" {
            field.append("\"")
            current = input.next()
            continue
          }
          quoted = false
          current = next
          continue
        }
        quoted = true
      } else if character == "," && !quoted {
        row.append(field)
        field = ""
      } else if character == "\n" && !quoted {
        row.append(field.hasSuffix("\r") ? String(field.dropLast()) : field)
        if row.contains(where: { !$0.isEmpty }) { result.append(row) }
        row = []
        field = ""
      } else {
        field.unicodeScalars.append(character)
      }
      current = input.next()
    }
    if !field.isEmpty || !row.isEmpty {
      row.append(field.hasSuffix("\r") ? String(field.dropLast()) : field)
      if row.contains(where: { !$0.isEmpty }) { result.append(row) }
    }
    return result
  }
  private static func header(_ text: String) -> String {
    text.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
  }
  public static func band(channel: Int?, radio: Radio) -> String {
    if radio == .ble { return "Bluetooth" }
    guard let channel else { return "Unknown" }
    if (1...14).contains(channel) { return "2.4 GHz" }
    if (32...177).contains(channel) { return "5 GHz" }
    return channel > 177 ? "6 GHz" : "Unknown"
  }
  public static func security(_ auth: String) -> String {
    let mode = auth.uppercased()
    if mode.isEmpty || mode.contains("OPEN") || mode.contains("NONE") { return "Open" }
    return ["WPA3", "WPA2", "WPA", "WEP"].first(where: { mode.contains($0) }) ?? "Other"
  }
  public static func manufacturer(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let hex = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
      of: "^0x", with: "", options: [.regularExpression, .caseInsensitive])
    guard hex.range(of: "^[0-9a-f]{1,4}$", options: [.regularExpression, .caseInsensitive]) != nil
    else { return nil }
    return String(repeating: "0", count: 4 - hex.count) + hex.uppercased()
  }
  public static func parse(_ text: String, session: String, timeZone: TimeZone = .current) throws
    -> [Observation]
  {
    let all = try rows(text)
    let hints: Set<String> = [
      "mac", "bssid", "ssid", "authmode", "firstseen", "currentlatitude", "currentlongitude",
      "type",
    ]
    var best = -1
    var bestScore = 0
    for (index, row) in all.prefix(10).enumerated() {
      let score = row.reduce(0) { $0 + (hints.contains(header($1)) ? 1 : 0) }
      if score > bestScore {
        best = index
        bestScore = score
      }
    }
    guard best >= 0, bestScore >= 2 else {
      throw AtlasError.invalid(
        "No supported CSV header was found. Choose a Biscuit or WiGLE-format export.")
    }
    let headers = all[best].map(header)
    let dates = CaptureDateParser(timeZone: timeZone)
    var output: [Observation] = []
    for (index, row) in all.dropFirst(best + 1).enumerated() {
      if index % 256 == 0 { try Task.checkCancellation() }
      var fields: [String: String] = [:]
      for (column, name) in headers.enumerated() {
        fields[name] =
          column < row.count ? row[column].trimmingCharacters(in: .whitespacesAndNewlines) : ""
      }
      func number(_ text: String?) -> Double? {
        guard let text,
          let range = text.range(
            of: "^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?",
            options: .regularExpression), let result = Double(text[range]), result.isFinite
        else { return nil }
        return result
      }
      func nonempty(_ key: String, _ fallback: String) -> String {
        let v = fields[key] ?? ""
        return v.isEmpty ? fallback : v
      }
      guard let lat = number(fields["currentlatitude"] ?? fields["latitude"]),
        let lon = number(fields["currentlongitude"] ?? fields["longitude"]), abs(lat) <= 90,
        abs(lon) <= 180
      else { continue }
      let accuracy = number(fields["accuracymeters"] ?? fields["accuracy"])
      if let accuracy, accuracy < 0 { continue }
      let typeText = nonempty("type", "WIFI").uppercased()
      let radio: Radio = typeText.contains("BLE") || typeText.contains("BLUETOOTH") ? .ble : .wifi
      let channel = fields["channel"].flatMap { value -> Int? in
        guard let range = value.range(of: "^[+-]?[0-9]+", options: .regularExpression) else {
          return nil
        }
        return Int(value[range])
      }
      let firstSeen = nonempty("firstseen", fields["timestamp"] ?? "")
      output.append(
        Observation(
          session: session, bssid: nonempty("mac", nonempty("bssid", "Unknown device")),
          ssid: nonempty("ssid", "Hidden network"),
          authMode: nonempty("authmode", "Unknown"), security: security(fields["authmode"] ?? ""),
          firstSeen: firstSeen,
          timestamp: dates.parse(firstSeen), channel: channel,
          band: band(channel: channel, radio: radio), rssi: number(fields["rssi"]),
          latitude: lat, longitude: lon,
          altitude: number(fields["altitudemeters"] ?? fields["altitude"]), accuracy: accuracy,
          manufacturerId: manufacturer(fields["mfgrid"]), type: radio))
    }
    guard !output.isEmpty else {
      throw AtlasError.invalid(
        "The file has a header, but no rows with valid latitude and longitude values.")
    }
    return output
  }
  public static func uniqueSession(_ name: String, existing: Set<String>) -> String {
    var result = name
    var suffix = 2
    while existing.contains(result) {
      result = "\(name) (\(suffix))"
      suffix += 1
    }
    return result
  }
}

/// Formatters are owned by one import operation, never shared between tasks.
private final class CaptureDateParser {
  private let iso = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
  private let local: [DateFormatter]
  private var cached: [String: Double] = [:]
  init(timeZone: TimeZone) {
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    local = [
      "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS",
      "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd",
    ].map { format in
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = timeZone
      formatter.calendar = Calendar(identifier: .gregorian)
      formatter.dateFormat = format
      formatter.isLenient = false
      return formatter
    }
  }
  func parse(_ text: String) -> Double? {
    guard !text.isEmpty else { return nil }
    if let value = cached[text] { return value }
    let date =
      fractional.date(from: text) ?? iso.date(from: text)
      ?? local.lazy.compactMap { $0.date(from: text) }.first
    guard let date else { return nil }
    let value = date.timeIntervalSince1970 * 1000
    if cached.count < 100_000 { cached[text] = value }
    return value
  }
}
