import AuthenticationServices
import SwiftUI

struct NativeAuthOptions: Decodable {
  let appleEnabled: Bool
  let googleEnabled: Bool
}
struct AppleChallenge: Decodable {
  let id: String
  let nonce: String
}
struct AppleLoginView: View {
  @EnvironmentObject var state: AppState
  @Binding var busy: Bool
  let finished: () -> Void
  @State private var challenge: AppleChallenge?
  @State private var submitted: AppleChallenge?
  @State private var error = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      SignInWithAppleButton(.continue) { request in
        guard let challenge else { return }
        submitted = challenge
        busy = true
        request.requestedScopes = [.fullName, .email]
        request.nonce = challenge.nonce
        request.state = challenge.id
      } onCompletion: { result in
        Task { await complete(result) }
      }
      .signInWithAppleButtonStyle(.black).frame(height: 50).disabled(challenge == nil || busy)
      if busy { ProgressView("Signing in…") }
      if !error.isEmpty {
        Text(error).foregroundStyle(.red).font(.caption)
        Button("Prepare Apple sign-in") { Task { await prepare() } }
      }
    }.task { await prepare() }
  }
  func prepare(clearError: Bool = true) async {
    do {
      challenge = try await state.api.post("/api/auth/apple/challenge")
      if clearError { error = "" }
    } catch { self.error = error.localizedDescription }
  }
  func complete(_ result: Result<ASAuthorization, Error>) async {
    defer {
      busy = false
      submitted = nil
    }
    do {
      let authorization = try result.get()
      guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
        let submitted, credential.state == submitted.id,
        let data = credential.identityToken, let token = String(data: data, encoding: .utf8),
        let codeData = credential.authorizationCode,
        let code = String(data: codeData, encoding: .utf8)
      else { throw APIError(message: "Apple sign-in did not match this request. Try again.") }
      var body: [String: Any] = ["identityToken": token, "code": code, "challengeID": submitted.id]
      if let fullName = credential.fullName {
        let name = PersonNameComponentsFormatter().string(from: fullName)
        if !name.isEmpty { body["name"] = name }
      }
      try await state.api.act("/api/auth/apple", body)
      await state.refreshSession()
      if state.user != nil { finished() }
    } catch {
      if (error as? ASAuthorizationError)?.code != .canceled {
        self.error = error.localizedDescription
      }
    }
    challenge = nil
    await prepare(clearError: false)
  }
}
