import Foundation

/// A place being scanned: its name here, its capture in `SpotTake`'s folder, and its stitched
/// tour on the Tour Studio service under the same id.
struct Property: Codable, Identifiable, Hashable {
  let id: String
  var name: String
  var createdAt: Date
  /// A capture of this property has been sent to Tour Studio.
  var uploaded = false
}

/// The properties on this iPhone. A small JSON file; captures live in their own folders.
final class PropertyStore: ObservableObject {
  static let owner = "tour-studio"
  @Published private(set) var properties: [Property] = []
  private let file: URL

  init(
    file: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("properties.json")
  ) {
    self.file = file
    if let data = try? Data(contentsOf: file),
      let saved = try? Self.decoder.decode([Property].self, from: data)
    {
      properties = saved
    }
  }

  @discardableResult
  func add(name: String) -> Property {
    let property = Property(
      id: UUID().uuidString.lowercased(), name: Self.clean(name), createdAt: Date())
    properties.insert(property, at: 0)
    save()
    return property
  }

  /// Adds the properties Tour Studio holds that this iPhone does not list yet, and notes which
  /// of its own Tour Studio already has. Nothing is removed and no name here is changed: a scan
  /// that was never uploaded exists only on this iPhone. Returns how many were added.
  @discardableResult
  func merge(_ kept: [StudioProperty]) -> Int {
    var added = 0
    var changed = false
    for remote in kept {
      if let index = properties.firstIndex(where: { $0.id == remote.id }) {
        if !properties[index].uploaded {
          properties[index].uploaded = true
          changed = true
        }
      } else {
        properties.append(
          Property(
            id: remote.id, name: Self.clean(remote.name),
            createdAt: remote.createdAt.flatMap(Self.moment) ?? Date(), uploaded: true))
        added += 1
      }
    }
    guard added > 0 || changed else { return 0 }
    properties.sort { $0.createdAt > $1.createdAt }
    save()
    return added
  }

  private static func moment(_ text: String) -> Date? { ISO8601DateFormatter().date(from: text) }

  func update(_ id: String, _ change: (inout Property) -> Void) {
    guard let index = properties.firstIndex(where: { $0.id == id }) else { return }
    change(&properties[index])
    properties[index].name = Self.clean(properties[index].name)
    save()
  }

  /// Removes the property and its capture from this iPhone.
  func remove(_ id: String) {
    properties.removeAll { $0.id == id }
    try? FileManager.default.removeItem(at: Self.captureFolder(id))
    save()
  }

  static func captureFolder(_ id: String) -> URL { SpotTake.folder(owner: owner, listing: id) }

  static func draft(for property: Property) -> PhotoCaptureDraft {
    PhotoCaptureDraft(id: property.id, ownerId: owner, listingId: property.id, name: property.name)
  }

  static func clean(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Untitled property" : String(trimmed.prefix(80))
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()
  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()

  private func save() {
    do {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Self.encoder.encode(properties).write(
        to: file, options: [.atomic, .completeFileProtection])
    } catch {
      // The list is rebuilt from what is in memory on the next successful save.
    }
  }
}
