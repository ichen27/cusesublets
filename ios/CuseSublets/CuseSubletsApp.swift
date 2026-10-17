import AuthenticationServices
import CryptoKit
import SwiftUI

@MainActor final class AppState: ObservableObject {
  let api: APIClient
  private var refreshID = UUID()
  private let appleCredentialState:
    (String) async throws -> ASAuthorizationAppleIDProvider.CredentialState
  init(
    api: APIClient? = nil,
    appleCredentialState:
      @escaping (String) async throws -> ASAuthorizationAppleIDProvider.CredentialState = {
        try await ASAuthorizationAppleIDProvider().credentialState(forUserID: $0)
      }
  ) {
    self.appleCredentialState = appleCredentialState
    self.api = api ?? APIClient()
    self.deletionReceipt = DeletionReceiptStore(account: self.api.baseURL.absoluteString).read()
    self.api.onSessionEnded = { [weak self] in
      guard let self else { return }
      self.clearAccount()
      self.error = "Your session ended. Please sign in again."
    }
  }
  private func clearAccount() {
    refreshID = UUID()
    user = nil
    blockedMembers = []
    hiddenMemberIDs = []
    loading = false
    conversationID = nil
    tab = 0
    showLogin = false
  }
  @Published var deletionReceipt: DeletionReceipt?
  func clearDeletedAccount() {
    clearAccount()
    tab = 3
  }
  @Published var blockedMembers: [BlockedMember] = []
  @Published var hiddenMemberIDs: Set<String> = []
  @Published var user: Member?
  @Published var loading = true
  @Published var showLogin = false
  @Published var error: String?
  @Published var tab = 0
  @Published var conversationID: String?
  func refreshSession(reportErrors: Bool = true) async {
    let requestID = UUID()
    refreshID = requestID
    do {
      try api.validateSession()
      if let appleUserID = api.appleUserID {
        let status = try? await appleCredentialState(appleUserID)
        guard refreshID == requestID else { return }
        if status == .revoked || status == .notFound || status == .transferred {
          await logout()
          return
        }
      }
      let r: SessionResponse = try await api.get("/api/session")
      guard refreshID == requestID else { return }
      if r.user == nil && (api.hasStoredSession || user != nil) {
        clearAccount()
        try api.clearSession()
      } else {
        user = r.user
        if user != nil { await refreshBlocks() }
      }
    } catch {
      guard refreshID == requestID else { return }
      if reportErrors { self.error = error.localizedDescription }
    }
    loading = false
  }
  func logout() async {
    var warning: String?
    do { try await api.act("/api/logout") } catch {
      warning =
        "Signed out on this iPhone. The server could not confirm session revocation; it will expire automatically."
    }
    do { try api.clearSession() } catch { warning = error.localizedDescription }
    clearAccount()
    error = warning
  }
  func requireLogin() -> Bool {
    if user == nil {
      showLogin = true
      return false
    }
    return true
  }
  func contact(listingID: String, searchID: String? = nil) async {
    guard requireLogin() else { return }
    do {
      var body: [String: Any] = ["listingId": listingID]
      if let searchID { body["requestId"] = searchID }
      let r: ConversationResponse = try await api.post("/api/conversations", body)
      conversationID = r.conversation.id
      tab = 2
    } catch { self.error = error.localizedDescription }
  }
}
@main struct CuseSubletsApp: App {
  @StateObject private var state = AppState()
  @Environment(\.scenePhase) private var scenePhase
  var body: some Scene {
    WindowGroup {
      RootView().environmentObject(state).environment(\.timeZone, marketplaceTimeZone)
        .tint(.cuseOrange).task(id: scenePhase) {
          guard scenePhase == .active else { return }
          while !Task.isCancelled {
            await state.refreshSession(reportErrors: false)
            try? await Task.sleep(for: .seconds(60))
          }
        }
    }
  }
}
struct RootView: View {
  @EnvironmentObject var state: AppState
  var body: some View {
    TabView(selection: $state.tab) {
      NavigationStack { BrowseView() }.tabItem { Label("Browse", systemImage: "square.grid.2x2") }
        .tag(0)
      NavigationStack { MatchesView() }.tabItem {
        Label("Matches", systemImage: "arrow.left.arrow.right")
      }.tag(1)
      NavigationStack { InboxView() }.tabItem {
        Label("Inbox", systemImage: "bubble.left.and.bubble.right")
      }.tag(2)
      NavigationStack { AccountView() }.tabItem { Label("You", systemImage: "person.crop.circle") }
        .tag(3)
    }
    .id(state.user?.id ?? "guest")
    .onReceive(
      NotificationCenter.default.publisher(
        for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)
    ) { _ in
      if state.api.appleUserID != nil { Task { await state.logout() } }
    }
    .sheet(isPresented: $state.showLogin) { LoginView() }
    .alert(
      "CuseSublets",
      isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })
    ) {
      Button("OK") { state.error = nil }
    } message: {
      Text(state.error ?? "")
    }
  }
}
struct LoginView: View {
  @EnvironmentObject var state: AppState
  @Environment(\.dismiss) var dismiss
  @State private var email = ""
  @State private var password = ""
  @State private var name = ""
  @State private var error = ""
  @State private var signup = false
  @State private var busy = false
  @State private var google = GoogleSignIn()
  @State private var authOptions: NativeAuthOptions?
  private var showGoogle: Bool {
    #if DEBUG
      return true
    #else
      return authOptions?.googleEnabled == true
    #endif
  }
  private var passwordContentType: UITextContentType {
    #if DEBUG
      // Keep synthetic credential entry independent of the system password-generator sheet.
      if ProcessInfo.processInfo.environment["CUSE_UI_MANUAL_PASSWORD"] == "1" {
        return .password
      }
    #endif
    return signup ? .newPassword : .password
  }
  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text("Find a sublet. List your place.").font(.title2.bold())
          Text("Your account works on the website and iPhone.").foregroundStyle(.secondary)
        }
        Section {
          Button(signup ? "Already have an account? Log in" : "Create an account") {
            signup.toggle()
            error = ""
          }.disabled(busy)
          if signup { TextField("Your name", text: $name).textContentType(.name) }
          TextField("Email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(
            .never
          ).autocorrectionDisabled().textContentType(.username)
          SecureField("Password", text: $password).textContentType(passwordContentType)
          if signup {
            Text("Use 15–128 characters. Signing up does not verify your identity.").font(.caption)
          }
          Button(signup ? "Create account" : "Log in") { Task { await login() } }.disabled(
            busy || email.isEmpty || password.isEmpty)
        }
        if authOptions?.appleEnabled == true {
          Section { AppleLoginView(busy: $busy, finished: { dismiss() }) }
        }
        if showGoogle {
          Section {
            Button("Continue with Google") {
              Task {
                busy = true
                defer { busy = false }
                do {
                  try await google.signIn(api: state.api)
                  await state.refreshSession()
                  if state.user != nil { dismiss() }
                } catch { self.error = error.localizedDescription }
              }
            }.disabled(busy)
            Text("Google access currently follows the website’s configured account policy.").font(
              .caption
            ).foregroundStyle(.secondary)
          }
        }
        if busy { ProgressView() }
        if !error.isEmpty { Text(error).foregroundStyle(.red) }
        Text("Password recovery emails are not available yet.").font(.footnote).foregroundStyle(
          .secondary)
      }.task {
        do { authOptions = try await state.api.get("/api/auth/native-options") } catch {
          self.error =
            "Other sign-in methods could not be loaded. You can still use email and password."
        }
      }.scrollDismissesKeyboard(.interactively).navigationTitle("Welcome").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("Done") {
            UIApplication.shared.sendAction(
              #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
          }.accessibilityIdentifier("dismiss-keyboard")
        }
      }
    }
  }
  func login() async {
    busy = true
    error = ""
    defer { busy = false }
    do {
      let _: EmptyResponse = try await state.api.post(
        signup ? "/api/auth/signup" : "/api/auth/login",
        ["email": email, "password": password, "name": name])
      password = ""
      await state.refreshSession()
      if state.user != nil { dismiss() }
    } catch { self.error = error.localizedDescription }
  }
}
@MainActor final class GoogleSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
  private var session: ASWebAuthenticationSession?
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
      ?? UIWindow()
  }
  func signIn(api: APIClient) async throws {
    let verifier = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
    let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    let state = UUID().uuidString
    let callback: URL = try await withCheckedThrowingContinuation { continuation in
      let url = api.url("/api/login?mobile_challenge=\(challenge)&state=\(state)")
      session = ASWebAuthenticationSession(url: url, callbackURLScheme: "cusesublets") {
        url, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let url {
          continuation.resume(returning: url)
        } else {
          continuation.resume(throwing: APIError(message: "Sign-in did not finish"))
        }
      }
      session?.presentationContextProvider = self
      if session?.start() != true {
        continuation.resume(throwing: APIError(message: "Could not open Google sign-in"))
      }
    }
    let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
    guard callback.host == "auth", parts.first(where: { $0.name == "state" })?.value == state,
      let code = parts.first(where: { $0.name == "code" })?.value
    else { throw APIError(message: "Sign-in response did not match this request") }
    try await api.act("/api/auth/mobile", ["code": code, "verifier": verifier])
    session = nil
  }
}
extension Color {
  static let cuseOrange = Color(red: 0.82, green: 0.28, blue: 0.09)
  static let cuseCream = Color(red: 0.98, green: 0.96, blue: 0.92)
}
struct StatusText: View {
  let text: String
  var body: some View {
    Text(text).font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 5)
      .background(Color.cuseCream, in: Capsule())
  }
}
struct EmptyState: View {
  let title: String
  let text: String
  var body: some View {
    ContentUnavailableView(title, systemImage: "house", description: Text(text))
  }
}
struct RemoteImage: View {
  @EnvironmentObject var state: AppState
  let path: String?
  var body: some View {
    AsyncImage(url: path.flatMap { URL(string: $0, relativeTo: state.api.baseURL) }) { image in
      image.resizable().scaledToFill()
    } placeholder: {
      Color.cuseCream.overlay(
        Image(systemName: "house").font(.largeTitle).foregroundStyle(.secondary))
    }.clipped()
  }
}
