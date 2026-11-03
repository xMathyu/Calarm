//
//  CalarmWidgetsBundle.swift
//  CalarmWidgets
//
//  Widget extension bundle:
//  - the AlarmKit Live Activity, which renders the snooze / pre-alert countdown on
//    the Lock Screen and in the Dynamic Island (without it, posponing an alarm
//    showed no "rings again in…" timer);
//  - the Cuenta regresiva and Próxima alarma widgets, which read the
//    `WidgetSnapshot` the app writes into the App Group;
//  - the «Nueva alarma» control for Control Center.
//

import SwiftUI
import WidgetKit

@main
struct CalarmWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CalarmAlarmLiveActivity()
        CountdownWidget()
        NextAlarmWidget()
        NewAlarmControl()
    }
}
