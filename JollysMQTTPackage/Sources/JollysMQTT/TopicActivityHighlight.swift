import SwiftUI

/// A coalesced subtree counter also changes for a collapsed ancestor and for
/// repeated payloads. Only mounted rows own a short, cancellable highlight task.
struct TopicActivityHighlight: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let messageCount: UInt64
  let latestReceivedAtMicroseconds: Int64?
  let isFrozen: Bool
  let isSelected: Bool

  @State private var previousMessageCount: UInt64?
  @State private var highlighted = false

  private struct Trigger: Equatable {
    let count: UInt64
    let frozen: Bool
  }

  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        RoundedRectangle(cornerRadius: 3)
          .fill(Color.green.opacity(highlighted ? (isSelected ? 0.30 : 0.18) : 0))
      }
      .overlay(alignment: .leading) {
        RoundedRectangle(cornerRadius: 1)
          .fill(Color.green)
          .frame(width: 3)
          .opacity(highlighted ? 1 : 0)
          .accessibilityHidden(true)
      }
      .task(id: Trigger(count: messageCount, frozen: isFrozen)) {
        let previous = previousMessageCount
        previousMessageCount = messageCount
        guard !isFrozen,
          previous.map({ messageCount > $0 }) ?? isRecentDelivery
        else {
          highlighted = false
          return
        }
        // Reset immediately even if the previous fade was still in progress.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { highlighted = true }
        do {
          try await Task.sleep(for: .milliseconds(800))
        } catch {
          return
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.4)) {
          highlighted = false
        }
      }
  }

  private var isRecentDelivery: Bool {
    guard let latestReceivedAtMicroseconds, messageCount > 0 else { return false }
    let age = Date().timeIntervalSince1970
      - Double(latestReceivedAtMicroseconds) / 1_000_000
    return age >= 0 && age < 1.2
  }
}
