//
//  CalarmSchema.swift
//  Calarm
//

import SwiftData

enum CalarmSchema {
    /// Todos los modelos de la base, en un solo sitio. La app y los intents de
    /// Siri (que abren su propio contenedor) tienen que usar esta misma lista:
    /// abrir la base con un esquema más corto la migraría a ese esquema, y lo
    /// que falte (p. ej. las cuentas regresivas) podría perderse.
    static var schema: Schema {
        Schema([Reminder.self, CustomCategory.self, CountdownEvent.self])
    }
}
