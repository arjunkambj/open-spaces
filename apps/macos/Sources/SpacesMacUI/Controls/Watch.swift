import Observation

/// Runs `apply` with the value `read` returns: once now, and again every time
/// that value changes. `read` may touch any `@Observable` object.
///
/// Keep the watch for as long as you want the updates; they stop when it is let go.
/// Capture owners weakly in both closures, or the watch keeps them alive.
@MainActor
public final class Watch<Value: Equatable & Sendable> {
  private let read: @MainActor () -> Value
  private let apply: @MainActor (Value) -> Void
  private var last: Value?

  public init(_ read: @escaping @MainActor () -> Value, apply: @escaping @MainActor (Value) -> Void) {
    self.read = read
    self.apply = apply
    refresh()
  }

  private func refresh() {
    let value = withObservationTracking {
      read()
    } onChange: { [weak self] in
      // Called just before the change lands, so look again on the next turn.
      Task { @MainActor [weak self] in self?.refresh() }
    }
    guard value != last else { return }
    last = value
    apply(value)
  }
}
