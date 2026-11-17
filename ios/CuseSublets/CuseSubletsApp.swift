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
  /// Set by the Post button; the You tab opens the matching editor and clears it.
  @Published var postIntent: PostIntent?
  /// How many screens with their own bottom bar are showing; the tab bar hides while any is.
  @Published var screensHidingTabBar = 0
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
        if user != nil {
          // Any refresh may be the one that observes sign-in; signup's own refresh can be
          // superseded by the periodic or foreground refresh, so close the sheet here.
          showLogin = false
          await refreshBlocks()
        }
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
  private func requireLogin() -> Bool {
    if user == nil {
      showLogin = true
      return false
    }
    return true
  }
  /// The app has just opened with a saved session and the server has not yet said whose it is.
  /// Until it does, nobody is known to be signed in, and nobody is known to be a guest.
  var checkingSavedSession: Bool { user == nil && loading && api.hasStoredSession }
  /// Whether someone is signed in; a guest is shown the login sheet. Just after the app opens
  /// a saved session is still being checked, and this waits for that answer: asking at once
  /// would show a signed-in person the login sheet and then drop what they tapped.
  func signedInOrAsk() async -> Bool {
    if checkingSavedSession {
      for await checking in $loading.values where !checking { break }
    }
    return requireLogin()
  }
  func contact(listingID: String, searchID: String? = nil) async {
    guard await signedInOrAsk() else { return }
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
  #if !PERSONAL_DEVICE
    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase
  #endif
  var body: some Scene {
    WindowGroup {
      #if PERSONAL_DEVICE
        PropertiesView().tint(.cuseOrange)
      #else
        // The redesign is drawn for light appearance only so far.
        RootView().environmentObject(state).environment(\.timeZone, marketplaceTimeZone)
          .tint(.quadOrangeDeep).preferredColorScheme(.light).task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
              await state.refreshSession(reportErrors: false)
              try? await Task.sleep(for: .seconds(60))
            }
          }
      #endif
    }
  }
}
struct RootView: View {
  @EnvironmentObject var state: AppState
  @State private var choosingPost = false
  var body: some View {
    // The system tab bar is hidden; `QuadTabBar` floats over the bottom of every tab instead.
    TabView(selection: $state.tab) {
      tab(.home) { BrowseView() }
      tab(.matches) { MatchesView() }
      tab(.inbox) { InboxView() }
      tab(.you) { AccountView() }
    }
    .overlay(alignment: .bottom) {
      if state.screensHidingTabBar == 0 {
        QuadTabBar(selection: $state.tab) {
          Task { if await state.signedInOrAsk() { choosingPost = true } }
        }
          .ignoresSafeArea(.keyboard, edges: .bottom)
      }
    }
    .confirmationDialog(
      "What would you like to post?", isPresented: $choosingPost, titleVisibility: .visible
    ) {
      Button("Sublease my place") { post(.listing) }
      Button("Say what I'm looking for") { post(.search) }
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
      "Quad",
      isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })
    ) {
      Button("OK") { state.error = nil }
    } message: {
      Text(state.error ?? "")
    }
  }
  /// One tab's screens. The margin keeps the end of every scrolling screen above the floating
  /// bar; a safe-area inset on the tab view or the stack does not reach the screens inside.
  private func tab<Content: View>(_ tab: QuadTab, @ViewBuilder content: () -> Content)
    -> some View
  {
    NavigationStack { content() }
      .contentMargins(.bottom, QuadTabBar.reservedHeight, for: .scrollContent)
      .toolbar(.hidden, for: .tabBar)
      .tag(tab.rawValue)
  }
  private func post(_ intent: PostIntent) {
    state.postIntent = intent
    state.tab = QuadTab.you.rawValue
  }
}
/// Shown in place of a tab's guest screen while a saved session is still being checked, so a
/// signed-in person opening the app is not first told to log in.
struct CheckingSessionView: View {
  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Checking your account").font(.subheadline.weight(.semibold))
        .foregroundStyle(Color.quadMuted)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("checking-session")
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
  static let cuseOrange = Color(
    UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.98, green: 0.52, blue: 0.30, alpha: 1)
        : UIColor(red: 0.78, green: 0.24, blue: 0.07, alpha: 1)
    })
  static let cuseCream = Color(
    UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.12, green: 0.11, blue: 0.10, alpha: 1)
        : UIColor(red: 0.98, green: 0.96, blue: 0.92, alpha: 1)
    })
  // Filled buttons retain sufficient contrast with their white labels in either appearance.
  static let cuseButtonFill = Color(red: 0.78, green: 0.24, blue: 0.07)
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
      Color.quadPhoto.overlay(
        Image(systemName: "photo").font(.title).foregroundStyle(Color.quadMuted))
    }.clipped()
  }
}
