import Foundation
import JollysMQTTCore
import Testing

@Suite("Performance regression contracts")
struct PerformanceRegressionTests {
  @Test("The standard workload is an exact deterministic ten-minute fixture")
  func standardWorkload() {
    let fixture = PerformanceWorkloadFixture.standard

    #expect(fixture.topicCount == 10_000)
    #expect(fixture.messagesPerMinute == 100_000)
    #expect(fixture.durationSeconds == 600)
    #expect(fixture.totalMessageCount == 1_000_000)
    #expect(fixture.payloadBytes == 256)
    #expect(fixture.topicDistribution.hotTopicCount == 1_000)
    #expect(fixture.topicDistribution.hotMessagePercent == 80)
    #expect(fixture.payloadDistribution.scalarPercent == 50)
    #expect(fixture.payloadDistribution.jsonPercent == 40)
    #expect(fixture.payloadDistribution.binaryPercent == 10)

    let first = fixture.message(at: 0)
    let repeated = fixture.message(at: 0)
    let binary = fixture.message(at: 99)

    #expect(first == repeated)
    #expect(first.topic == "site/00/device/0000/telemetry")
    #expect(first.payload.count == 256)
    #expect(binary.payload.count == 256)
    #expect(String(data: binary.payload, encoding: .utf8) == nil)

    let generatedTopics = Set(
      (0..<45_000).map { fixture.message(at: $0).topic }
    )
    #expect(generatedTopics.count == 10_000)

    let payloads = (0..<100).map { fixture.message(at: $0).payload }
    #expect(payloads.count { $0.first == Character("v").asciiValue } == 50)
    #expect(payloads.count { $0.first == Character("{").asciiValue } == 40)
    #expect(payloads.count { $0.first == 0xFF } == 10)
  }

  @Test("A result preserves the complete reproducibility and lifecycle record")
  func completeResultRoundTrip() throws {
    let result = PerformanceRunResult.fixture()

    let encoded = try JSONEncoder().encode(result)
    let decoded = try JSONDecoder().decode(
      PerformanceRunResult.self,
      from: encoded
    )

    #expect(decoded == result)
    #expect(decoded.queuesReturnedToBaseline)
    #expect(decoded.isLifecycleClean)
    #expect(decoded.recordsEveryRequiredMetric)
  }

  @Test("Percentage tolerances fail only regressions beyond their reviewed limits")
  func percentageTolerance() {
    let baseline = PerformanceRegressionBaseline(
      revision: 3,
      reviewedAtUTC: "2026-07-29T10:00:00Z",
      reviewedBy: "release-owner",
      reviewReference: "issue-23",
      fixture: .standard,
      environment: .fixture,
      budgets: [
        PerformanceMetricBudget(
          metric: .ingestMessagesPerSecond,
          referenceValue: 2_000,
          allowedRegressionPercent: 10,
          direction: .higherIsBetter
        ),
        PerformanceMetricBudget(
          metric: .snapshotP95Milliseconds,
          referenceValue: 10,
          allowedRegressionPercent: 20,
          direction: .lowerIsBetter
        ),
      ]
    )

    let passing = baseline.evaluate(
      [
        .ingestMessagesPerSecond: 1_800,
        .snapshotP95Milliseconds: 12,
      ]
    )
    let failing = baseline.evaluate(
      [
        .ingestMessagesPerSecond: 1_799,
        .snapshotP95Milliseconds: 12.01,
      ]
    )

    #expect(passing.passed)
    #expect(
      failing.failures.map(\.metric) == [
        .ingestMessagesPerSecond,
        .snapshotP95Milliseconds,
      ])
  }

  @Test("A baseline update requires explicit review and advances its revision")
  func reviewedBaselineUpdate() throws {
    let result = PerformanceRunResult.fixture()
    let baseline = PerformanceRegressionBaseline(
      revision: 3,
      reviewedAtUTC: "2026-07-29T10:00:00Z",
      reviewedBy: "release-owner",
      reviewReference: "issue-23",
      fixture: .standard,
      environment: .fixture,
      budgets: PerformanceMetric.allCases.map { metric in
        PerformanceMetricBudget(
          metric: metric,
          referenceValue: result.regressionMeasurements[metric]!,
          allowedRegressionPercent: 10,
          direction:
            metric == .ingestMessagesPerSecond
            || metric == .historyMessagesPerSecond
            ? .higherIsBetter : .lowerIsBetter
        )
      }
    )

    #expect(throws: PerformanceBaselineUpdateError.missingReviewer) {
      try baseline.reviewedUpdate(
        from: .fixture(),
        reviewedAtUTC: "2026-07-30T10:00:00Z",
        reviewedBy: "",
        reviewReference: "issue-23"
      )
    }

    let updated = try baseline.reviewedUpdate(
      from: .fixture(),
      reviewedAtUTC: "2026-07-30T10:00:00Z",
      reviewedBy: "release-owner",
      reviewReference: "issue-23-comment-4"
    )

    #expect(updated.revision == 4)
    #expect(updated.reviewedBy == "release-owner")
    #expect(updated.reviewReference == "issue-23-comment-4")
    #expect(
      updated.budgets.first?.referenceValue
        == result.ingestMessagesPerSecond
    )
  }

  @Test("A partial baseline cannot be accepted as a reviewed update")
  func partialBaselineCannotBeUpdated() {
    let baseline = PerformanceRegressionBaseline(
      revision: 1,
      reviewedAtUTC: "2026-07-29T10:00:00Z",
      reviewedBy: "release-owner",
      reviewReference: "issue-23",
      fixture: .standard,
      environment: .fixture,
      budgets: [
        PerformanceMetricBudget(
          metric: .ingestMessagesPerSecond,
          referenceValue: 2_000,
          allowedRegressionPercent: 10,
          direction: .higherIsBetter
        )
      ]
    )

    #expect(
      throws: PerformanceBaselineUpdateError.incompleteMetricCoverage
    ) {
      try baseline.reviewedUpdate(
        from: .fixture(),
        reviewedAtUTC: "2026-07-30T10:00:00Z",
        reviewedBy: "release-owner",
        reviewReference: "issue-23-comment-4"
      )
    }
  }

  @Test("A zero main-actor update count remains a visible invalid result")
  func zeroMainActorUpdatesAreVisible() {
    let result = PerformanceRunResult.fixture(
      mainActorUpdateCount: 0,
      mainActorUpdatesPerSecond: 0
    )

    #expect(result.mainActorUpdateCount == 0)
    #expect(result.mainActorUpdatesPerSecond == 0)
    #expect(!result.recordsEveryRequiredMetric)
  }

  @Test("A result with incomplete durable history is invalid")
  func incompleteHistoryIsVisible() {
    let result = PerformanceRunResult.fixture(
      historyWrittenMessageCount: 999_999
    )

    #expect(!result.recordsEveryRequiredMetric)
  }
}

extension PerformanceLatencySummary {
  fileprivate static let fixture = PerformanceLatencySummary(
    sampleCount: 10,
    medianMilliseconds: 1,
    p95Milliseconds: 2,
    maximumMilliseconds: 3
  )
}

extension PerformanceEnvironment {
  fileprivate static let fixture = PerformanceEnvironment(
    hardwareModel: "Mac16,1",
    operatingSystem: "macOS 27.0",
    architecture: "arm64",
    buildConfiguration: "release",
    xcodeVersion: "Xcode 27.0"
  )
}

extension PerformanceRunResult {
  fileprivate static func fixture(
    mainActorUpdateCount: Int = 5_900,
    mainActorUpdatesPerSecond: Double = 9.83,
    historyWrittenMessageCount: Int = 1_000_000
  ) -> PerformanceRunResult {
    PerformanceRunResult(
      generatedAtUTC: "2026-07-29T10:00:00Z",
      fixture: .standard,
      environment: .fixture,
      elapsedSeconds: 600,
      ingestedMessageCount: 1_000_000,
      ingestMessagesPerSecond: 1_666.67,
      historyWrittenMessageCount: historyWrittenMessageCount,
      historyMessagesPerSecond: 25_000,
      historyDatabaseByteLimit: 250 * 1_024 * 1_024,
      peakObservedHistoryDatabaseBytes: 152 * 1_024 * 1_024,
      settledHistoryDatabaseBytes: 124 * 1_024 * 1_024,
      queueDepths: PerformanceQueueDepths(
        ingress: .init(baseline: 0, highWaterMark: 31, settled: 0),
        history: .init(baseline: 0, highWaterMark: 127, settled: 0),
        publish: .init(baseline: 0, highWaterMark: 32, settled: 0)
      ),
      mainActorUpdateCount: mainActorUpdateCount,
      mainActorUpdatesPerSecond: mainActorUpdatesPerSecond,
      snapshotCost: .fixture,
      outlineUpdateCost: .fixture,
      searchCost: .fixture,
      selectionCost: .fixture,
      freezeViewCost: .fixture,
      scrollPreparationCost: .fixture,
      chartCost: .fixture,
      baselineResidentBytes: 20_000_000,
      peakResidentBytes: 80_000_000,
      settledResidentBytes: 24_000_000,
      postStopResidentByteSamples: [24_100_000, 24_000_000, 24_050_000],
      memoryStabilized: true,
      feedOwnedStateReleased: true
    )
  }
}
