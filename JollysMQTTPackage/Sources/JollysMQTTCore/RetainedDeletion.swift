import Foundation

extension BrokerTopicTreeSnapshot {
  /// Returns the current, locally known value-bearing topics below an exact
  /// topic identity. This is not a broker retained-message inventory.
  public func locallyKnownCurrentValueTopics(
    in subtree: BrokerTopicID
  ) -> [String] {
    var selectedNode: BrokerTopicNodeSnapshot?
    var search = Array(roots.reversed())
    while let node = search.popLast() {
      if node.id == subtree {
        selectedNode = node
        break
      }
      search.append(contentsOf: node.children.reversed())
    }
    guard let selectedNode else { return [] }

    var topicsByUTF8: [[UInt8]: String] = [:]
    var pending = [selectedNode]
    while let node = pending.popLast() {
      if !node.isStale, node.latest != nil {
        topicsByUTF8[Array(node.fullTopic.utf8)] = node.fullTopic
      }
      pending.append(contentsOf: node.children)
    }
    return
      topicsByUTF8
      .sorted { lhs, rhs in
        lhs.key.lexicographicallyPrecedes(rhs.key)
      }
      .map(\.value)
  }
}
