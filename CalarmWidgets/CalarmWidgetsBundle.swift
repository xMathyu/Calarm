//
//  CalarmWidgetsBundle.swift
//  CalarmWidgets
//
//  Widget extension bundle. Its only member is the AlarmKit Live Activity, which
//  renders the snooze / pre-alert countdown on the Lock Screen and in the Dynamic
//  Island. Without this extension the system has nowhere to draw the countdown, so
//  posponing an alarm showed no "rings again in…" timer.
//

import SwiftUI
import WidgetKit

@main
struct CalarmWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CalarmAlarmLiveActivity()
    }
}
