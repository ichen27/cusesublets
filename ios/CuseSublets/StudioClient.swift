import Foundation
import Security

/// A property as Tour Studio reports it.
struct StudioProperty: Decodable, Equatable {
  let id: String
  let name: String
  /// `processing`, `ready` or `failed`.
  let status: String
  let error: String?
  let spots: Int
  let seconds: Double?
}

enum StudioFailure: LocalizedError, Equatable {
  case notConfigured
  case unreachable
  case refused(String)

  var errorDescription: String? {
    switch self {
    case .notConfigured: return "Set the Tour Studio address in Settings first."
    case .unreachable:
      return "Tour Studio could not be reached. Check the address and your connection."
    case .refused(let code): return StudioClient.explain(code)
    }
  }
}

/// The Tour Studio access token, kept in the Keychain on this device only.
enum StudioToken {
  static let minimumLength = 32
  private static let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "com.ichen27.cusesublets.tour-studio",
    kSecAttrAccount as String: "token",
  ]

  /// Letters and digits only, long enough to be unguessable.
  static func isValid(_ text: String) -> Bool {
    text.count >= minimumLength && text.unicodeScalars.allSatisfy {
      $0.isASCII && CharacterSet.alphanumerics.contains($0)
    }
  }

  static func read() -> String? {
    var q = query
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// Saves the token, or removes it when given nil. Returns whether the Keychain accepted it.
  @discardableResult
  static func save(_ token: String?) -> Bool {
    SecItemDelete(query as CFDictionary)
    guard let token else { return true }
    var q = query
    q[kSecValueData as String] = Data(token.utf8)
    q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
  }
}

/// Talks to the private Tour Studio service that stitches captures and shows tours. Every
/// request carries the access token; it is sent only to the configured https address.
struct StudioClient {
  static let addressKey = "studioURL"
  static let tokenArgument = "studioToken"
  let base: URL
  var token: String?
  var session = URLSession.shared

  /// The configured service, or nil when no usable https address is set.
  static var configured: StudioClient? {
    guard let text = UserDefaults.standard.string(forKey: addressKey), let url = address(text)
    else { return nil }
    return StudioClient(base: url, token: StudioToken.read())
  }

  /// The token as a cookie for the tour page's web view, which cannot add a header to the
  /// requests the page makes itself.
  var tokenCookie: HTTPCookie? {
    guard let token, let host = base.host else { return nil }
    return HTTPCookie(properties: [
      .name: "studio_token", .value: token, .domain: host, .path: "/", .secure: "TRUE",
    ])
  }

  /// Keeps an address passed as a launch argument (`-studioURL https://…`), so a developer can
  /// set it from the Mac once instead of typing it on the phone.
  static func rememberLaunchAddress(_ defaults: UserDefaults = .standard) {
    let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    if let text = arguments[addressKey] as? String, address(text) != nil {
      defaults.set(text, forKey: addressKey)
    }
    // The token goes to the Keychain, never to the preferences file.
    if let token = arguments[tokenArgument] as? String, StudioToken.isValid(token) {
      StudioToken.save(token)
    }
  }

  /// Accepts only an https origin; a path, query or other scheme is refused.
  static func address(_ text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let parts = URLComponents(string: trimmed), parts.scheme == "https",
      let host = parts.host, !host.isEmpty, parts.path.isEmpty || parts.path == "/",
      parts.query == nil, parts.user == nil
    else { return nil }
    var origin = URLComponents()
    origin.scheme = "https"
    origin.host = host
    origin.port = parts.port
    return origin.url
  }

  static func explain(_ code: String) -> String {
    switch code {
    case "spot_incomplete": return "A spot had gaps. Scan again and hold each dot until it fills."
    case "capture_invalid": return "Tour Studio could not read this scan. Scan again."
    case "capture_too_large": return "This scan is too large. Use fewer spots."
    case "already_processing": return "This property is already being stitched."
    case "unauthorized": return "Tour Studio refused the access token. Check it in Settings."
    case "timeout": return "Stitching took too long. Try again."
    case "interrupted": return "Stitching was interrupted. Try again."
    default: return "Tour Studio could not make the tour (\(code))."
    }
  }

  func tourPage(_ id: String) -> URL { base.appendingPathComponent("tour").appendingPathComponent(id) }

  /// Whether the service answers and accepts the token, as a sentence for the settings screen.
  func check() async -> String {
    guard (try? await send(request("health"))) != nil else {
      return StudioFailure.unreachable.localizedDescription
    }
    do {
      _ = try await send(request("api/properties"))
      return "Connected."
    } catch { return error.localizedDescription }
  }

  /// Nil when Tour Studio has no capture of this property.
  func status(_ id: String) async throws -> StudioProperty? {
    do {
      return try JSONDecoder().decode(
        StudioProperty.self, from: try await send(request("api/properties/\(id)")))
    } catch StudioFailure.refused("not_found") {
      return nil
    }
  }

  func upload(archive: URL, id: String, name: String) async throws -> StudioProperty {
    var upload = request("api/properties/\(id)/capture", method: "POST")
    upload.setValue(
      name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "",
      forHTTPHeaderField: "X-Property-Name")
    upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    upload.timeoutInterval = 300
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.upload(for: upload, fromFile: archive)
    } catch { throw StudioFailure.unreachable }
    return try JSONDecoder().decode(StudioProperty.self, from: try Self.check(data, response))
  }

  func delete(_ id: String) async throws {
    _ = try await send(request("api/properties/\(id)", method: "DELETE"))
  }

  private func request(_ path: String, method: String = "GET") -> URLRequest {
    var request = URLRequest(url: base.appendingPathComponent(path))
    request.httpMethod = method
    request.timeoutInterval = 20
    // The service refuses changes without this header, which a cross-site form cannot send.
    request.setValue("1", forHTTPHeaderField: "X-Cuse-Studio")
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    return request
  }

  private func send(_ request: URLRequest) async throws -> Data {
    let data: Data
    let response: URLResponse
    do { (data, response) = try await session.data(for: request) } catch {
      throw StudioFailure.unreachable
    }
    return try Self.check(data, response)
  }

  private struct Refusal: Decodable { let error: String }

  static func check(_ data: Data, _ response: URLResponse) throws -> Data {
    guard let http = response as? HTTPURLResponse else { throw StudioFailure.unreachable }
    if (200..<300).contains(http.statusCode) { return data }
    if let refusal = try? JSONDecoder().decode(Refusal.self, from: data) {
      throw StudioFailure.refused(refusal.error)
    }
    // Anything else (a sign-in page, a proxy error) means the app is not talking to the service.
    throw StudioFailure.unreachable
  }
}
