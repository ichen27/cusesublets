import Foundation

enum CaptureArchive {
  // Uncompressed USTAR keeps the server's size limits meaningful.
  static func write(entries: [(String, URL)], to target: URL) throws {
    var names = Set<String>()
    var total = 1024
    for (name, file) in entries {
      guard
        name == "manifest.json" || name == "mesh.json"
          || name.range(of: "^images/[0-9]{5}\\.jpg$", options: .regularExpression) != nil,
        names.insert(name).inserted
      else { throw CaptureFailure.message("Invalid capture file name.") }
      let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      total += size + 512 + (512 - size % 512) % 512
    }
    guard total <= 64 * 1024 * 1024 else {
      throw CaptureFailure.message("Capture exceeds 64 MB. Record a smaller room.")
    }
    let temporary = target.appendingPathExtension("partial")
    FileManager.default.createFile(atPath: temporary.path, contents: nil)
    let output = try FileHandle(forWritingTo: temporary)
    do {
      for (name, file) in entries {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        var header = Data(repeating: 0, count: 512)
        func field(_ offset: Int, _ length: Int, _ text: String) {
          let bytes = Data(text.utf8)
          header.replaceSubrange(
            offset..<(offset + min(length, bytes.count)), with: bytes.prefix(length))
        }
        field(0, 100, name)
        field(100, 8, "0000600")
        field(108, 8, "0000000")
        field(116, 8, "0000000")
        field(124, 12, String(format: "%011o", size))
        field(136, 12, "00000000000")
        field(148, 8, "        ")
        field(156, 1, "0")
        field(257, 6, "ustar")
        field(263, 2, "00")
        let sum = header.reduce(0) { $0 + Int($1) }
        field(148, 8, String(format: "%06o", sum) + "\0 ")
        try output.write(contentsOf: header)
        let input = try FileHandle(forReadingFrom: file)
        do {
          while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
            try output.write(contentsOf: data)
          }
          try input.close()
        } catch {
          try? input.close()
          throw error
        }
        try output.write(contentsOf: Data(repeating: 0, count: (512 - size % 512) % 512))
      }
      try output.write(contentsOf: Data(repeating: 0, count: 1024))
      try output.synchronize()
      try output.close()
      if FileManager.default.fileExists(atPath: target.path) {
        try FileManager.default.removeItem(at: target)
      }
      try FileManager.default.moveItem(at: temporary, to: target)
    } catch {
      try? output.close()
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }
}

enum CaptureFailure: LocalizedError {
  case message(String)
  var errorDescription: String? {
    if case .message(let value) = self { return value }
    return nil
  }
}
