import Foundation
import JollysMQTTCore
import Testing

@Suite("History retention policy")
struct HistoryRetentionPolicyTests {
  @Test(
    "Every configurable retention field rejects values outside its documented bounds",
    arguments: [
      InvalidRetentionPolicyCase(
        topicMessageLimit: 0,
        expected: .topicMessageLimit(0)
      ),
      InvalidRetentionPolicyCase(
        topicMessageLimit: 1_000_001,
        expected: .topicMessageLimit(1_000_001)
      ),
      InvalidRetentionPolicyCase(
        brokerByteLimit: 15 * 1_024 * 1_024,
        expected: .brokerByteLimit(15 * 1_024 * 1_024)
      ),
      InvalidRetentionPolicyCase(
        brokerByteLimit: 4 * 1_024 * 1_024 * 1_024 * 1_024 + 1,
        expected: .brokerByteLimit(
          4 * 1_024 * 1_024 * 1_024 * 1_024 + 1
        )
      ),
      InvalidRetentionPolicyCase(
        payloadByteLimit: 0,
        expected: .payloadByteLimit(0)
      ),
      InvalidRetentionPolicyCase(
        brokerByteLimit: 4 * 1_024 * 1_024 * 1_024 * 1_024,
        payloadByteLimit: 64 * 1_024 * 1_024 + 1,
        expected: .payloadByteLimit(64 * 1_024 * 1_024 + 1)
      ),
      InvalidRetentionPolicyCase(
        messagePruneBatchLimit: 0,
        expected: .messagePruneBatchLimit(0)
      ),
      InvalidRetentionPolicyCase(
        messagePruneBatchLimit: 5_001,
        expected: .messagePruneBatchLimit(5_001)
      ),
      InvalidRetentionPolicyCase(
        vacuumPageLimit: 0,
        expected: .vacuumPageLimit(0)
      ),
      InvalidRetentionPolicyCase(
        vacuumPageLimit: 8_193,
        expected: .vacuumPageLimit(8_193)
      ),
      InvalidRetentionPolicyCase(
        brokerByteLimit: 64 * 1_024 * 1_024,
        payloadByteLimit: 7 * 1_024 * 1_024,
        expected: .payloadExceedsBrokerSlack(
          payloadByteLimit: 7 * 1_024 * 1_024,
          brokerByteLimit: 64 * 1_024 * 1_024
        )
      ),
    ]
  )
  func rejectsInvalidBounds(_ testCase: InvalidRetentionPolicyCase) {
    #expect(
      throws: testCase.expected
    ) {
      try HistoryRetentionPolicy(
        topicMessageLimit: testCase.topicMessageLimit,
        brokerByteLimit: testCase.brokerByteLimit,
        payloadByteLimit: testCase.payloadByteLimit,
        messagePruneBatchLimit: testCase.messagePruneBatchLimit,
        vacuumPageLimit: testCase.vacuumPageLimit
      )
    }
  }

  @Test("Exact lower and upper boundaries are valid")
  func exactBoundariesAreValid() throws {
    let lower = try HistoryRetentionPolicy(
      topicMessageLimit: 1,
      brokerByteLimit: 16 * 1_024 * 1_024,
      payloadByteLimit: 1,
      messagePruneBatchLimit: 1,
      vacuumPageLimit: 1
    )
    #expect(lower.topicMessageLimit == 1)
    #expect(lower.brokerByteLimit == 16 * 1_024 * 1_024)

    let upper = try HistoryRetentionPolicy(
      topicMessageLimit: 1_000_000,
      brokerByteLimit: 4 * 1_024 * 1_024 * 1_024 * 1_024,
      payloadByteLimit: 64 * 1_024 * 1_024,
      messagePruneBatchLimit: 5_000,
      vacuumPageLimit: 8_192
    )
    #expect(upper.topicMessageLimit == 1_000_000)
    #expect(upper.payloadByteLimit == 64 * 1_024 * 1_024)
  }

  @Test("Defaults remain the documented release policy")
  func defaults() {
    #expect(HistoryRetentionPolicy.default.topicMessageLimit == 1_000)
    #expect(
      HistoryRetentionPolicy.default.brokerByteLimit
        == 250 * 1_024 * 1_024
    )
    #expect(
      HistoryRetentionPolicy.default.payloadByteLimit == 1_048_576
    )
    #expect(
      HistoryRetentionPolicy.default.messagePruneBatchLimit == 5_000
    )
    #expect(HistoryRetentionPolicy.default.vacuumPageLimit == 8_192)
  }

  @Test("Decoding applies the same validation as direct construction")
  func decodingRejectsInvalidPolicy() {
    let encoded = Data(
      """
      {
        "topicMessageLimit": 0,
        "brokerByteLimit": 262144000,
        "payloadByteLimit": 1048576,
        "messagePruneBatchLimit": 5000,
        "vacuumPageLimit": 8192
      }
      """.utf8
    )

    #expect(
      throws: HistoryRetentionPolicyValidationError.topicMessageLimit(0)
    ) {
      try JSONDecoder().decode(
        HistoryRetentionPolicy.self,
        from: encoded
      )
    }
  }
}

struct InvalidRetentionPolicyCase: Sendable {
  let topicMessageLimit: Int
  let brokerByteLimit: Int64
  let payloadByteLimit: Int
  let messagePruneBatchLimit: Int
  let vacuumPageLimit: Int
  let expected: HistoryRetentionPolicyValidationError

  init(
    topicMessageLimit: Int = 1_000,
    brokerByteLimit: Int64 = 250 * 1_024 * 1_024,
    payloadByteLimit: Int = 1_048_576,
    messagePruneBatchLimit: Int = 5_000,
    vacuumPageLimit: Int = 8_192,
    expected: HistoryRetentionPolicyValidationError
  ) {
    self.topicMessageLimit = topicMessageLimit
    self.brokerByteLimit = brokerByteLimit
    self.payloadByteLimit = payloadByteLimit
    self.messagePruneBatchLimit = messagePruneBatchLimit
    self.vacuumPageLimit = vacuumPageLimit
    self.expected = expected
  }
}
