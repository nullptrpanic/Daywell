import Foundation

extension DaywellState {
  /// Cancelling a task is durable: an old callback or a clock change cannot revive it.
  mutating func reconcileLockRules(at date: Date) {
    let sleeps = sessions.filter {
      !$0.isMorning && $0.cancelledAt == nil && $0.occurrence.start <= date
    }
    if let latest = sleeps.map(\.occurrence.start).max() {
      morningCancelledThrough = max(morningCancelledThrough ?? latest, latest)
    }
    if let lastGroup = fitness?.lastCompletedAt,
      sleeps.contains(where: { $0.occurrence.end > lastGroup })
    {
      fitness?.suppressLocking()
    }

    // Upgrade old overlapping snapshots deterministically; normal saves forbid overlap.
    let runningSleep = sleeps.filter { $0.occurrence.contains(date) }.sorted {
      $0.occurrence.start == $1.occurrence.start
        ? $0.id > $1.id : $0.occurrence.start > $1.occurrence.start
    }
    for old in runningSleep.dropFirst() {
      if let index = sessions.firstIndex(where: { $0.id == old.id }) {
        sessions[index].cancelledAt = date
      }
    }
    let latestMorning = morningWindows.filter { $0.start <= date }.max {
      $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
    }?.id
    for index in morningWindows.indices where morningWindows[index].start <= date {
      let window = morningWindows[index]
      if window.id != latestMorning || window.start <= (morningCancelledThrough ?? .distantPast)
        || !runningSleep.isEmpty || fitness?.isLocked(at: date) == true
      {
        morningWindows[index].cancelledAt = window.cancelledAt ?? date
      }
    }
    let cancelled = Set(morningWindows.filter { $0.cancelledAt != nil }.map(\.id))
    for index in sessions.indices {
      if let source = sessions[index].morningSourceID, cancelled.contains(source) {
        sessions[index].cancelledAt = sessions[index].cancelledAt ?? date
      }
    }
    if let reservation,
      !Set(reservation.grants.map(\.sessionID)).isSubset(
        of: Set(activeSessions(at: date).map(\.id)))
    {
      self.reservation = nil
    }
  }
}
