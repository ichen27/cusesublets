import Combine
import Foundation
import Security

struct SessionCredential: Codable {
  let cookie: String
  let expires: Date
  var appleUserID: String? = nil
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
  private var sessionRevision = 0
  private let currentTime: () -> Date
  var onSessionEnded: (() -> Void)?
  var hasStoredSession: Bool { credential != nil }
  var appleUserID: String? { credential?.appleUserID }
  init(
    baseURL: URL? = nil, configuration: URLSessionConfiguration = .ephemeral,
    now: @escaping () -> Date = Date.init
  ) {
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
    self.currentTime = now
    self.baseURL = baseURL ?? configured
    vault = KeychainSession(account: self.baseURL.absoluteString)
    credential = vault.read()
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 30
    session = URLSession(
      configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    if credential == nil { try? clearSession() }
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
    let revision = sessionRevision
    let (data, response) = try await send(path)
    guard revision == sessionRevision else {
      throw APIError(message: "Your session changed. Reopen this screen.")
    }
    try checkAuthenticated(data, response, path: path)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cuse-downloads", isDirectory: true
    ).appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let target = folder.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
    try data.write(to: target, options: .completeFileProtection)
    return target
  }
  private func request<T: Decodable>(
    _ path: String, method: String = "GET", data: Data? = nil, contentType: String? = nil
  ) async throws -> T {
    let revision = sessionRevision
    let (bytes, response) = try await send(
      path, method: method, data: data, contentType: contentType)
    guard revision == sessionRevision else {
      throw APIError(message: "Your session changed. Reopen this screen.")
    }
    try checkAuthenticated(bytes, response, path: path)
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
            expires: cookie.expiresDate ?? currentTime().addingTimeInterval(28800),
            appleUserID: (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any])?[
              "appleUserID"] as? String)
        try vault.save(value)
        credential = value
        sessionRevision += 1
      }
    }
    return try JSONDecoder().decode(T.self, from: bytes)
  }
  func validateSession() throws {
    if let credential, credential.expires <= currentTime() {
      defer { onSessionEnded?() }
      try clearSession()
      throw APIError(message: "Your session expired. Please sign in again.", status: 401)
    }
  }
  private func send(
    _ path: String, method: String = "GET", data: Data? = nil, contentType: String? = nil
  ) async throws -> (Data, HTTPURLResponse) {
    try validateSession()
    guard path.hasPrefix("/api/"), let target = URL(string: path, relativeTo: baseURL),
      target.host == baseURL.host, target.scheme == baseURL.scheme, target.port == baseURL.port
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
    if let credential, credential.expires > currentTime() {
      request.setValue(credential.cookie, forHTTPHeaderField: "Cookie")
    }
    let (bytes, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, http.url?.host == baseURL.host else {
      throw APIError(message: "Unexpected server response")
    }
    return (bytes, http)
  }
  private func checkAuthenticated(_ data: Data, _ response: HTTPURLResponse, path: String) throws {
    if response.statusCode == 401, credential != nil, !path.hasPrefix("/api/auth/") {
      defer { onSessionEnded?() }
      try clearSession()
    }
    try check(data, response)
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
  func webSessionCookie() -> HTTPCookie? {
    guard let credential, credential.expires > currentTime(), let host = baseURL.host,
      let separator = credential.cookie.firstIndex(of: "=")
    else { return nil }
    return HTTPCookie(properties: [
      .domain: host, .path: "/",
      .name: String(credential.cookie[..<separator]),
      .value: String(credential.cookie[credential.cookie.index(after: separator)...]),
      .expires: credential.expires, .secure: baseURL.scheme == "https" ? "TRUE" : "FALSE",
    ])
  }
  func uploadCapture(_ path: String, file: URL) async throws {
    guard path.hasPrefix("/api/listings/"), let target = URL(string: path, relativeTo: baseURL),
      target.host == baseURL.host, target.scheme == baseURL.scheme, target.port == baseURL.port,
      let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0,
      size <= 64 * 1024 * 1024
    else { throw APIError(message: "Capture is missing or larger than 64 MB.") }
    var request = URLRequest(url: target)
    request.httpMethod = "POST"
    request.timeoutInterval = 180
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.setValue(String(size), forHTTPHeaderField: "Content-Length")
    request.setValue(
      baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
      forHTTPHeaderField: "Origin")
    if let credential, credential.expires > currentTime() {
      request.setValue(credential.cookie, forHTTPHeaderField: "Cookie")
    }
    let revision = sessionRevision
    let (data, response) = try await session.upload(for: request, fromFile: file)
    guard revision == sessionRevision else {
      throw APIError(message: "Your session changed. Reopen this screen.")
    }
    guard let http = response as? HTTPURLResponse else {
      throw APIError(message: "Unexpected upload response")
    }
    try checkAuthenticated(data, http, path: path)
  }
  func clearSession() throws {
    credential = nil
    sessionRevision += 1
    try vault.save(nil)
    let downloads = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cuse-downloads", isDirectory: true)
    if FileManager.default.fileExists(atPath: downloads.path) {
      try FileManager.default.removeItem(at: downloads)
    }
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
