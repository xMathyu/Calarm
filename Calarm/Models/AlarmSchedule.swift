//
//  AlarmSchedule.swift
//  Calarm
//
//  One (date+time, recurrence) schedule within an alarm. A `Reminder` has a
//  primary schedule (its `date` / `recurrence`) plus zero or more additional ones
//  (`Reminder.additionalSchedules`), so a SINGLE alarm can fire on different days
//  and times — e.g. Judo on Mon+Fri 5pm AND Sat 11am — without needing separate
//  alarms. Encoded as JSON inside `Reminder.additionalSchedulesData` and carried
//  in the share payload, so it's additive (no CloudKit schema change).
//

import Foundation

struct AlarmSchedule: Codable, Identifiable, Hashable {
    var id: UUID
    var date: Date
    /// Encoded `RecurrenceRule` (JSON), mirroring `Reminder.recurrenceData` so a
    /// future rule-shape change can't break decoding of the rest.
    var recurrenceData: Data

    init(id: UUID = UUID(), date: Date, recurrence: RecurrenceRule = .once) {
        self.id = id
        self.date = date
        self.recurrenceData = (try? JSONEncoder().encode(recurrence)) ?? Data()
    }

    var recurrence: RecurrenceRule {
        get { (try? JSONDecoder().decode(RecurrenceRule.self, from: recurrenceData)) ?? .once }
        set { recurrenceData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}
