import Foundation

public struct PerformanceTopicDistribution:
  Codable,
  Equatable,
  Sendable
{
  public let hotTopicCount: Int
  public let hotMessagePercent: Int
  public let seed: UInt64

  public init(
    hotTopicCount: Int,
    hotMessagePercent: Int,
    seed: UInt64
  ) {
    precondition(hotTopicCount > 0)
    precondition((1...99).contains(hotMessagePercent))
    self.hotTopicCount = hotTopicCount
    self.hotMessagePercent = hotMessagePercent
    self.seed = seed
  }
}

public struct PerformancePayloadDistribution:
  Codable,
  Equatable,
  Sendable
{
  public let scalarPercent: Int
  public let jsonPercent: Int
  public let binaryPercent: Int

  public init(
    scalarPercent: Int,
    jsonPercent: Int,
    binaryPercent: Int
  ) {
    precondition(scalarPercent >= 0)
    precondition(jsonPercent >= 0)
    precondition(binaryPercent >= 0)
    precondition(scalarPercent + jsonPercent + binaryPercent == 100)
    self.scalarPercent = scalarPercent
    self.jsonPercent = jsonPercent
    self.binaryPercent = binaryPercent
  }
}

public struct PerformanceFixtureMessage: Equatable, Sendable {
  public let topic: String
  public let payload: Data

  public init(topic: String, payload: Data) {
    self.topic = topic
    self.payload = payload
  }
}

public struct PerformanceWorkloadFixture:
  Codable,
  Equatable,
  Sendable
{
  public static let standard = PerformanceWorkloadFixture(
    topicCount: 10_000,
    messagesPerMinute: 100_000,
    durationSeconds: 600,
    payloadBytes: 256,
    topicDistribution: PerformanceTopicDistribution(
      hotTopicCount: 1_000,
      hotMessagePercent: 80,
      seed: 0x4A_4D_51_54_54
    ),
    payloadDistribution: PerformancePayloadDistribution(
      scalarPercent: 50,
      jsonPercent: 40,
      binaryPercent: 10
    )
  )

  public let topicCount: Int
  public let messagesPerMinute: Int
  public let durationSeconds: Int
  public let payloadBytes: Int
  public let topicDistribution: PerformanceTopicDistribution
  public let payloadDistribution: PerformancePayloadDistribution

  public var totalMessageCount: Int {
    messagesPerMinute * durationSeconds / 60
  }

  public init(
    topicCount: Int,
    messagesPerMinute: Int,
    durationSeconds: Int,
    payloadBytes: Int,
    topicDistribution: PerformanceTopicDistribution,
    payloadDistribution: PerformancePayloadDistribution
  ) {
    precondition(topicCount > 0)
    precondition(messagesPerMinute > 0)
    precondition(durationSeconds > 0)
    precondition(payloadBytes > 0)
    precondition(topicDistribution.hotTopicCount < topicCount)
    precondition(
      messagesPerMinute.multipliedReportingOverflow(
        by: durationSeconds
      ).overflow == false
    )
    self.topicCount = topicCount
    self.messagesPerMinute = messagesPerMinute
    self.durationSeconds = durationSeconds
    self.payloadBytes = payloadBytes
    self.topicDistribution = topicDistribution
    self.payloadDistribution = payloadDistribution
  }

  public func message(at index: Int) -> PerformanceFixtureMessage {
    precondition(index >= 0)
    let topicIndex = distributedTopicIndex(for: index)
    return PerformanceFixtureMessage(
      topic: String(
        format: "site/%02d/device/%04d/telemetry",
        locale: Locale(identifier: "en_US_POSIX"),
        topicIndex / 100,
        topicIndex
      ),
      payload: payload(for: index, topicIndex: topicIndex)
    )
  }

  private func distributedTopicIndex(for index: Int) -> Int {
    let hotPercent = topicDistribution.hotMessagePercent
    let remainder = index % 100
    if remainder < hotPercent {
      let ordinal = index / 100 * hotPercent + remainder
      return ordinal % topicDistribution.hotTopicCount
    }
    let coldTopicCount = topicCount - topicDistribution.hotTopicCount
    let coldOrdinal =
      index / 100 * (100 - hotPercent) + remainder - hotPercent
    return topicDistribution.hotTopicCount + coldOrdinal % coldTopicCount
  }

  private func payload(for index: Int, topicIndex: Int) -> Data {
    let distributionIndex = index % 100
    let scalarEnd = payloadDistribution.scalarPercent
    let jsonEnd = scalarEnd + payloadDistribution.jsonPercent
    if distributionIndex < scalarEnd {
      return paddedUTF8("value=\(index % 1_000_000)")
    }
    if distributionIndex < jsonEnd {
      return paddedUTF8(
        "{\"topic\":\(topicIndex),\"value\":\(index % 1_000_000)}"
      )
    }
    return Data(repeating: 0xFF, count: payloadBytes)
  }

  private func paddedUTF8(_ value: String) -> Data {
    var data = Data(value.utf8.prefix(payloadBytes))
    if data.count < payloadBytes {
      data.append(
        Data(repeating: 0x20, count: payloadBytes - data.count)
      )
    }
    return data
  }
}

public struct PerformanceEnvironment:
  Codable,
  Equatable,
  Sendable
{
  public let hardwareModel: String
  public let operatingSystem: String
  public let architecture: String
  public let buildConfiguration: String
  public let xcodeVersion: String

  public init(
    hardwareModel: String,
    operatingSystem: String,
    architecture: String,
    buildConfiguration: String,
    xcodeVersion: String
  ) {
    self.hardwareModel = hardwareModel
    self.operatingSystem = operatingSystem
    self.architecture = architecture
    self.buildConfiguration = buildConfiguration
    self.xcodeVersion = xcodeVersion
  }
}

public struct PerformanceQueueDepthSample:
  Codable,
  Equatable,
  Sendable
{
  public let baseline: Int
  public let highWaterMark: Int
  public let settled: Int

  public init(baseline: Int, highWaterMark: Int, settled: Int) {
    precondition(baseline >= 0)
    precondition(highWaterMark >= baseline)
    precondition(settled >= 0)
    self.baseline = baseline
    self.highWaterMark = highWaterMark
    self.settled = settled
  }

  public var returnedToBaseline: Bool {
    settled <= baseline
  }
}

public struct PerformanceQueueDepths:
  Codable,
  Equatable,
  Sendable
{
  public let ingress: PerformanceQueueDepthSample
  public let history: PerformanceQueueDepthSample
  public let publish: PerformanceQueueDepthSample

  public init(
    ingress: PerformanceQueueDepthSample,
    history: PerformanceQueueDepthSample,
    publish: PerformanceQueueDepthSample
  ) {
    self.ingress = ingress
    self.history = history
    self.publish = publish
  }

  public var returnedToBaseline: Bool {
    ingress.returnedToBaseline
      && history.returnedToBaseline
      && publish.returnedToBaseline
  }
}

public struct PerformanceLatencySummary:
  Codable,
  Equatable,
  Sendable
{
  public let sampleCount: Int
  public let medianMilliseconds: Double
  public let p95Milliseconds: Double
  public let maximumMilliseconds: Double

  public init(
    sampleCount: Int,
    medianMilliseconds: Double,
    p95Milliseconds: Double,
    maximumMilliseconds: Double
  ) {
    precondition(sampleCount > 0)
    precondition(medianMilliseconds >= 0)
    precondition(p95Milliseconds >= medianMilliseconds)
    precondition(maximumMilliseconds >= p95Milliseconds)
    self.sampleCount = sampleCount
    self.medianMilliseconds = medianMilliseconds
    self.p95Milliseconds = p95Milliseconds
    self.maximumMilliseconds = maximumMilliseconds
  }
}

public struct PerformanceRunResult:
  Codable,
  Equatable,
  Sendable
{
  public let generatedAtUTC: String
  public let fixture: PerformanceWorkloadFixture
  public let environment: PerformanceEnvironment
  public let elapsedSeconds: Double
  public let ingestedMessageCount: Int
  public let ingestMessagesPerSecond: Double
  public let historyWrittenMessageCount: Int
  public let historyMessagesPerSecond: Double
  public let historyDatabaseByteLimit: Int64
  public let peakObservedHistoryDatabaseBytes: Int64
  public let settledHistoryDatabaseBytes: Int64
  public let queueDepths: PerformanceQueueDepths
  public let mainActorUpdateCount: Int
  public let mainActorUpdatesPerSecond: Double
  public let snapshotCost: PerformanceLatencySummary
  public let outlineUpdateCost: PerformanceLatencySummary
  public let searchCost: PerformanceLatencySummary
  public let selectionCost: PerformanceLatencySummary
  public let freezeViewCost: PerformanceLatencySummary
  public let scrollPreparationCost: PerformanceLatencySummary
  public let chartCost: PerformanceLatencySummary
  public let baselineResidentBytes: UInt64
  public let peakResidentBytes: UInt64
  public let settledResidentBytes: UInt64
  public let postStopResidentByteSamples: [UInt64]
  public let memoryStabilized: Bool
  public let feedOwnedStateReleased: Bool

  public init(
    generatedAtUTC: String,
    fixture: PerformanceWorkloadFixture,
    environment: PerformanceEnvironment,
    elapsedSeconds: Double,
    ingestedMessageCount: Int,
    ingestMessagesPerSecond: Double,
    historyWrittenMessageCount: Int,
    historyMessagesPerSecond: Double,
    historyDatabaseByteLimit: Int64,
    peakObservedHistoryDatabaseBytes: Int64,
    settledHistoryDatabaseBytes: Int64,
    queueDepths: PerformanceQueueDepths,
    mainActorUpdateCount: Int,
    mainActorUpdatesPerSecond: Double,
    snapshotCost: PerformanceLatencySummary,
    outlineUpdateCost: PerformanceLatencySummary,
    searchCost: PerformanceLatencySummary,
    selectionCost: PerformanceLatencySummary,
    freezeViewCost: PerformanceLatencySummary,
    scrollPreparationCost: PerformanceLatencySummary,
    chartCost: PerformanceLatencySummary,
    baselineResidentBytes: UInt64,
    peakResidentBytes: UInt64,
    settledResidentBytes: UInt64,
    postStopResidentByteSamples: [UInt64],
    memoryStabilized: Bool,
    feedOwnedStateReleased: Bool
  ) {
    self.generatedAtUTC = generatedAtUTC
    self.fixture = fixture
    self.environment = environment
    self.elapsedSeconds = elapsedSeconds
    self.ingestedMessageCount = ingestedMessageCount
    self.ingestMessagesPerSecond = ingestMessagesPerSecond
    self.historyWrittenMessageCount = historyWrittenMessageCount
    self.historyMessagesPerSecond = historyMessagesPerSecond
    self.historyDatabaseByteLimit = historyDatabaseByteLimit
    self.peakObservedHistoryDatabaseBytes =
      peakObservedHistoryDatabaseBytes
    self.settledHistoryDatabaseBytes = settledHistoryDatabaseBytes
    self.queueDepths = queueDepths
    self.mainActorUpdateCount = mainActorUpdateCount
    self.mainActorUpdatesPerSecond = mainActorUpdatesPerSecond
    self.snapshotCost = snapshotCost
    self.outlineUpdateCost = outlineUpdateCost
    self.searchCost = searchCost
    self.selectionCost = selectionCost
    self.freezeViewCost = freezeViewCost
    self.scrollPreparationCost = scrollPreparationCost
    self.chartCost = chartCost
    self.baselineResidentBytes = baselineResidentBytes
    self.peakResidentBytes = peakResidentBytes
    self.settledResidentBytes = settledResidentBytes
    self.postStopResidentByteSamples = postStopResidentByteSamples
    self.memoryStabilized = memoryStabilized
    self.feedOwnedStateReleased = feedOwnedStateReleased
  }

  public var queuesReturnedToBaseline: Bool {
    queueDepths.returnedToBaseline
  }

  public var isLifecycleClean: Bool {
    queuesReturnedToBaseline
      && memoryStabilized
      && feedOwnedStateReleased
  }

  public var recordsEveryRequiredMetric: Bool {
    let environmentValues = [
      environment.hardwareModel,
      environment.operatingSystem,
      environment.architecture,
      environment.buildConfiguration,
      environment.xcodeVersion,
    ]
    let latencyValues = [
      snapshotCost,
      outlineUpdateCost,
      searchCost,
      selectionCost,
      freezeViewCost,
      scrollPreparationCost,
      chartCost,
    ]
    return !generatedAtUTC.isEmpty
      && environmentValues.allSatisfy { !$0.isEmpty }
      && elapsedSeconds > 0
      && ingestedMessageCount > 0
      && ingestMessagesPerSecond > 0
      && historyWrittenMessageCount > 0
      && historyWrittenMessageCount == ingestedMessageCount
      && historyMessagesPerSecond > 0
      && historyDatabaseByteLimit > 0
      && peakObservedHistoryDatabaseBytes > 0
      && peakObservedHistoryDatabaseBytes <= historyDatabaseByteLimit
      && settledHistoryDatabaseBytes > 0
      && settledHistoryDatabaseBytes <= historyDatabaseByteLimit
      && mainActorUpdateCount > 0
      && mainActorUpdatesPerSecond > 0
      && latencyValues.allSatisfy { $0.sampleCount > 0 }
      && peakResidentBytes >= baselineResidentBytes
      && !postStopResidentByteSamples.isEmpty
  }
}

public enum PerformanceMetric:
  String,
  CaseIterable,
  Codable,
  Hashable,
  Sendable
{
  case ingestMessagesPerSecond
  case historyMessagesPerSecond
  case mainActorUpdatesPerSecond
  case snapshotP95Milliseconds
  case outlineUpdateP95Milliseconds
  case searchP95Milliseconds
  case selectionP95Milliseconds
  case freezeViewP95Milliseconds
  case scrollPreparationP95Milliseconds
  case chartP95Milliseconds
  case peakResidentByteDelta
  case settledResidentByteDelta
}

public enum PerformanceMetricDirection:
  String,
  Codable,
  Equatable,
  Sendable
{
  case higherIsBetter
  case lowerIsBetter
}

public struct PerformanceMetricBudget:
  Codable,
  Equatable,
  Sendable
{
  public let metric: PerformanceMetric
  public let referenceValue: Double
  public let allowedRegressionPercent: Double
  public let direction: PerformanceMetricDirection

  public init(
    metric: PerformanceMetric,
    referenceValue: Double,
    allowedRegressionPercent: Double,
    direction: PerformanceMetricDirection
  ) {
    precondition(referenceValue >= 0 && referenceValue.isFinite)
    precondition(
      allowedRegressionPercent >= 0
        && allowedRegressionPercent.isFinite
    )
    self.metric = metric
    self.referenceValue = referenceValue
    self.allowedRegressionPercent = allowedRegressionPercent
    self.direction = direction
  }

  public var failureThreshold: Double {
    let fraction = allowedRegressionPercent / 100
    switch direction {
    case .higherIsBetter:
      return referenceValue * max(0, 1 - fraction)
    case .lowerIsBetter:
      return referenceValue * (1 + fraction)
    }
  }

  public func passes(_ actualValue: Double) -> Bool {
    guard actualValue.isFinite, actualValue >= 0 else { return false }
    switch direction {
    case .higherIsBetter:
      return actualValue >= failureThreshold
    case .lowerIsBetter:
      return actualValue <= failureThreshold
    }
  }
}

public struct PerformanceRegressionFailure:
  Codable,
  Equatable,
  Sendable
{
  public let metric: PerformanceMetric
  public let actualValue: Double?
  public let failureThreshold: Double
  public let direction: PerformanceMetricDirection

  public init(
    metric: PerformanceMetric,
    actualValue: Double?,
    failureThreshold: Double,
    direction: PerformanceMetricDirection
  ) {
    self.metric = metric
    self.actualValue = actualValue
    self.failureThreshold = failureThreshold
    self.direction = direction
  }
}

public struct PerformanceRegressionEvaluation:
  Codable,
  Equatable,
  Sendable
{
  public let failures: [PerformanceRegressionFailure]

  public init(failures: [PerformanceRegressionFailure]) {
    self.failures = failures
  }

  public var passed: Bool {
    failures.isEmpty
  }
}

public struct PerformanceRegressionBaseline:
  Codable,
  Equatable,
  Sendable
{
  public let revision: Int
  public let reviewedAtUTC: String
  public let reviewedBy: String
  public let reviewReference: String
  public let fixture: PerformanceWorkloadFixture
  public let environment: PerformanceEnvironment
  public let budgets: [PerformanceMetricBudget]

  public init(
    revision: Int,
    reviewedAtUTC: String,
    reviewedBy: String,
    reviewReference: String,
    fixture: PerformanceWorkloadFixture,
    environment: PerformanceEnvironment,
    budgets: [PerformanceMetricBudget]
  ) {
    precondition(revision > 0)
    precondition(!reviewedAtUTC.isEmpty)
    precondition(!reviewedBy.isEmpty)
    precondition(!reviewReference.isEmpty)
    precondition(Set(budgets.map(\.metric)).count == budgets.count)
    self.revision = revision
    self.reviewedAtUTC = reviewedAtUTC
    self.reviewedBy = reviewedBy
    self.reviewReference = reviewReference
    self.fixture = fixture
    self.environment = environment
    self.budgets = budgets
  }

  public func evaluate(
    _ measurements: [PerformanceMetric: Double]
  ) -> PerformanceRegressionEvaluation {
    PerformanceRegressionEvaluation(
      failures: budgets.compactMap { budget in
        let actual = measurements[budget.metric]
        guard let actual, budget.passes(actual) else {
          return PerformanceRegressionFailure(
            metric: budget.metric,
            actualValue: actual,
            failureThreshold: budget.failureThreshold,
            direction: budget.direction
          )
        }
        return nil
      }
    )
  }

  public var hasCompleteMetricCoverage: Bool {
    budgets.count == PerformanceMetric.allCases.count
      && Set(budgets.map(\.metric)) == Set(PerformanceMetric.allCases)
  }

  public func reviewedUpdate(
    from result: PerformanceRunResult,
    reviewedAtUTC: String,
    reviewedBy: String,
    reviewReference: String
  ) throws -> PerformanceRegressionBaseline {
    guard
      !reviewedAtUTC.trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty
    else {
      throw PerformanceBaselineUpdateError.missingReviewDate
    }
    guard !reviewedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw PerformanceBaselineUpdateError.missingReviewer
    }
    guard
      !reviewReference.trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty
    else {
      throw PerformanceBaselineUpdateError.missingReviewReference
    }
    guard result.recordsEveryRequiredMetric else {
      throw PerformanceBaselineUpdateError.incompleteResult
    }
    guard result.isLifecycleClean else {
      throw PerformanceBaselineUpdateError.lifecycleDidNotSettle
    }
    guard hasCompleteMetricCoverage else {
      throw PerformanceBaselineUpdateError.incompleteMetricCoverage
    }
    let measurements = result.regressionMeasurements
    let updatedBudgets = try budgets.map { budget in
      guard let referenceValue = measurements[budget.metric] else {
        throw PerformanceBaselineUpdateError.missingMetric(budget.metric)
      }
      return PerformanceMetricBudget(
        metric: budget.metric,
        referenceValue: referenceValue,
        allowedRegressionPercent: budget.allowedRegressionPercent,
        direction: budget.direction
      )
    }
    return PerformanceRegressionBaseline(
      revision: revision + 1,
      reviewedAtUTC: reviewedAtUTC,
      reviewedBy: reviewedBy,
      reviewReference: reviewReference,
      fixture: result.fixture,
      environment: result.environment,
      budgets: updatedBudgets
    )
  }
}

public enum PerformanceBaselineUpdateError:
  Error,
  Equatable,
  Sendable
{
  case missingReviewDate
  case missingReviewer
  case missingReviewReference
  case incompleteResult
  case lifecycleDidNotSettle
  case incompleteMetricCoverage
  case missingMetric(PerformanceMetric)
}

extension PerformanceRunResult {
  public var regressionMeasurements: [PerformanceMetric: Double] {
    [
      .ingestMessagesPerSecond: ingestMessagesPerSecond,
      .historyMessagesPerSecond: historyMessagesPerSecond,
      .mainActorUpdatesPerSecond: mainActorUpdatesPerSecond,
      .snapshotP95Milliseconds: snapshotCost.p95Milliseconds,
      .outlineUpdateP95Milliseconds:
        outlineUpdateCost.p95Milliseconds,
      .searchP95Milliseconds: searchCost.p95Milliseconds,
      .selectionP95Milliseconds: selectionCost.p95Milliseconds,
      .freezeViewP95Milliseconds: freezeViewCost.p95Milliseconds,
      .scrollPreparationP95Milliseconds:
        scrollPreparationCost.p95Milliseconds,
      .chartP95Milliseconds: chartCost.p95Milliseconds,
      .peakResidentByteDelta:
        Double(
          peakResidentBytes >= baselineResidentBytes
            ? peakResidentBytes - baselineResidentBytes
            : 0
        ),
      .settledResidentByteDelta:
        Double(
          settledResidentBytes >= baselineResidentBytes
            ? settledResidentBytes - baselineResidentBytes
            : 0
        ),
    ]
  }
}
