//
//  CalarmAlarmMetadata.swift
//  Calarm
//
//  Static metadata travelling with each AlarmKit alarm.
//
//  SHARED between the app target (which schedules alarms) and the widget extension
//  (which renders the Live Activity / countdown). ActivityKit identifies a Live
//  Activity by its attributes type — `AlarmAttributes<CalarmAlarmMetadata>` — so
//  this struct must be compiled into BOTH targets as the same-named, same-shaped
//  type. Keep it dependency-free (Foundation + AlarmKit only) so the widget target
//  stays lean; app-only conveniences live in an extension in AlarmScheduler.swift.
//

import AlarmKit
import Foundation

struct CalarmAlarmMetadata: AlarmMetadata {
    let ownerID: String
    let title: String
    let symbolName: String
    let categoryRaw: Int
    /// Join link of the meeting (Teams, Zoom or Google Meet). The stored key keeps
    /// its legacy `teamsURLString` name so metadata of already-scheduled alarms
    /// still decodes.
    let teamsURLString: String?
    let location: String?

    var meetingURL: URL? {
        guard let s = teamsURLString, !s.isEmpty else { return nil }
        return URL(string: s)
    }
}
