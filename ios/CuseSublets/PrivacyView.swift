import SwiftUI

struct PrivacyNotice: Decodable {
  struct Section: Decodable {
    let title: String
    let text: String
  }
  let title: String
  let updated: String
  let status: String
  let sections: [Section]
  let supportURL: String
}
struct PrivacyView: View {
  private var notice: PrivacyNotice? {
    guard let url = Bundle.main.url(forResource: "privacy", withExtension: "json"),
      let data = try? Data(contentsOf: url)
    else { return nil }
    return try? JSONDecoder().decode(PrivacyNotice.self, from: data)
  }
  var body: some View {
    List {
      if let notice {
        Section {
          Text(notice.status)
          Text("Updated \(notice.updated)").font(.caption)
        }
        ForEach(notice.sections, id: \.title) { section in
          Section(section.title) { Text(section.text).textSelection(.enabled) }
        }
        if let url = URL(string: notice.supportURL) { Link("Technical feedback", destination: url) }
      } else {
        Text("Privacy information could not be loaded. Open the website’s privacy page.")
      }
    }.navigationTitle("Data & privacy")
  }
}
