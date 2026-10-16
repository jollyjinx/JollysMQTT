import SwiftUI
import UniformTypeIdentifiers

struct SupportLogsView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var store: SupportLogsStore
  @State private var preparation = 0
  @State private var exporting = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Share Log Files", bundle: #bundle).font(.title2)
      Text(
        "Share application and connection diagnostics to help investigate a problem.",
        bundle: #bundle)
      Text(
        "Broker addresses, usernames, topics, payloads, and credentials are excluded. Logs use anonymous connection identifiers.",
        bundle: #bundle
      )
      .foregroundStyle(.secondary)
      if store.failed {
        Text(
          "The log files could not be prepared or saved. Check available disk space and try again.",
          bundle: #bundle
        )
        .foregroundStyle(.red)
        Button {
          preparation += 1
        } label: {
          Text("Try Again", bundle: #bundle)
        }
      } else if let archive = store.archive {
        HStack {
          ShareLink(item: archive) {
            Label {
              Text("Share Log Files…", bundle: #bundle)
            } icon: {
              Image(systemName: "square.and.arrow.up")
            }
          }
          #if os(macOS)
            Button {
              exporting = true
            } label: {
              Text("Save ZIP…", bundle: #bundle)
            }
          #endif
        }
      } else {
        ProgressView {
          Text("Preparing log files…", bundle: #bundle)
        }
      }
      Text(
        "JollysMQTT keeps up to 20 MB of logs in total and removes logs last written more than 10 days ago.",
        bundle: #bundle
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button {
          dismiss()
        } label: {
          Text("Done", bundle: #bundle)
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(idealWidth: 460)
    .task(id: preparation) { await store.prepare() }
    .fileExporter(
      isPresented: $exporting,
      document: store.archive.map { DiagnosticArchiveDocument(url: $0) },
      contentType: .zip,
      defaultFilename: "JollysMQTT-Logs.zip",
      onCompletion: store.exportFinished
    )
  }
}

private struct DiagnosticArchiveDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.zip]
  let url: URL

  init(url: URL) { self.url = url }

  init(configuration: ReadConfiguration) throws {
    throw CocoaError(.fileReadUnsupportedScheme)
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    try FileWrapper(url: url, options: .immediate)
  }
}
