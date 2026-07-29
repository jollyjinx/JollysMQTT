import Foundation
import JollysMQTTCore

public struct TopicOutlineRowState: Equatable, Identifiable, Sendable {
  public let id: BrokerTopicID
  public let level: String
  public let fullTopic: String
  public let depth: Int
  public let hasChildren: Bool
  public let hasVisibleChildren: Bool
  public let isExpanded: Bool
  public let isExpansionForced: Bool
  public let allowsExpansionToggle: Bool
  public let isSelected: Bool
  public let hasValue: Bool
  public let isStale: Bool
  public let retained: Bool
  public let qos: MQTTQualityOfService?
  public let latestOrdinal: UInt64?
  public let descendantValueTopicCount: Int
  public let descendantMessageCount: UInt64
  public let payloadSummary: BrokerTopicPayloadSummary?
}

public enum TopicOutlineFeature {
  public struct State: Equatable, Sendable {
    public fileprivate(set) var selectedTopic: String?
    public fileprivate(set) var expandedTopics: Set<String>
    public fileprivate(set) var searchText: String
    public fileprivate(set) var sortMode: BrokerTopicSortMode
    public let expectedBrokerID: UUID?
    public fileprivate(set) var snapshot: BrokerTopicTreeSnapshot
    public fileprivate(set) var rows: [TopicOutlineRowState]
    public fileprivate(set) var isFrozen: Bool
    public fileprivate(set) var pendingChangeCount: Int
    public fileprivate(set) var pendingChangeCountIsCapped: Bool

    fileprivate let pendingChangeLimit: Int
    fileprivate var newestSnapshot: BrokerTopicTreeSnapshot

    public var expandedTopicIDs: Set<BrokerTopicID> {
      Set(
        rows.lazy
          .filter(\.isExpanded)
          .map(\.id)
      )
    }

    public init(
      selectedTopic: String? = nil,
      expandedTopics: Set<String> = [],
      searchText: String = "",
      sortMode: BrokerTopicSortMode = .name,
      expectedBrokerID: UUID? = nil,
      pendingChangeLimit: Int = 999
    ) {
      precondition(pendingChangeLimit > 0)
      self.selectedTopic = selectedTopic
      self.expandedTopics = expandedTopics
      self.searchText = searchText
      self.sortMode = sortMode
      self.expectedBrokerID = expectedBrokerID
      self.pendingChangeLimit = pendingChangeLimit
      self.snapshot = .empty
      self.newestSnapshot = .empty
      self.rows = []
      self.isFrozen = false
      self.pendingChangeCount = 0
      self.pendingChangeCountIsCapped = false
    }
  }

  public enum Intent: Equatable, Sendable {
    case selectTopic(BrokerTopicID?)
    case toggleExpansion(BrokerTopicID)
    case setSearchText(String)
    case setSortMode(BrokerTopicSortMode)
    case freezeView
    case jumpToLive
  }

  public enum Action: Equatable, Sendable {
    case snapshotReceived(BrokerTopicTreeSnapshot)
  }

  public static func reduce(state: inout State, intent: Intent) {
    switch intent {
    case .selectTopic(let id):
      if let id {
        guard state.rows.contains(where: { $0.id == id }) else { return }
        state.selectedTopic = id.fullTopic
      } else {
        state.selectedTopic = nil
      }
      rebuildRows(state: &state)

    case .toggleExpansion(let id):
      guard
        state.rows.contains(where: {
          $0.id == id && $0.allowsExpansionToggle
        })
      else {
        return
      }
      if state.expandedTopics.contains(id.fullTopic) {
        state.expandedTopics.remove(id.fullTopic)
      } else {
        state.expandedTopics.insert(id.fullTopic)
      }
      rebuildRows(state: &state)

    case .setSearchText(let text):
      state.searchText = text
      rebuildRows(state: &state)

    case .setSortMode(let mode):
      state.sortMode = mode
      rebuildRows(state: &state)

    case .freezeView:
      guard !state.isFrozen else { return }
      state.isFrozen = true
      state.newestSnapshot = state.snapshot
      updatePendingCount(state: &state)

    case .jumpToLive:
      guard state.isFrozen else { return }
      state.snapshot = state.newestSnapshot
      state.isFrozen = false
      state.pendingChangeCount = 0
      state.pendingChangeCountIsCapped = false
      rebuildRows(state: &state)
    }
  }

  public static func reduce(state: inout State, action: Action) {
    switch action {
    case .snapshotReceived(let snapshot):
      if let expectedBrokerID = state.expectedBrokerID,
        !snapshot.roots.allSatisfy({
          $0.id.brokerID == expectedBrokerID
        })
      {
        return
      }
      if snapshot.revision != 0,
        state.newestSnapshot.revision > snapshot.revision
      {
        return
      }
      if snapshot.revision == 0 {
        state.snapshot = snapshot
        state.newestSnapshot = snapshot
        state.isFrozen = false
        state.pendingChangeCount = 0
        state.pendingChangeCountIsCapped = false
        rebuildRows(state: &state)
      } else if state.isFrozen {
        state.newestSnapshot = snapshot
        updatePendingCount(state: &state)
      } else {
        state.snapshot = snapshot
        state.newestSnapshot = snapshot
        rebuildRows(state: &state)
      }
    }
  }

  private struct IndexedNode {
    let node: BrokerTopicNodeSnapshot
    let parentID: BrokerTopicID?
  }

  private static func rebuildRows(state: inout State) {
    let allNodes = index(snapshot: state.snapshot)
    let query = folded(state.searchText)
    let includedIDs: Set<BrokerTopicID>?
    if query.isEmpty {
      includedIDs = nil
    } else {
      let parents = Dictionary(
        uniqueKeysWithValues: allNodes.map {
          ($0.node.id, $0.parentID)
        }
      )
      var included: Set<BrokerTopicID> = []
      for indexed in allNodes
      where indexed.node.foldedFullTopicSearchText.contains(query)
        || (!indexed.node.isStale
          && indexed.node.payloadSummary?.foldedSearchText.contains(query)
            == true)
      {
        var next: BrokerTopicID? = indexed.node.id
        while let current = next, included.insert(current).inserted {
          next = parents[current] ?? nil
        }
      }
      includedIDs = included
    }

    var rows: [TopicOutlineRowState] = []
    var stack: [(BrokerTopicNodeSnapshot, Int)] = sorted(
      state.snapshot.roots,
      by: state.sortMode
    ).reversed().map { ($0, 0) }
    while let (node, depth) = stack.popLast() {
      if let includedIDs, !includedIDs.contains(node.id) {
        continue
      }
      let visibleChildren =
        includedIDs.map { includedIDs in
          node.children.filter { includedIDs.contains($0.id) }
        } ?? node.children
      let hasChildren = !node.children.isEmpty
      let hasVisibleChildren = !visibleChildren.isEmpty
      let isExpansionForced =
        includedIDs != nil && hasVisibleChildren
      let isExpanded =
        hasVisibleChildren
        && (isExpansionForced
          || state.expandedTopics.contains(node.fullTopic))
      let ownValueCount = node.latest == nil ? 0 : 1
      let ownMessageCount = node.messageCount
      rows.append(
        TopicOutlineRowState(
          id: node.id,
          level: node.level,
          fullTopic: node.fullTopic,
          depth: depth,
          hasChildren: hasChildren,
          hasVisibleChildren: hasVisibleChildren,
          isExpanded: isExpanded,
          isExpansionForced: isExpansionForced,
          allowsExpansionToggle:
            hasVisibleChildren && !isExpansionForced,
          isSelected: node.fullTopic == state.selectedTopic,
          hasValue: node.latest != nil,
          isStale: node.isStale,
          retained:
            !node.isStale && node.latest?.retained == true,
          qos: node.isStale ? nil : node.latest?.qos,
          latestOrdinal: node.isStale ? nil : node.latest?.ordinal,
          descendantValueTopicCount:
            node.subtreeValueTopicCount - ownValueCount,
          descendantMessageCount:
            node.subtreeMessageCount - ownMessageCount,
          payloadSummary: node.isStale ? nil : node.payloadSummary
        )
      )
      guard isExpanded else { continue }
      let children = sorted(visibleChildren, by: state.sortMode)
      for child in children.reversed() {
        stack.append((child, depth + 1))
      }
    }
    state.rows = rows
  }

  private static func index(
    snapshot: BrokerTopicTreeSnapshot
  ) -> [IndexedNode] {
    var indexed: [IndexedNode] = []
    var stack: [(node: BrokerTopicNodeSnapshot, parentID: BrokerTopicID?)] =
      snapshot.roots.reversed().map { ($0, nil) }
    while let frame = stack.popLast() {
      indexed.append(
        IndexedNode(
          node: frame.node,
          parentID: frame.parentID
        )
      )
      for child in frame.node.children.reversed() {
        stack.append((child, frame.node.id))
      }
    }
    return indexed
  }

  private static func sorted(
    _ nodes: [BrokerTopicNodeSnapshot],
    by mode: BrokerTopicSortMode
  ) -> [BrokerTopicNodeSnapshot] {
    nodes.sorted { lhs, rhs in
      switch mode {
      case .name:
        break
      case .recentActivity:
        let left = lhs.subtreeLatestReceivedAtMicroseconds ?? Int64.min
        let right = rhs.subtreeLatestReceivedAtMicroseconds ?? Int64.min
        if left != right { return left > right }
      case .descendantMessages:
        let left =
          lhs.subtreeMessageCount - lhs.messageCount
        let right =
          rhs.subtreeMessageCount - rhs.messageCount
        if left != right {
          return left > right
        }
      case .descendantTopics:
        let left =
          lhs.subtreeValueTopicCount - (lhs.latest == nil ? 0 : 1)
        let right =
          rhs.subtreeValueTopicCount - (rhs.latest == nil ? 0 : 1)
        if left != right {
          return left > right
        }
      }
      let comparison = lhs.level.localizedStandardCompare(rhs.level)
      if comparison != .orderedSame {
        return comparison == .orderedAscending
      }
      return lhs.fullTopic < rhs.fullTopic
    }
  }

  private static func folded(_ text: String) -> String {
    text.folding(
      options: [
        .caseInsensitive,
        .diacriticInsensitive,
        .widthInsensitive,
      ],
      locale: Locale(identifier: "en_US_POSIX")
    )
  }

  private static func updatePendingCount(state: inout State) {
    let difference: UInt64
    if state.newestSnapshot.totalMessageCount
      >= state.snapshot.totalMessageCount
    {
      difference =
        state.newestSnapshot.totalMessageCount
        - state.snapshot.totalMessageCount
    } else {
      difference = 0
    }
    let hasSnapshotChange =
      state.newestSnapshot.revision != state.snapshot.revision
    let pending = difference == 0 && hasSnapshotChange ? 1 : difference
    let limit = UInt64(state.pendingChangeLimit)
    state.pendingChangeCount = Int(min(pending, limit))
    state.pendingChangeCountIsCapped = pending > limit
  }
}
