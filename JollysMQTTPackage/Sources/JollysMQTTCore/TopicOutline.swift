public enum BrokerTopicSortMode:
  String,
  CaseIterable,
  Codable,
  Equatable,
  Sendable
{
  case name
  case recentActivity
  case descendantMessages
  case descendantTopics
}
