import Combine
import Foundation
import Security

struct SessionCredential: Codable {
  let cookie: String
  let expires: Date
}
struct KeychainSession {
  let account: String
  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.ichen27.cusesublets.session",
      kSecAttrAccount as String: account,
    ]
  }
  func read() -> SessionCredential? {
    var q = query
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
      let value = try? JSONDecoder().decode(SessionCredential.self, from: data),
      value.expires > Date()
    else { return nil }
    return value
  }
  func save(_ value: SessionCredential?) throws {
    SecItemDelete(query as CFDictionary)
    guard let value else { return }
    var q = query
    q[kSecValueData as String] = try JSONEncoder().encode(value)
    q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else {
      throw APIError(message: "Could not save your session securely. Please sign in again.")
    }
  }
}
@MainActor final class APIClient: ObservableObject {
  let baseURL: URL
  private let session: URLSession
  private let vault: KeychainSession
  private var credential: SessionCredential?
  init(baseURL: URL? = nil, configuration: URLSessionConfiguration = .ephemeral) {
    var configured = URL(
      string: Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String
        ?? "https://app-cusesublets.chenagent.com")!
    #if DEBUG
      if let value = ProcessInfo.processInfo.environment["CUSE_API_URL"],
        let url = URL(string: value), ["127.0.0.1", "localhost"].contains(url.host ?? "")
      {
        configured = url
      }
    #endif
    self.baseURL = baseURL ?? configured
    vault = KeychainSession(account: self.baseURL.absoluteString)
    credential = vault.read()
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 30
    session = URLSession(
      configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
  }
  func url(_ path: String) -> URL { URL(string: path, relativeTo: baseURL)!.absoluteURL }
  func get<T: Decodable>(_ path: String) async throws -> T { try await request(path) }
  func post<T: Decodable>(_ path: String, _ body: [String: Any] = [:]) async throws -> T {
    try await request(
      path, method: "POST", data: JSONSerialization.data(withJSONObject: body),
      contentType: "application/json")
  }
  func act(_ path: String, _ body: [String: Any] = [:]) async throws {
    let _: EmptyResponse = try await post(path, body)
  }
  func upload(_ path: String, file: URL, fields: [String: String] = [:]) async throws {
    let scoped = file.startAccessingSecurityScopedResource()
    defer { if scoped { file.stopAccessingSecurityScopedResource() } }
    let limit =
      ["mp4", "webm"].contains(file.pathExtension.lowercased()) ? 25 * 1024 * 1024 : 5 * 1024 * 1024
    guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0,
      size <= limit
    else {
      throw APIError(message: "Choose a file under 25 MB. Documents and photos must be under 5 MB.")
    }
    let data = try await Task.detached(priority: .userInitiated) {
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }
      let bytes = try handle.read(upToCount: limit + 1) ?? Data()
      guard !bytes.isEmpty, bytes.count <= limit else {
        throw APIError(message: "File is empty or too large")
      }
      return bytes
    }.value
    let ext = file.pathExtension.lowercased()
    let types = [
      "pdf": "application/pdf", "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
      "webp": "image/webp", "mp4": "video/mp4", "webm": "video/webm",
    ]
    guard let type = types[ext] else {
      throw APIError(message: "Choose a PDF, JPG, PNG, WebP, MP4 or WebM file.")
    }
    let boundary = "cuse-" + UUID().uuidString
    var body = Data()
    func append(_ value: String) { body.append(Data(value.utf8)) }
    for (key, value) in fields {
      append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
    }
    append(
      "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"upload.\(ext)\"\r\nContent-Type: \(type)\r\n\r\n"
    )
    body.append(data)
    append("\r\n--\(boundary)--\r\n")
    let _: EmptyResponse = try await request(
      path, method: "POST", data: body, contentType: "multipart/form-data; boundary=\(boundary)")
  }
  func download(_ path: String, name: String) async throws -> URL {
    let (data, response) = try await send(path)
    try check(data, response)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let target = folder.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
    try data.write(to: target, options: .completeFileProtection)
    return target
  }
  private func request<T: Decodable>(
    _ path: String, method: String = "GET", data: Data? = nil, contentType: String? = nil
  ) async throws -> T {
    let (bytes, response) = try await send(
      path, method: method, data: data, contentType: contentType)
    try check(bytes, response)
    if let header = response.value(forHTTPHeaderField: "Set-Cookie") {
      let cookies = HTTPCookie.cookies(
        withResponseHeaderFields: ["Set-Cookie": header], for: baseURL)
      if let cookie = cookies.first(where: {
        $0.name == "cuse_password_session" || $0.name == "cuse_session"
      }) {
        let value =
          cookie.value.isEmpty
          ? nil
          : SessionCredential(
            cookie: "\(cookie.name)=\(cookie.value)",
            expires: cookie.expiresDate ?? Date().addingTimeInterval(28800))
        try vault.save(value)
        credential = value
      }
    }
    return try JSONDecoder().decode(T.self, from: bytes)
  }
  private func send(
    _ path: String, method: String = "GET", data: Data? = nil, contentType: String? = nil
  ) async throws -> (Data, HTTPURLResponse) {
    guard path.hasPrefix("/api/"), let target = URL(string: path, relativeTo: baseURL),
      target.host == baseURL.host, target.scheme == baseURL.scheme
    else { throw APIError(message: "Invalid API destination") }
    var request = URLRequest(url: target)
    request.httpMethod = method
    request.httpBody = data
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if method != "GET" {
      request.setValue(
        baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
        forHTTPHeaderField: "Origin")
    }
    if let credential, credential.expires > Date() {
      request.setValue(credential.cookie, forHTTPHeaderField: "Cookie")
    }
    let (bytes, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, http.url?.host == baseURL.host else {
      throw APIError(message: "Unexpected server response")
    }
    return (bytes, http)
  }
  private func check(_ data: Data, _ response: HTTPURLResponse) throws {
    guard (200..<300).contains(response.statusCode) else {
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      throw APIError(
        message: json?["error"] as? String
          ?? "The server returned \(response.statusCode). Please try again.",
        status: response.statusCode)
    }
  }
  func clearSession() throws {
    try vault.save(nil)
    credential = nil
  }
}

// An API response must never forward a session cookie to a redirect destination.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
