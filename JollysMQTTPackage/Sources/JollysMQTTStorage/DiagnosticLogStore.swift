import Foundation

/// Serial, bounded diagnostics with no per-message tasks or retained handles.
/// Each pooled connection owns an opaque ID; reconnect attempts keep its file.
public actor DiagnosticLogStore {
  public static let maximumRetainedBytes = 20_000_000
  public static let maximumRetainedAge: TimeInterval = 10 * 86_400
  public static let shared = DiagnosticLogStore(
    directory: (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first
      ?? FileManager.default.temporaryDirectory).appending(
        path: "JollysMQTT/diagnostic-logs", directoryHint: .isDirectory)
  )

  private struct FileRecord {
    var bytes: Int
    var modified: Date
  }

  public nonisolated let directory: URL
  private let maximumBytes: Int
  private let segmentBytes: Int
  private let now: @Sendable () -> Date
  private let runID = UUID().uuidString.lowercased()
  private var files: [URL: FileRecord] = [:]
  private var currentFiles: [String: URL] = [:]
  private var totalBytes = 0
  private var segment = 0
  private var initialized = false
  private var writeFailed = false

  public init(
    directory: URL,
    maximumBytes: Int = maximumRetainedBytes,
    segmentBytes: Int = 1_000_000,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.directory = directory
    self.maximumBytes = max(2, maximumBytes)
    self.segmentBytes = max(1, min(segmentBytes, maximumBytes / 2))
    self.now = now
  }

  @discardableResult
  public func record(_ event: DiagnosticLogEvent, connectionID: UUID? = nil) -> Bool {
    do {
      try initialize()
      try prune()
      let stream = connectionID.map { "connection-\($0.uuidString.lowercased())" } ?? "application"
      try append(event.message, stream: stream)
      writeFailed = false
      return true
    } catch {
      writeFailed = true
      // A failed write may have changed file lengths. Reconcile from disk
      // before attempting another write or claiming a bounded export.
      initialized = false
      currentFiles.removeAll()
      return false
    }
  }

  public func retainedFiles() throws -> [URL] {
    try initialize()
    try prune()
    return files.keys.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  /// Copy under actor isolation so pruning/writes cannot race the snapshot.
  /// Compression then runs away from this actor and the UI executor.
  public func createArchive(in exportDirectory: URL) async throws -> URL {
    try Task.checkCancellation()
    let retained = try retainedFiles()
    guard !writeFailed else { throw CocoaError(.fileWriteUnknown) }
    let fm = FileManager.default
    try fm.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
    try protect(exportDirectory)
    try removeOldExports(in: exportDirectory)
    let workspace = exportDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let snapshot = workspace.appending(path: "JollysMQTT Logs", directoryHint: .isDirectory)
    let archive = workspace.appending(path: "JollysMQTT-Logs.zip")
    do {
      try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
      try protect(workspace)
      try protect(snapshot)
      for url in retained {
        let copy = snapshot.appending(path: url.lastPathComponent)
        try fm.copyItem(at: url, to: copy)
        try protect(copy)
      }
      let information = snapshot.appending(path: "Support Information.txt")
      try Data(Self.supportInformation.utf8).write(to: information, options: .atomic)
      try protect(information)
      try await Self.compress(snapshot: snapshot, archive: archive)
      try fm.removeItem(at: snapshot)
      try protect(archive)
      return archive
    } catch {
      try? fm.removeItem(at: workspace)
      throw error
    }
  }

  private func initialize() throws {
    guard !initialized else { return }
    let fm = FileManager.default
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    try protect(directory)
    files.removeAll()
    totalBytes = 0
    for url in try fm.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
      ]
    )
    where url.pathExtension == "log"
      && (url.lastPathComponent.hasPrefix("application-")
        || url.lastPathComponent.hasPrefix("connection-"))
    {
      let values = try url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
      let bytes = values.fileSize ?? 0
      files[url] = FileRecord(
        bytes: bytes, modified: values.contentModificationDate ?? .distantPast)
      totalBytes += bytes
      try protect(url)
    }
    try prune()
    try append(DiagnosticLogEvent.applicationStarted.message, stream: "application")
    initialized = true
    writeFailed = false
  }

  private func append(_ message: String, stream: String) throws {
    let timestamp = now().ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true))
    var data = Data("\(timestamp) \(message)".utf8.prefix(max(0, min(4096, segmentBytes) - 1)))
    while !data.isEmpty && String(data: data, encoding: .utf8) == nil { data.removeLast() }
    data.append(0x0a)
    try prune(incomingBytes: data.count)
    let url: URL
    if let current = currentFiles[stream],
      let record = files[current], record.bytes + data.count <= segmentBytes
    {
      url = current
    } else {
      segment += 1
      url = directory.appending(path: "\(stream)-\(runID)-\(segment).log")
      currentFiles[stream] = url
    }
    if files[url] == nil {
      try data.write(to: url, options: .atomic)
      try protect(url)
    } else {
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
    }
    totalBytes += data.count
    files[url] = FileRecord(bytes: (files[url]?.bytes ?? 0) + data.count, modified: now())
  }

  private func prune(incomingBytes: Int = 0) throws {
    let cutoff = now().addingTimeInterval(-Self.maximumRetainedAge)
    for (url, record) in files.sorted(by: {
      if $0.value.modified == $1.value.modified { return $0.key.path < $1.key.path }
      return $0.value.modified < $1.value.modified
    }) {
      guard record.modified < cutoff || totalBytes + incomingBytes > maximumBytes else { continue }
      try FileManager.default.removeItem(at: url)
      files.removeValue(forKey: url)
      currentFiles = currentFiles.filter { $0.value != url }
      totalBytes -= record.bytes
    }
  }

  private func protect(_ url: URL) throws {
    var url = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
    let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    var attributes: [FileAttributeKey: Any] = [.posixPermissions: isDirectory ? 0o700 : 0o600]
    #if os(iOS)
      attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
    #endif
    try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
  }

  private func removeOldExports(in directory: URL) throws {
    let fm = FileManager.default
    let candidates = try fm.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.creationDateKey, .isSymbolicLinkKey]
    ).filter { UUID(uuidString: $0.lastPathComponent) != nil }.sorted { $0.path < $1.path }
    for url in candidates {
      let values = try url.resourceValues(forKeys: [.creationDateKey, .isSymbolicLinkKey])
      guard values.isSymbolicLink != true,
        (values.creationDate ?? .distantPast) < now().addingTimeInterval(-86_400)
      else { continue }
      try fm.removeItem(at: url)
    }
  }

  @concurrent private static func compress(snapshot: URL, archive: URL) async throws {
    try Task.checkCancellation()
    var coordinationError: NSError?
    var copyError: (any Error)?
    NSFileCoordinator().coordinate(
      readingItemAt: snapshot, options: .forUploading, error: &coordinationError
    ) { zip in
      do { try FileManager.default.copyItem(at: zip, to: archive) } catch { copyError = error }
    }
    if let coordinationError { throw coordinationError }
    if let copyError { throw copyError }
    try Task.checkCancellation()
    guard FileManager.default.fileExists(atPath: archive.path) else {
      throw CocoaError(.fileReadUnknown)
    }
  }

  private static var supportInformation: String {
    let bundle = Bundle.main
    let version =
      bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    return """
      JollysMQTT \(version) (\(build))
      \(ProcessInfo.processInfo.operatingSystemVersionString)
      Logs contain typed diagnostic events and anonymous connection IDs.
      No broker addresses, usernames, topics, payloads, or credentials are included.
      Retention: 20 MB total, 10 days, rotating 1 MB segments per connection.
      """
  }
}
