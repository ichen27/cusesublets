import Security
import SwiftUI

struct DeletionReceipt: Codable {
  let receipt: String
  let ownerId: String
}
struct DeletionReceiptStore {
  let account: String
  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.ichen27.cusesublets.deletion",
      kSecAttrAccount as String: account,
    ]
  }
  func receipts() throws -> [DeletionReceipt] {
    var q = query
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let result = SecItemCopyMatching(q as CFDictionary, &item)
    if result == errSecItemNotFound { return [] }
    guard result == errSecSuccess, let data = item as? Data else {
      throw APIError(
        message: "Could not read saved deletion receipts. Unlock your iPhone and try again.")
    }
    if let records = try? JSONDecoder().decode([DeletionReceipt].self, from: data) {
      return records
    }
    // Preserve the single receipt saved by earlier app versions when adding another owner.
    return [try JSONDecoder().decode(DeletionReceipt.self, from: data)]
  }
  func read() -> DeletionReceipt? { try? receipts().last }
  func read(ownerId: String) throws -> DeletionReceipt? {
    try receipts().first { $0.ownerId == ownerId }
  }
  func save(_ value: DeletionReceipt) throws {
    var records = try receipts()
    records.removeAll { $0.ownerId == value.ownerId }
    records.append(value)
    let attributes: [String: Any] = [
      kSecValueData as String: try JSONEncoder().encode(records),
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if result == errSecSuccess { return }
    if result == errSecItemNotFound {
      let item = query.merging(attributes) { _, new in new }
      if SecItemAdd(item as CFDictionary, nil) == errSecSuccess { return }
    }
    throw APIError(message: "Could not save the deletion receipt securely. Try again.")
  }

}
struct DeletionStatus: Decodable {
  let status: String
  let requestedAt: Double
  let completedAt: Double?
}
struct AccountDeletionView: View {
  @EnvironmentObject var state: AppState
  @State private var confirmation = ""
  @State private var busy = false
  @State private var error = ""
  var body: some View {
    Form {
      Section("Permanently delete your account") {
        Text(
          "This removes your profile, account credentials, listings, searches, reviews, comments, uploaded files and room captures. You will be signed out everywhere."
        )
        Text(
          "Other participants keep their own messages and a minimal booking history labelled Deleted member. Deleting an account does not cancel a lease or settle a payment or dispute."
        )
        Text(
          "Public content and access are removed immediately. File cleanup and Apple authorization revocation normally finish within 30 minutes for small accounts; larger accounts and queued requests take longer. If a service is unavailable, cleanup retries automatically; you can check its status here without signing in."
        )
        Text(
          "Your saved captures for this account on this iPhone will also be removed. Copies already exported or saved by other people cannot be recalled."
        )
      }
      Section("Confirm deletion") {
        TextField("Type DELETE", text: $confirmation).textInputAutocapitalization(.characters)
          .autocorrectionDisabled().accessibilityIdentifier("deletion-confirmation")
        Button("Delete my account", role: .destructive) { Task { await remove() } }
          .disabled(busy || confirmation != "DELETE")
        if busy { ProgressView("Requesting deletion…") }
        if !error.isEmpty { Text(error).foregroundStyle(.red) }
      }
    }.navigationTitle("Delete account").navigationBarBackButtonHidden(busy)
  }
  private func remove() async {
    guard let user = state.user else { return }
    busy = true
    defer { busy = false }
    do {
      let store = DeletionReceiptStore(account: state.api.baseURL.absoluteString)
      let receipt =
        try store.read(ownerId: user.id)
        ?? DeletionReceipt(
          receipt: (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: ""),
          ownerId: user.id)
      try store.save(receipt)
      state.deletionReceipt = receipt
      // Check the durable receipt first: a prior request may have committed before its response was lost.
      let accepted: DeletionStatus? = try? await state.api.post(
        "/api/account/deletion/status", ["receipt": receipt.receipt])
      if accepted == nil {
        try await state.api.act(
          "/api/account/delete", ["confirmation": "DELETE", "receipt": receipt.receipt])
      }
      try state.finishAccountDeletion(receipt)
    } catch { self.error = error.localizedDescription }
  }
}
struct DeletionStatusView: View {
  @EnvironmentObject var state: AppState
  @State private var status: DeletionStatus?
  @State private var receipts: [DeletionReceipt] = []
  @State private var selectedOwner = ""
  @State private var error = ""
  @State private var busy = false
  var body: some View {
    Form {
      if receipts.count > 1 {
        Picker("Account receipt", selection: $selectedOwner) {
          ForEach(receipts, id: \.ownerId) { receipt in
            Text("Account \(receipt.ownerId)").tag(receipt.ownerId)
          }
        }.disabled(busy).onChange(of: selectedOwner) { _, _ in
          status = nil
          error = ""
          Task { await load() }
        }
      }
      if status == nil {
        Text(
          "A saved receipt means deletion was requested on this iPhone. Check the server status to confirm whether the request was accepted."
        )
      }
      if let status {
        Label(
          status.status == "complete"
            ? "Account deletion completed" : "Account deletion in progress",
          systemImage: status.status == "complete" ? "checkmark.circle" : "clock")
        Text(
          status.status == "complete"
            ? "Account data and server uploads have been removed. Minimal shared transaction references remain under Deleted member."
            : "Your account is closed and public content is removed. File cleanup and Apple revocation are being retried automatically. Small accounts normally finish within 30 minutes; larger accounts, queued requests and service outages can take longer."
        )
        if let completed = status.completedAt {
          Text(Date(timeIntervalSince1970: completed / 1000), style: .date)
        }
      }
      if !error.isEmpty { Text(error).foregroundStyle(.red) }
      Button("Check deletion status") { Task { await load() } }.disabled(busy)
      if busy { ProgressView() }
    }.navigationTitle("Deletion status").task {
      do {
        receipts = try DeletionReceiptStore(account: state.api.baseURL.absoluteString).receipts()
        selectedOwner = receipts.last?.ownerId ?? ""
        if receipts.count <= 1 { await load() }
      } catch { self.error = error.localizedDescription }
    }
  }
  func load() async {
    guard let receipt = receipts.first(where: { $0.ownerId == selectedOwner }), !busy else {
      return
    }
    busy = true
    defer { busy = false }
    do {
      status = try await state.api.post(
        "/api/account/deletion/status", ["receipt": receipt.receipt])
      try state.finishAccountDeletion(receipt)
      error = ""
    } catch { self.error = error.localizedDescription }
  }
}

extension AppState {
  func finishAccountDeletion(_ receipt: DeletionReceipt) throws {
    let clearsCurrentAccount = user == nil || user?.id == receipt.ownerId
    defer {
      if clearsCurrentAccount {
        try? api.clearSession()
        clearDeletedAccount()
      }
    }
    // Read only owner identifiers, so partially written capture manifests do not prevent cleanup.
    let fm = FileManager.default
    let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    for directory in ["room-drafts", "photo-captures"] {
      let folder = base.appendingPathComponent(directory, isDirectory: true)
      for entry in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
      {
        let metadata =
          directory == "photo-captures" ? entry.appendingPathComponent("draft.json") : entry
        if let data = try? Data(contentsOf: metadata),
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          value["ownerId"] as? String == receipt.ownerId
        {
          try fm.removeItem(at: entry)
        }
      }
    }
    if clearsCurrentAccount { try api.clearSession() }
  }
}
