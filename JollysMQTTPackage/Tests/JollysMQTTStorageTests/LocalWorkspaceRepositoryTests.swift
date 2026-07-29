import Foundation
import JollysMQTTCore
import JollysMQTTStorage
import Testing

@Suite("Local workspace repository")
struct LocalWorkspaceRepositoryTests {
  @Test("A missing workspace opens at the server list")
  func missingWorkspaceUsesDefaultRecord() async throws {
    let fixture = try WorkspaceFixture()
    defer { fixture.remove() }
    let id = WorkspaceID()
    let repository = LocalWorkspaceRepository(directoryURL: fixture.directory)

    let record = try await repository.load(id: id)

    #expect(record == WorkspaceRecord(id: id))
    #expect(record.route == .serverList)
  }

  @Test("A workspace round-trips through a versioned atomic document")
  func workspaceRoundTripIsVersioned() async throws {
    let fixture = try WorkspaceFixture()
    defer { fixture.remove() }
    let id = WorkspaceID()
    let profileID = UUID()
    let expected = WorkspaceRecord(
      id: id,
      route: .connected(profileID: profileID),
      selectedProfileID: profileID,
      selectedTopic: "factory/line/status",
      expandedTopics: ["factory", "factory/line"],
      topicSearchText: "status",
      topicSortMode: .recentActivity,
      destination: .charts
    )
    let repository = LocalWorkspaceRepository(directoryURL: fixture.directory)

    try await repository.save(expected)

    let data = try Data(contentsOf: fixture.fileURL(for: id))
    let json = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(json["version"] as? Int == 1)
    let relaunched = LocalWorkspaceRepository(directoryURL: fixture.directory)
    #expect(try await relaunched.load(id: id) == expected)
  }

  @Test("One complete numeric chart configuration round-trips in a version-one workspace")
  func numericChartRoundTrip() async throws {
    let fixture = try WorkspaceFixture()
    defer { fixture.remove() }
    let id = WorkspaceID()
    let brokerID = UUID()
    let chart = NumericChartConfiguration(
      series: NumericChartSeries(
        id: NumericChartSeriesID(
          brokerID: brokerID,
          topic: "factory/line/metrics",
          jsonPointer: PayloadJSONPointer(rawValue: "/temperature")
        ),
        conversion: NumericChartValueConversion(
          kind: .number,
          multiplier: 0.1
        )
      ),
      isPaused: true,
      autoScroll: false,
      visibleRange: try NumericChartVisibleRange.fixed(
        lowerBoundMicroseconds: 1_000_000,
        upperBoundMicroseconds: 61_000_000
      ),
      yAxis: try NumericChartYAxis.fixed(
        lowerBound: -20,
        upperBound: 80
      )
    )
    let expected = WorkspaceRecord(id: id, numericChart: chart)
    let repository = LocalWorkspaceRepository(directoryURL: fixture.directory)

    try await repository.save(expected)

    let encoded = try Data(contentsOf: fixture.fileURL(for: id))
    let document = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    #expect(document["version"] as? Int == 1)
    #expect(try await repository.load(id: id) == expected)
  }

  @Test("A ticket-18 numericChart record migrates to one deterministically identified card")
  func legacyNumericChartMigratesToDashboard() async throws {
    let fixture = try WorkspaceFixture()
    defer { fixture.remove() }
    let id = WorkspaceID()
    let brokerID = UUID()
    let chart = NumericChartConfiguration(
      series: NumericChartSeries(
        id: NumericChartSeriesID(
          brokerID: brokerID,
          topic: "factory/legacy"
        ),
        conversion: NumericChartValueConversion(kind: .number)
      )
    )
    let chartObject = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(chart)
    )
    let legacyDocument: [String: Any] = [
      "version": 1,
      "record": [
        "id": ["rawValue": id.rawValue.uuidString],
        "route": ["serverList": [:]],
        "numericChart": chartObject,
      ],
    ]
    try JSONSerialization.data(withJSONObject: legacyDocument)
      .write(to: fixture.fileURL(for: id), options: [.atomic])
    let repository = LocalWorkspaceRepository(
      directoryURL: fixture.directory
    )

    let first = try await repository.load(id: id)
    let second = try await repository.load(id: id)

    #expect(first.numericChartDashboard.cards.count == 1)
    #expect(first.numericChartDashboard.cards.first?.chart == chart)
    #expect(
      first.numericChartDashboard.cards.first?.id
        == NumericChartCardID(rawValue: id.rawValue)
    )
    #expect(first.numericChartDashboard == second.numericChartDashboard)
  }

  @Test("A multi-card dashboard round-trips distinct duplicate-series cards in order")
  func dashboardRoundTripPreservesCards() async throws {
    let fixture = try WorkspaceFixture()
    defer { fixture.remove() }
    let id = WorkspaceID()
    let brokerID = UUID()
    let series = NumericChartSeries(
      id: NumericChartSeriesID(
        brokerID: brokerID,
        topic: "factory/value"
      ),
      conversion: NumericChartValueConversion(kind: .number)
    )
    let cards = [
      NumericChartCardConfiguration(
        id: NumericChartCardID(rawValue: UUID()),
        chart: NumericChartConfiguration(series: series),
        presentationStyle: .points,
        color: .teal,
        gridSpan: .third
      ),
      NumericChartCardConfiguration(
        id: NumericChartCardID(rawValue: UUID()),
        chart: NumericChartConfiguration(series: series, isPaused: true),
        presentationStyle: .step,
        color: .orange,
        gridSpan: .full
      ),
    ]
    let expected = WorkspaceRecord(
      id: id,
      numericChartDashboard:
        NumericChartDashboardConfiguration(cards: cards)
    )
    let repository = LocalWorkspaceRepository(
      directoryURL: fixture.directory
    )

    try await repository.save(expected)
    let restored = try await repository.load(id: id)

    #expect(restored == expected)
    #expect(restored.numericChartDashboard.cards.map(\.id) == cards.map(\.id))
  }

  @Test("Version-one workspaces without outline fields receive safe defaults")
  func legacyWorkspaceDefaultsOutlinePresentation() async throws {
    let fixture = try WorkspaceFixture()
    defer { fixture.remove() }
    let id = WorkspaceID()
    let data = Data(
      """
      {
        "version": 1,
        "record": {
          "id": {"rawValue": "\(id.rawValue.uuidString)"},
          "route": {"serverList": {}}
        }
      }
      """.utf8
    )
    try data.write(to: fixture.fileURL(for: id), options: [.atomic])
    let repository = LocalWorkspaceRepository(directoryURL: fixture.directory)

    let record = try await repository.load(id: id)

    #expect(record.expandedTopics.isEmpty)
    #expect(record.topicSearchText.isEmpty)
    #expect(record.topicSortMode == .name)
    #expect(record.destination == .topics)
    #expect(record.numericChart == nil)
  }

  @Test("An undecodable current workspace recovers to the server list")
  func corruptWorkspaceRecoversSafely() async throws {
    let fixture = try WorkspaceFixture()
    defer { fixture.remove() }
    let id = WorkspaceID()
    try Data(#"{"version":1,"record":{"broken":true}}"#.utf8)
      .write(to: fixture.fileURL(for: id), options: [.atomic])
    let repository = LocalWorkspaceRepository(directoryURL: fixture.directory)

    let recovered = try await repository.load(id: id)

    #expect(recovered == WorkspaceRecord(id: id))
    #expect(
      try Data(contentsOf: fixture.fileURL(for: id))
        == Data(#"{"version":1,"record":{"broken":true}}"#.utf8)
    )
  }

  @Test("A future workspace version is surfaced and cannot be downgraded")
  func futureVersionIsPreserved() async throws {
    let fixture = try WorkspaceFixture()
    defer { fixture.remove() }
    let id = WorkspaceID()
    let futureData = Data(#"{"version":77,"record":{"future":"state"}}"#.utf8)
    try futureData.write(to: fixture.fileURL(for: id), options: [.atomic])
    let repository = LocalWorkspaceRepository(directoryURL: fixture.directory)

    await #expect(
      throws: LocalWorkspaceRepositoryError.unsupportedVersion(77)
    ) {
      try await repository.load(id: id)
    }
    await #expect(
      throws: LocalWorkspaceRepositoryError.unsupportedVersion(77)
    ) {
      try await repository.save(WorkspaceRecord(id: id))
    }
    #expect(try Data(contentsOf: fixture.fileURL(for: id)) == futureData)
  }

  @Test("Closed records are retained for seven days and pruned deterministically")
  func closedRecordRetention() async throws {
    let fixture = try WorkspaceFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000)
    let staleID = WorkspaceID()
    let recentID = WorkspaceID()
    let openID = WorkspaceID()
    let repository = LocalWorkspaceRepository(
      directoryURL: fixture.directory,
      now: { now }
    )
    try await repository.save(
      WorkspaceRecord(
        id: staleID,
        closedAt: now.addingTimeInterval(-7 * 24 * 60 * 60)
      )
    )
    try await repository.save(
      WorkspaceRecord(
        id: recentID,
        closedAt: now.addingTimeInterval(-(7 * 24 * 60 * 60) + 1)
      )
    )
    try await repository.save(WorkspaceRecord(id: openID))

    try await repository.pruneClosed()

    #expect(!FileManager.default.fileExists(atPath: fixture.fileURL(for: staleID).path))
    #expect(FileManager.default.fileExists(atPath: fixture.fileURL(for: recentID).path))
    #expect(FileManager.default.fileExists(atPath: fixture.fileURL(for: openID).path))
  }

  @Test("Data protection is applied after atomic writes and on load")
  func appliesWorkspaceFilePolicy() async throws {
    let fixture = try WorkspaceFixture()
    defer { fixture.remove() }
    let id = WorkspaceID()
    let policy = RecordingWorkspaceFilePolicy()
    let repository = LocalWorkspaceRepository(
      directoryURL: fixture.directory,
      filePolicy: policy
    )

    try await repository.save(WorkspaceRecord(id: id))
    _ = try await repository.load(id: id)

    #expect(
      await policy.appliedURLs() == [
        fixture.fileURL(for: id),
        fixture.fileURL(for: id),
      ]
    )
  }
}

private actor RecordingWorkspaceFilePolicy: WorkspaceFilePolicy {
  private var urls: [URL] = []

  func apply(to url: URL) {
    urls.append(url)
  }

  func appliedURLs() -> [URL] { urls }
}

private struct WorkspaceFixture {
  let directory: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }

  func fileURL(for id: WorkspaceID) -> URL {
    directory.appending(
      path: "\(id.rawValue.uuidString.lowercased()).json",
      directoryHint: .notDirectory
    )
  }
}
