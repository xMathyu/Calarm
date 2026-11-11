//
//  NewAlarmControl.swift
//  CalarmWidgets
//
//  «Nueva alarma» para el Centro de control, la pantalla bloqueada o el botón
//  de Acción: abre Calarm con el editor de una alarma nueva.
//

import AppIntents
import SwiftUI
import WidgetKit

struct NewAlarmControl: ControlWidget {
    static let kind = "MathyuSolutions.Calarm.NewAlarmControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: NewAlarmControlIntent()) {
                Label("Nueva alarma", systemImage: "alarm.fill")
            }
        }
        .displayName("Nueva alarma")
        .description("Abre Calarmi para crear una alarma.")
    }
}
