import Foundation
import JollysMQTTStorage
import Observation

@MainActor
@Observable
final class SupportLogsStore {
  var isPresented = false
  private(set) var archive: URL?
  private(set) var failed = false
  private let logs: DiagnosticLogStore

  init(logs: DiagnosticLogStore = .shared) {
    self.logs = logs
  }

  func prepare() async {
    archive = nil
    failed = false
    do {
      let archive = try await logs.createArchive(
        in: FileManager.default.temporaryDirectory.appending(
          path: "JollysMQTT-LogExports", directoryHint: .isDirectory
        )
      )
      try Task.checkCancellation()
      self.archive = archive
    } catch is CancellationError {
      return
    } catch {
      failed = true
    }
  }

  func exportFinished(_ result: Result<URL, any Error>) {
    if case .failure = result { failed = true }
  }
}
