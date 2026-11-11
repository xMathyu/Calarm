//
//  CountdownEvent.swift
//  Calarm
//
//  Una fecha que se espera (un concierto, un viaje, un cumpleaños) y los días
//  que faltan para ella. No suena: solo cuenta. Compatible con CloudKit como
//  `Reminder`: cada propiedad guardada tiene valor por defecto.
//
//  OJO: es un tipo nuevo de SwiftData (`CD_CountdownEvent`), así que hay que
//  desplegar el esquema a Production en el panel de CloudKit antes de publicar.
//

import Foundation
import SwiftData
import SwiftUI

@Model
final class CountdownEvent {
    var id: UUID = UUID()
    var title: String = ""
    var notes: String? = nil
    /// El día del evento; también la hora cuando `includesTime`.
    var date: Date = Date()
    /// Sin hora, la cuenta llega al inicio del día. Con hora, el detalle cuenta
    /// hasta el minuto exacto.
    var includesTime: Bool = false
    /// Vuelve cada año (cumpleaños, aniversario): cuenta siempre hasta el
    /// próximo y nunca pasa a «Pasados».
    var repeatsYearly: Bool = false
    var colorHex: String = CountdownEvent.defaultColorHex
    var iconKindRaw: Int = ReminderIconKind.emoji.rawValue
    /// Nombre de SF Symbol o emoji, según `iconKind`.
    var iconValue: String = CountdownEvent.defaultEmoji
    /// Ya reducida al guardar (`CountdownPhoto.prepared`): es el fondo de la tarjeta.
    @Attribute(.externalStorage) var photoData: Data? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Llegó por una invitación: es la copia de solo lectura de la cuenta de
    /// otra persona, que se actualiza con cada escaneo de la base compartida.
    /// OJO: columna nueva de SwiftData (`CD_isReceivedShare` en
    /// `CD_CountdownEvent`): hay que desplegar el esquema antes de publicar.
    var isReceivedShare: Bool = false

    static let defaultColorHex = "#FF2D55"
    static let defaultEmoji = "🎉"

    init(
        id: UUID = UUID(),
        title: String = "",
        notes: String? = nil,
        date: Date = Date(),
        includesTime: Bool = false,
        repeatsYearly: Bool = false,
        colorHex: String = CountdownEvent.defaultColorHex,
        iconKind: ReminderIconKind = .emoji,
        iconValue: String = CountdownEvent.defaultEmoji,
        photoData: Data? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.date = date
        self.includesTime = includesTime
        self.repeatsYearly = repeatsYearly
        self.colorHex = colorHex
        self.iconKindRaw = iconKind.rawValue
        self.iconValue = iconValue
        self.photoData = photoData
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
    }

    var iconKind: ReminderIconKind {
        get { ReminderIconKind(rawValue: iconKindRaw) ?? .emoji }
        set { iconKindRaw = newValue.rawValue }
    }

    var color: Color { Color(hex: colorHex) ?? .pink }

    /// La ocurrencia hacia la que se cuenta ahora mismo.
    func target(now: Date = Date(), calendar: Calendar = .current) -> Date {
        CountdownMath.target(
            date: date,
            includesTime: includesTime,
            repeatsYearly: repeatsYearly,
            now: now,
            calendar: calendar
        )
    }

    func status(now: Date = Date(), calendar: Calendar = .current) -> CountdownStatus {
        CountdownMath.status(to: target(now: now, calendar: calendar), now: now, calendar: calendar)
    }
}
