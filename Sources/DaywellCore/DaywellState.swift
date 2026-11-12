import Foundation

public struct Exemption: Codable, Equatable, Sendable {
  public let requestID: UUID
  public let start: Date
  public let end: Date
}

public struct LockSession: Codable, Equatable, Sendable, Identifiable {
  public let period: LockPeriod
  public let occurrence: PeriodOccurrence
  public internal(set) var selectionData: Data
  public let policy: ExemptionPolicy
  public internal(set) var usedCount = 0
  // Uses made by the matching sleep/morning session; retained when that history is pruned.
  public internal(set) var linkedUsedCount: Int?
  public internal(set) var exemption: Exemption?
  public let morningSourceID: String?
  public internal(set) var cancelledAt: Date? = nil
  public var isMorning: Bool { morningSourceID != nil }
  public var id: String { morningSourceID.map { "morning." + $0 } ?? occurrence.id }
  public var remainingCount: Int {
    max(0, policy.allowedCount - usedCount - (linkedUsedCount ?? 0))
  }
  public var nextExemptionMinutes: Int? {
    policy.durationMinutes(forUseAt: policy.allowedCount - remainingCount)
  }
  public func isExempt(at date: Date) -> Bool {
    guard let exemption else { return false }
    return exemption.start <= date && date < exemption.end
  }
}

public struct ExemptionReservation: Codable, Equatable, Sendable, Identifiable {
  public struct Grant: Codable, Equatable, Sendable {
    public let sessionID: String
    public let end: Date
  }

  public let id: UUID
  public let createdAt: Date
  public let grants: [Grant]
  public var validUntil: Date { createdAt.addingTimeInterval(30) }
}

public struct ExemptionOffer: Equatable, Sendable {
  public let duration: TimeInterval
  public let remainingCount: Int
  public var durationLabel: String {
    duration < 60 ? "不足 1 分钟" : "最多 \(Int(ceil(duration / 60))) 分钟"
  }
}

public struct DaywellState: Codable, Equatable, Sendable {
  public var schemaVersion = 2
  public internal(set) var revision: UInt64 = 0
  public var periods: [LockPeriod] = []
  public var selectionData: Data?
  public var alwaysAllowedApplicationsData: Data?
  public var policy = ExemptionPolicy.standard
  public var morningPolicy = MorningPolicy.standard
  public var fitness: FitnessTraining?
  public internal(set) var sessions: [LockSession] = []
  public internal(set) var morningWindows: [MorningWindow] = []
  public internal(set) var reservation: ExemptionReservation?
  public var monitoringError: String?
  public internal(set) var morningCancelledThrough: Date?
  public internal(set) var lastEvaluatedAt: Date?
  // High-water mark of reusable sleep shield stores, including the original store.
  // Persist it so another process can clear every batch after an exemption or stop.
  public var sleepShieldStoreCount = 1
  public var hadAuthorization = false
  public var needsApplicationReselection = false

  public init() {}

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let version = try values.decode(Int.self, forKey: .schemaVersion)
    guard version == 1 || version == 2 else { throw DaywellError.unsupportedSchema }
    revision = try values.decode(UInt64.self, forKey: .revision)
    periods = try values.decode([LockPeriod].self, forKey: .periods)
    selectionData = try values.decodeIfPresent(Data.self, forKey: .selectionData)
    alwaysAllowedApplicationsData = try values.decodeIfPresent(
      Data.self, forKey: .alwaysAllowedApplicationsData)
    policy = try values.decode(ExemptionPolicy.self, forKey: .policy)
    sessions = try values.decode([LockSession].self, forKey: .sessions)
    morningWindows =
      version == 1 ? [] : try values.decode([MorningWindow].self, forKey: .morningWindows)
    morningPolicy =
      version == 1 ? .standard : try values.decode(MorningPolicy.self, forKey: .morningPolicy)
    fitness = try values.decodeIfPresent(FitnessTraining.self, forKey: .fitness)
    morningCancelledThrough = try values.decodeIfPresent(
      Date.self, forKey: .morningCancelledThrough)
    lastEvaluatedAt = try values.decodeIfPresent(Date.self, forKey: .lastEvaluatedAt)
    reservation = try values.decodeIfPresent(ExemptionReservation.self, forKey: .reservation)
    monitoringError = try values.decodeIfPresent(String.self, forKey: .monitoringError)
    sleepShieldStoreCount =
      try values.decodeIfPresent(Int.self, forKey: .sleepShieldStoreCount) ?? 1
    hadAuthorization = try values.decode(Bool.self, forKey: .hadAuthorization)
    needsApplicationReselection = try values.decode(Bool.self, forKey: .needsApplicationReselection)
    synchronizeLinkedExemptionCounts()
  }

  public func activeSessions(at date: Date) -> [LockSession] {
    sessions.filter { $0.cancelledAt == nil && $0.occurrence.contains(date) }
  }

  public func blockingSessions(at date: Date) -> [LockSession] {
    activeSessions(at: date).filter { !$0.isExempt(at: date) }
  }

  public func hasFitnessRestriction(at date: Date) -> Bool {
    hadAuthorization && !activeSessions(at: date).contains { !$0.isMorning }
      && fitness?.isLocked(at: date) == true
  }

  public func exemptionOffer(at date: Date) -> ExemptionOffer? {
    let blocking = blockingSessions(at: date)
    guard !hasFitnessRestriction(at: date),
      !needsApplicationReselection, monitoringError == nil, !blocking.isEmpty,
      blocking.allSatisfy({ $0.remainingCount > 0 }),
      reservation.map({ date >= $0.validUntil }) ?? true
    else { return nil }
    var preview = self
    guard (try? preview.reserveExemption(at: date)) != nil else { return nil }
    let grantEnds = blocking.compactMap { session -> Date? in
      guard let minutes = session.nextExemptionMinutes else { return nil }
      return min(session.occurrence.end, date.addingTimeInterval(Double(minutes) * 60))
    }
    let existingEnds = activeSessions(at: date).filter { $0.isExempt(at: date) }
      .compactMap(\.exemption?.end)
    guard let end = (grantEnds + existingEnds).min(), end > date else { return nil }
    return ExemptionOffer(
      duration: end.timeIntervalSince(date), remainingCount: blocking.map(\.remainingCount).min()!)
  }

  public mutating func refresh(at date: Date, calendar: Calendar) {
    defer {
      prepareMornings(at: date, calendar: calendar)
      reconcileLockRules(at: date)
      synchronizeLinkedExemptionCounts()
      lastEvaluatedAt = max(lastEvaluatedAt ?? date, date)
    }
    // Retain recent occurrences so relaunching or moving the clock back doesn't reset their quota.
    fitness?.refresh(at: date)
    let retention = date.addingTimeInterval(-8 * 24 * 60 * 60)
    sessions.removeAll { $0.occurrence.end < retention }
    if let reservation, date >= reservation.validUntil { self.reservation = nil }
    let preservedPeriods = Set(
      activeSessions(at: date).filter { !$0.isMorning }.map(\.period.id))
    for index in periods.indices {
      // Older versions left this fence behind after a verified stop and re-enable.
      // A future fence is meaningful only while its original session is still running.
      if periods[index].isEnabled, let fence = periods[index].effectiveAfter,
        fence > date, !preservedPeriods.contains(periods[index].id)
      {
        periods[index].effectiveAfter = nil
      }
    }
    guard let selectionData, !needsApplicationReselection else { return }
    for period in periods {
      // Keep the original absolute interval stable during edits and time-zone changes.
      guard
        !activeSessions(at: date).contains(where: { !$0.isMorning && $0.period.id == period.id })
      else { continue }
      var occurrences = [PeriodOccurrence]()
      if let current = period.occurrence(containing: date, calendar: calendar) {
        occurrences.append(current)
      }
      // Catch up a short sleep that started and ended while the app/extension was idle.
      var cursor = max(lastEvaluatedAt ?? date, retention)
      while cursor < date,
        let next = period.nextOccurrence(after: cursor, calendar: calendar), next.start <= date
      {
        occurrences.append(next)
        cursor = next.start
      }
      for occurrence in occurrences where !sessions.contains(where: { $0.id == occurrence.id }) {
        sessions.append(
          LockSession(
            period: period, occurrence: occurrence,
            selectionData: selectionData, policy: policy.normalizedForConfiguration,
            morningSourceID: nil))
      }
    }
  }

  public mutating func savePeriod(_ period: LockPeriod, at date: Date, calendar: Calendar) throws {
    try savePeriod(period, at: date, calendar: calendar, verifiedSessionIDs: [])
  }

  public mutating func savePeriod(
    _ period: LockPeriod, at date: Date, calendar: Calendar, verifiedSessionIDs: Set<String>
  ) throws {
    try period.validate()
    let index = periods.firstIndex { $0.id == period.id }
    // Allow changes that leave a previously saved conflict as it was, including disabling it.
    let shouldCheckForOverlap =
      index.map { index in
        let saved = periods[index]
        return period.start != saved.start || period.end != saved.end
          || period.weekdays != saved.weekdays || (period.isEnabled && !saved.isEnabled)
      } ?? true
    if shouldCheckForOverlap,
      let conflict = periods.first(where: { $0.id != period.id && period.overlaps($0) })
    {
      throw DaywellError.overlappingPeriods(candidate: period, existing: conflict)
    }
    refresh(at: date, calendar: calendar)
    if shouldCheckForOverlap, period.isEnabled {
      let candidates = [
        period.occurrence(containing: date, calendar: calendar),
        period.nextOccurrence(after: date, calendar: calendar),
      ].compactMap { $0 }
      if let conflict = activeSessions(at: date).first(where: { existing in
        !existing.isMorning && existing.period.id != period.id
          && candidates.contains {
            $0.start < existing.occurrence.end && existing.occurrence.start < $0.end
          }
      }) {
        throw DaywellError.overlappingPeriods(candidate: period, existing: conflict.period)
      }
    }
    let running = activeSessions(at: date).filter { $0.period.id == period.id }
    if !period.isEnabled {
      let runningIDs = Set(running.map(\.id))
      guard runningIDs.isSubset(of: verifiedSessionIDs) else {
        throw DaywellError.deactivationVerificationRequired(sessionIDs: runningIDs)
      }
      // An accumulating morning has no active lock session yet. Cancel its source
      // snapshot too, so refresh and delayed threshold callbacks cannot recreate it.
      let endedSleepIDs = Set(
        running.map { $0.morningSourceID ?? $0.id }
          + pendingMornings(at: date).filter { $0.period.id == period.id }.map(\.id))
      sessions.removeAll { endedSleepIDs.contains($0.morningSourceID ?? $0.id) }
      morningWindows.removeAll { endedSleepIDs.contains($0.id) }
      if reservation?.grants.contains(where: { grant in
        !sessions.contains { $0.id == grant.sessionID }
      }) == true {
        reservation = nil
      }
    }
    var updated = period
    if !period.isEnabled || index.map({ !periods[$0].isEnabled }) == true {
      updated.effectiveAfter = nil
    } else if let activeEnd = running.filter({ !$0.isMorning }).map(\.occurrence.end).max() {
      updated.effectiveAfter = activeEnd
    }
    if let index {
      periods[index] = updated
    } else {
      periods.append(updated)
    }
    refresh(at: date, calendar: calendar)
  }

  public mutating func removePeriod(_ id: UUID, at date: Date, calendar: Calendar) {
    refresh(at: date, calendar: calendar)
    periods.removeAll { $0.id == id }
    prepareMornings(at: date, calendar: calendar)
  }

  public mutating func reserveExemption(at date: Date) throws -> ExemptionReservation {
    guard !hasFitnessRestriction(at: date) else { throw DaywellError.fitnessRestrictionActive }
    if let reservation, date < reservation.validUntil { throw DaywellError.reservationInProgress }
    let blocking = blockingSessions(at: date)
    guard !blocking.isEmpty else { throw DaywellError.noActivePeriod }
    guard blocking.allSatisfy({ $0.remainingCount > 0 }) else {
      throw DaywellError.allowanceExhausted
    }
    let pending = ExemptionReservation(
      id: UUID(), createdAt: date,
      grants: blocking.map {
        .init(
          sessionID: $0.id,
          end: min(
            $0.occurrence.end,
            Date(
              timeIntervalSince1970: ceil(
                date.timeIntervalSince1970 + Double($0.nextExemptionMinutes!) * 60))))
      })
    var preview = self
    preview.reservation = pending
    guard
      MonitorPlan.make(for: preview, at: date, calendar: .current).count
        <= MonitorPlan.activityLimit
    else {
      throw DaywellError.monitoringCapacityExceeded
    }
    reservation = pending
    return pending
  }

  public mutating func commitExemption(_ id: UUID, at date: Date) throws {
    guard !hasFitnessRestriction(at: date),
      let pending = reservation, pending.id == id, date >= pending.createdAt,
      date < pending.validUntil,
      Set(pending.grants.map(\.sessionID)) == Set(blockingSessions(at: date).map(\.id)),
      pending.grants.allSatisfy({ grant in
        guard let session = sessions.first(where: { $0.id == grant.sessionID }),
          let minutes = session.nextExemptionMinutes
        else { return false }
        // A reservation made before upgrading may still contain the old, independent duration.
        let latestEnd = min(
          session.occurrence.end,
          Date(
            timeIntervalSince1970: ceil(
              pending.createdAt.timeIntervalSince1970 + Double(minutes) * 60)))
        return grant.end > date && grant.end <= latestEnd
      }),
      blockingSessions(at: date).allSatisfy({ $0.remainingCount > 0 })
    else {
      throw DaywellError.staleReservation
    }
    for grant in pending.grants {
      guard let index = sessions.firstIndex(where: { $0.id == grant.sessionID }) else {
        throw DaywellError.staleReservation
      }
      sessions[index].usedCount += 1
      sessions[index].exemption = Exemption(requestID: id, start: pending.createdAt, end: grant.end)
    }
    synchronizeLinkedExemptionCounts()
    reservation = nil
  }

  mutating func synchronizeLinkedExemptionCounts() {
    // Keep per-session uses intact so old snapshots can be combined without double counting.
    for morning in sessions.indices {
      guard let sourceID = sessions[morning].morningSourceID,
        let sleep = sessions.firstIndex(where: { $0.id == sourceID })
      else { continue }
      sessions[morning].linkedUsedCount = max(
        sessions[morning].linkedUsedCount ?? 0, sessions[sleep].usedCount)
      sessions[sleep].linkedUsedCount = max(
        sessions[sleep].linkedUsedCount ?? 0, sessions[morning].usedCount)
    }
  }

  public mutating func cancelReservation(_ id: UUID) {
    if reservation?.id == id { reservation = nil }
  }

  public mutating func endExemptions(at date: Date) {
    reservation = nil
    for index in sessions.indices where sessions[index].occurrence.contains(date) {
      sessions[index].exemption = nil
    }
  }

  /// A missing report means the system has not loaded authorization in this process yet.
  public mutating func updateAuthorization(_ authorized: Bool?) {
    if authorized == true {
      hadAuthorization = true
    } else if authorized == false {
      markAuthorizationRevoked()
    }
  }

  public mutating func markAuthorizationRevoked() {
    guard hadAuthorization else { return }
    hadAuthorization = false
    needsApplicationReselection = true
    selectionData = nil
    alwaysAllowedApplicationsData = nil
    reservation = nil
    // Tokens are void after revocation. Keep counts but never reuse those opaque tokens.
  }

  public mutating func updateFitness(
    initial: FitnessTraining, _ update: (inout FitnessTraining) -> Void
  ) {
    var training = fitness ?? initial
    let previousCompletion = training.lastCompletedAt
    update(&training)
    fitness = training
    if let completed = training.lastCompletedAt, completed != previousCompletion {
      morningCancelledThrough = max(morningCancelledThrough ?? completed, completed)
      // This also handles a final group, which resets the visible count to zero.
      reconcileLockRules(at: completed)
    }
  }

  public mutating func replaceSelectionAfterAuthorization(_ data: Data?) {
    selectionData = data
    if needsApplicationReselection {
      // These snapshots hold invalidated tokens; retain their quotas with the replacement selection.
      sessions = sessions.map { session in
        LockSession(
          period: session.period, occurrence: session.occurrence,
          selectionData: data ?? Data(), policy: session.policy,
          usedCount: session.usedCount, linkedUsedCount: session.linkedUsedCount,
          exemption: session.exemption,
          morningSourceID: session.morningSourceID, cancelledAt: session.cancelledAt)
      }
      for index in morningWindows.indices { morningWindows[index].selectionData = data ?? Data() }
    }
    needsApplicationReselection = false
  }

  /// New selections apply now; removals wait for the next occurrence.
  /// The platform merges opaque selection data without exposing SDK types to the core.
  public mutating func updateSelection(
    _ data: Data?, at date: Date, merging merge: (Data, Data) throws -> Data
  ) rethrows {
    if needsApplicationReselection {
      replaceSelectionAfterAuthorization(data)
      return
    }
    var updatedSessions = sessions
    var updatedMornings = morningWindows
    if let data {
      for index in updatedSessions.indices
      where updatedSessions[index].cancelledAt == nil
        && updatedSessions[index].occurrence.contains(date)
      {
        updatedSessions[index].selectionData = try merge(updatedSessions[index].selectionData, data)
      }
      // Once usage accumulation starts, changing the event would reset its counter.
      for index in updatedMornings.indices
      where updatedMornings[index].cancelledAt == nil && updatedMornings[index].sleep.contains(date)
      {
        updatedMornings[index].selectionData = try merge(updatedMornings[index].selectionData, data)
      }
    }
    selectionData = data
    sessions = updatedSessions
    morningWindows = updatedMornings
  }

  public func validate() throws {
    guard schemaVersion == 2 else { throw DaywellError.unsupportedSchema }
    guard (1...49).contains(sleepShieldStoreCount) else { throw DaywellError.invalidState }
    try fitness?.validate()
    guard Set(periods.map(\.id)).count == periods.count,
      Set(sessions.map(\.id)).count == sessions.count,
      Set(morningWindows.map(\.id)).count == morningWindows.count
    else { throw DaywellError.invalidState }
    for period in periods { try period.validate() }
    for window in morningWindows {
      try window.period.validate()
      guard window.period.morningEnabled, window.sleep.periodID == window.period.id,
        window.sleep.start < window.sleep.end, window.start < window.end
      else { throw DaywellError.invalidState }
    }
    for session in sessions {
      try session.period.validate()
      guard session.occurrence.periodID == session.period.id,
        session.occurrence.start < session.occurrence.end,
        session.usedCount >= 0, session.usedCount <= session.policy.allowedCount,
        (session.linkedUsedCount ?? 0) >= 0
      else {
        throw DaywellError.invalidState
      }
      if let exemption = session.exemption {
        guard exemption.start >= session.occurrence.start, exemption.end <= session.occurrence.end,
          exemption.start < exemption.end
        else { throw DaywellError.invalidState }
      }
      if let sourceID = session.morningSourceID {
        guard
          morningWindows.contains(where: {
            $0.id == sourceID && $0.period.id == session.period.id
              && $0.contains(session.occurrence.start)
          })
        else { throw DaywellError.invalidState }
      }
    }
    if let reservation {
      guard !reservation.grants.isEmpty,
        Set(reservation.grants.map(\.sessionID)).count == reservation.grants.count,
        reservation.grants.allSatisfy({ grant in
          sessions.contains { $0.id == grant.sessionID && grant.end <= $0.occurrence.end }
            && grant.end > reservation.createdAt
        })
      else { throw DaywellError.invalidState }
    }
  }
}
