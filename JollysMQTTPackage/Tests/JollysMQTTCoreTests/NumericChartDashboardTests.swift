import Foundation
import JollysMQTTCore
import Testing

@Suite("Numeric chart dashboard domain")
struct NumericChartDashboardTests {
  @Test("Cards preserve distinct stable identity, order, and complete settings")
  func cardsPreserveIdentityOrderAndSettings() throws {
    let brokerID = UUID()
    let series = NumericChartSeries(
      id: NumericChartSeriesID(
        brokerID: brokerID,
        topic: "factory/temperature"
      ),
      conversion: NumericChartValueConversion(kind: .number)
    )
    let firstID = NumericChartCardID(
      rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    )
    let secondID = NumericChartCardID(
      rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    )
    let marker = NumericChartSampleClearMarker(
      historySourceID: "source",
      throughDurableOrder: 12,
      sampleIDs: [
        NumericChartSampleID(
          connectionEpoch: UUID(),
          ordinal: 42,
          direction: .received
        )
      ]
    )
    let dashboard = NumericChartDashboardConfiguration(
      cards: [
        NumericChartCardConfiguration(
          id: firstID,
          chart: NumericChartConfiguration(series: series),
          presentationStyle: .line,
          color: .system,
          gridSpan: .automatic
        ),
        NumericChartCardConfiguration(
          id: secondID,
          chart: NumericChartConfiguration(
            series: series,
            isPaused: true,
            sampleClearMarker: marker
          ),
          presentationStyle: .step,
          color: .orange,
          gridSpan: .full
        ),
      ]
    )

    let restored = try JSONDecoder().decode(
      NumericChartDashboardConfiguration.self,
      from: JSONEncoder().encode(dashboard)
    )

    #expect(restored == dashboard)
    #expect(restored.cards.map(\.id) == [firstID, secondID])
    #expect(restored.cards.map(\.chart.series.id).allSatisfy { $0 == series.id })
    #expect(restored.cards[1].chart.sampleClearMarker == marker)
  }

  @Test("Dashboard limits impose fixed aggregate work ceilings")
  func dashboardHasAggregateBounds() {
    let policy = NumericChartDashboardPolicy.default

    #expect(policy.maximumCardCount == 12)
    #expect(policy.maximumConcurrentHistoryLoads == 3)
    #expect(
      policy.maximumAggregateHistoryPayloadBytes
        == policy.maximumCardCount
        * policy.cardPolicy.maximumPayloadBytesPerLoad
    )
    #expect(
      policy.maximumAggregateRawSampleCount
        == policy.maximumCardCount
        * policy.cardPolicy.maximumRawSampleCount
    )
    #expect(
      policy.maximumAggregateDisplaySampleCount
        == policy.maximumCardCount
        * policy.cardPolicy.maximumDisplaySampleCount
    )
    #expect(policy.maximumAggregateHistoryPayloadBytes <= 16 * 1_024 * 1_024)
    #expect(policy.maximumAggregateRawSampleCount <= 8_192)
    #expect(policy.maximumAggregateDisplaySampleCount <= 8_192)
  }

  @Test("Duplicate persisted card IDs normalize by keeping the first occurrence")
  func duplicateCardIDsNormalizeDeterministically() throws {
    let brokerID = UUID()
    let id = NumericChartCardID(rawValue: UUID())
    let first = NumericChartCardConfiguration(
      id: id,
      chart: NumericChartConfiguration(
        series: NumericChartSeries(
          id: NumericChartSeriesID(
            brokerID: brokerID,
            topic: "first"
          ),
          conversion: NumericChartValueConversion(kind: .number)
        )
      )
    )
    let duplicate = NumericChartCardConfiguration(
      id: id,
      chart: NumericChartConfiguration(
        series: NumericChartSeries(
          id: NumericChartSeriesID(
            brokerID: brokerID,
            topic: "duplicate"
          ),
          conversion: NumericChartValueConversion(kind: .number)
        )
      )
    )
    let encodedCards = try JSONEncoder().encode([first, duplicate])
    let cardsObject = try JSONSerialization.jsonObject(with: encodedCards)
    let encodedDashboard = try JSONSerialization.data(
      withJSONObject: ["cards": cardsObject]
    )

    let restored = try JSONDecoder().decode(
      NumericChartDashboardConfiguration.self,
      from: encodedDashboard
    )

    #expect(restored.cards == [first])
  }
}
