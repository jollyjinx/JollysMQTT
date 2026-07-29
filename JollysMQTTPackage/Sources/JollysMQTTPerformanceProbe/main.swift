import Foundation
import JollysMQTT
import JollysMQTTCore

@main
enum JollysMQTTPerformanceProbeCommand {
  static func main() async throws {
    let arguments = try Arguments(CommandLine.arguments)
    let result = try await JollysMQTTPerformanceProbe().run(
      PerformanceProbeConfiguration(
        fixture: arguments.fixture,
        paceProducer: arguments.paceProducer
      )
    )
    try validateHardReleaseGates(result)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let resultData = try encoder.encode(result)
    FileHandle.standardOutput.write(resultData)
    FileHandle.standardOutput.write(Data([0x0A]))
    if let outputURL = arguments.outputURL {
      try resultData.write(to: outputURL, options: .atomic)
    }

    if let acceptedBaselineURL = arguments.acceptedBaselineURL {
      let baseline: PerformanceRegressionBaseline
      if FileManager.default.fileExists(atPath: acceptedBaselineURL.path) {
        let current = try JSONDecoder().decode(
          PerformanceRegressionBaseline.self,
          from: Data(contentsOf: acceptedBaselineURL)
        )
        baseline = try current.reviewedUpdate(
          from: result,
          reviewedAtUTC: ISO8601DateFormatter().string(from: Date()),
          reviewedBy: try arguments.requiredReviewer(),
          reviewReference: try arguments.requiredReviewReference()
        )
      } else {
        baseline = try initialBaseline(
          from: result,
          reviewedBy: arguments.requiredReviewer(),
          reviewReference: arguments.requiredReviewReference()
        )
      }
      let baselineData = try encoder.encode(baseline)
      try baselineData.write(to: acceptedBaselineURL, options: .atomic)
      return
    }

    if let baselineURL = arguments.baselineURL {
      let baseline = try JSONDecoder().decode(
        PerformanceRegressionBaseline.self,
        from: Data(contentsOf: baselineURL)
      )
      guard baseline.hasCompleteMetricCoverage else {
        throw CommandError.incompleteBaseline
      }
      try validateContext(result, baseline: baseline)
      let evaluation = baseline.evaluate(result.regressionMeasurements)
      guard evaluation.passed else {
        throw CommandError.regression(evaluation.failures)
      }
    }
  }

  private static func validateHardReleaseGates(
    _ result: PerformanceRunResult
  ) throws {
    guard result.recordsEveryRequiredMetric else {
      throw CommandError.incompleteResult
    }
    guard
      result.historyWrittenMessageCount == result.ingestedMessageCount
    else {
      throw CommandError.incompleteHistory(
        written: result.historyWrittenMessageCount,
        ingested: result.ingestedMessageCount
      )
    }
    guard
      result.peakObservedHistoryDatabaseBytes
        <= result.historyDatabaseByteLimit,
      result.settledHistoryDatabaseBytes
        <= result.historyDatabaseByteLimit
    else {
      throw CommandError.historyDatabaseLimitExceeded
    }
    guard result.isLifecycleClean else {
      throw CommandError.lifecycleDidNotSettle
    }
    guard result.mainActorUpdatesPerSecond <= 10 else {
      throw CommandError.mainActorRateExceeded(
        result.mainActorUpdatesPerSecond
      )
    }
  }

  private static func validateContext(
    _ result: PerformanceRunResult,
    baseline: PerformanceRegressionBaseline
  ) throws {
    guard result.fixture == baseline.fixture else {
      throw CommandError.fixtureMismatch
    }
    guard result.environment == baseline.environment else {
      throw CommandError.environmentMismatch
    }
  }

  private static func initialBaseline(
    from result: PerformanceRunResult,
    reviewedBy: String,
    reviewReference: String
  ) throws -> PerformanceRegressionBaseline {
    let reviewer = reviewedBy.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let reference = reviewReference.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !reviewer.isEmpty else {
      throw PerformanceBaselineUpdateError.missingReviewer
    }
    guard !reference.isEmpty else {
      throw PerformanceBaselineUpdateError.missingReviewReference
    }
    let measurements = result.regressionMeasurements
    let budgets = try PerformanceMetric.allCases.map { metric in
      guard let value = measurements[metric] else {
        throw PerformanceBaselineUpdateError.missingMetric(metric)
      }
      let direction: PerformanceMetricDirection =
        switch metric {
        case .ingestMessagesPerSecond, .historyMessagesPerSecond:
          .higherIsBetter
        case .mainActorUpdatesPerSecond,
          .snapshotP95Milliseconds,
          .outlineUpdateP95Milliseconds,
          .searchP95Milliseconds,
          .selectionP95Milliseconds,
          .freezeViewP95Milliseconds,
          .scrollPreparationP95Milliseconds,
          .chartP95Milliseconds,
          .peakResidentByteDelta,
          .settledResidentByteDelta:
          .lowerIsBetter
        }
      let tolerance: Double =
        switch metric {
        case .ingestMessagesPerSecond, .historyMessagesPerSecond:
          10
        case .mainActorUpdatesPerSecond:
          5
        case .snapshotP95Milliseconds,
          .outlineUpdateP95Milliseconds,
          .searchP95Milliseconds,
          .selectionP95Milliseconds,
          .freezeViewP95Milliseconds,
          .scrollPreparationP95Milliseconds,
          .chartP95Milliseconds:
          20
        case .peakResidentByteDelta, .settledResidentByteDelta:
          15
        }
      return PerformanceMetricBudget(
        metric: metric,
        referenceValue: value,
        allowedRegressionPercent: tolerance,
        direction: direction
      )
    }
    return PerformanceRegressionBaseline(
      revision: 1,
      reviewedAtUTC: ISO8601DateFormatter().string(from: Date()),
      reviewedBy: reviewer,
      reviewReference: reference,
      fixture: result.fixture,
      environment: result.environment,
      budgets: budgets
    )
  }
}

private struct Arguments {
  let fixture: PerformanceWorkloadFixture
  let paceProducer: Bool
  let outputURL: URL?
  let baselineURL: URL?
  let acceptedBaselineURL: URL?
  let reviewer: String?
  let reviewReference: String?

  init(_ arguments: [String]) throws {
    var quick = false
    var unpaced = false
    var outputURL: URL?
    var baselineURL: URL?
    var acceptedBaselineURL: URL?
    var reviewer: String?
    var reviewReference: String?
    var index = 1
    while index < arguments.count {
      switch arguments[index] {
      case "--quick":
        quick = true
      case "--unpaced":
        unpaced = true
      case "--output":
        index += 1
        outputURL = try Self.url(at: index, arguments: arguments)
      case "--baseline":
        index += 1
        baselineURL = try Self.url(at: index, arguments: arguments)
      case "--accept-baseline":
        index += 1
        acceptedBaselineURL = try Self.url(
          at: index,
          arguments: arguments
        )
      case "--reviewed-by":
        index += 1
        reviewer = try Self.value(at: index, arguments: arguments)
      case "--review-reference":
        index += 1
        reviewReference = try Self.value(at: index, arguments: arguments)
      default:
        throw CommandError.invalidArgument(arguments[index])
      }
      index += 1
    }
    if baselineURL != nil, acceptedBaselineURL != nil {
      throw CommandError.conflictingBaselineModes
    }
    fixture =
      quick
      ? PerformanceWorkloadFixture(
        topicCount: 1_000,
        messagesPerMinute: 60_000,
        durationSeconds: 1,
        payloadBytes: 256,
        topicDistribution: PerformanceTopicDistribution(
          hotTopicCount: 100,
          hotMessagePercent: 80,
          seed: 0x4A_4D_51_54_54
        ),
        payloadDistribution: PerformancePayloadDistribution(
          scalarPercent: 50,
          jsonPercent: 40,
          binaryPercent: 10
        )
      )
      : .standard
    paceProducer = !unpaced
    self.outputURL = outputURL
    self.baselineURL = baselineURL
    self.acceptedBaselineURL = acceptedBaselineURL
    self.reviewer = reviewer
    self.reviewReference = reviewReference
  }

  func requiredReviewer() throws -> String {
    guard let reviewer else {
      throw PerformanceBaselineUpdateError.missingReviewer
    }
    return reviewer
  }

  func requiredReviewReference() throws -> String {
    guard let reviewReference else {
      throw PerformanceBaselineUpdateError.missingReviewReference
    }
    return reviewReference
  }

  private static func value(
    at index: Int,
    arguments: [String]
  ) throws -> String {
    guard arguments.indices.contains(index) else {
      throw CommandError.missingArgumentValue
    }
    return arguments[index]
  }

  private static func url(
    at index: Int,
    arguments: [String]
  ) throws -> URL {
    URL(fileURLWithPath: try value(at: index, arguments: arguments))
  }
}

private enum CommandError: Error {
  case invalidArgument(String)
  case missingArgumentValue
  case conflictingBaselineModes
  case incompleteResult
  case incompleteHistory(written: Int, ingested: Int)
  case incompleteBaseline
  case historyDatabaseLimitExceeded
  case lifecycleDidNotSettle
  case mainActorRateExceeded(Double)
  case fixtureMismatch
  case environmentMismatch
  case regression([PerformanceRegressionFailure])
}
