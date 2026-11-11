//
//  PlusStore.swift
//  Calarm
//
//  Calarmi Plus: la compra opcional (suscripción anual o pago único de por
//  vida) que desbloquea los extras. Lo esencial de una alarma —que suene, se
//  repita, se comparta— no pasa nunca por aquí.
//
//  Dos reglas:
//  - Plus solo bloquea ELEGIR algo nuevo. Lo que ya está configurado sigue
//    funcionando sin Plus: una alarma con un reto Arcade suena y pide su reto,
//    un tono importado sigue sonando, y las cuentas regresivas que ya existen no
//    se tocan. Así quien usaba estos extras antes de Plus no pierde nada, y una
//    alarma compartida por alguien con Plus funciona igual en tu teléfono.
//  - Nada de esto corre al sonar una alarma. Si la App Store no contesta, lo
//    único que se pierde es poder elegir un extra nuevo.
//

import Foundation
import Observation
import StoreKit
import SwiftUI

/// Lo que desbloquea Calarmi Plus, en el orden en que lo enseña el paywall.
enum PlusFeature: String, CaseIterable, Identifiable {
    case arcadeChallenges
    case customTones
    case unlimitedCountdowns
    case appIcons

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .arcadeChallenges: appLocalized("Retos Arcade")
        case .customTones: appLocalized("Tus propios tonos")
        case .unlimitedCountdowns: appLocalized("Cuentas regresivas sin límite")
        case .appIcons: appLocalized("Íconos de colores")
        }
    }

    var localizedDescription: String {
        switch self {
        case .arcadeChallenges:
            appLocalized("Vuelo, Ovejas, Cañón y Tirachinas: juegos para apagar la alarma ya bien despierto.")
        case .customTones:
            appLocalized("Importa cualquier audio desde Archivos y despierta con él.")
        case .unlimitedCountdowns:
            appLocalized("Sin Plus puedes tener hasta \(PlusStore.freeCountdownLimit) cuentas regresivas propias.")
        case .appIcons:
            appLocalized("Cambia el color del ícono en tu pantalla de inicio.")
        }
    }

    var systemImage: String {
        switch self {
        case .arcadeChallenges: "gamecontroller.fill"
        case .customTones: "waveform"
        case .unlimitedCountdowns: "hourglass"
        case .appIcons: "paintpalette.fill"
        }
    }
}

extension WakeChallenge.Kind {
    /// Los retos que hace falta Plus para ELEGIR. Uno ya elegido sigue sonando.
    var requiresPlus: Bool { group == .arcade }
}

@MainActor
@Observable
final class PlusStore {
    static let shared = PlusStore()

    /// Cuántas cuentas regresivas PROPIAS se pueden tener sin Plus. Las que otra
    /// persona comparte contigo no cuentan: aceptar una invitación nunca se
    /// bloquea, porque es justo como Calarmi llega a gente nueva.
    nonisolated static let freeCountdownLimit = 3

    /// Los productos de App Store Connect. Si se cambian aquí hay que cambiarlos
    /// también en `Calarm.storekit` (pruebas locales) y en la tienda.
    enum ProductID {
        static let yearly = "MathyuSolutions.Calarm.plus.yearly"
        static let lifetime = "MathyuSolutions.Calarm.plus.lifetime"
        static let all: Set<String> = [yearly, lifetime]
    }

    enum LoadState: Equatable {
        case idle, loading, loaded, failed
    }

    enum PurchaseOutcome {
        case purchased, pending, cancelled
    }

    /// Si hay Plus. Arranca con lo último que se supo, para que los candados no
    /// parpadeen mientras StoreKit contesta; `refreshEntitlements` lo corrige.
    private(set) var isPlus: Bool
    /// El producto que da Plus ahora mismo, si hay uno.
    private(set) var activeProductID: String?
    private(set) var yearly: Product?
    private(set) var lifetime: Product?
    private(set) var loadState: LoadState = .idle
    /// Si la prueba gratis de la suscripción anual está disponible para esta
    /// cuenta de Apple (solo se puede usar una vez).
    private(set) var isEligibleForTrial = true

    var hasLifetime: Bool { activeProductID == ProductID.lifetime }

    private var updatesTask: Task<Void, Never>?
    private static let cacheKey = "plus.isActive"

    private init() {
        isPlus = UserDefaults.standard.bool(forKey: Self.cacheKey) || Self.debugUnlocked
    }

    /// Una vez por arranque: escucha las compras que llegan por fuera de la app
    /// (renovaciones, En familia, compras aprobadas más tarde, reembolsos) y
    /// lee el estado actual.
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task {
            for await result in StoreKit.Transaction.updates {
                await self.handle(result)
            }
        }
        Task {
            for await result in StoreKit.Transaction.unfinished {
                await handle(result)
            }
            await refreshEntitlements()
            await loadProducts()
        }
    }

    private func handle(_ result: VerificationResult<StoreKit.Transaction>) async {
        if case .verified(let transaction) = result {
            await transaction.finish()
        }
        await refreshEntitlements()
    }

    func loadProducts() async {
        guard loadState != .loading else { return }
        loadState = .loading
        do {
            let products = try await Product.products(for: ProductID.all)
            yearly = products.first { $0.id == ProductID.yearly }
            lifetime = products.first { $0.id == ProductID.lifetime }
            if let subscription = yearly?.subscription {
                isEligibleForTrial = await subscription.isEligibleForIntroOffer
            }
            loadState = (yearly == nil && lifetime == nil) ? .failed : .loaded
        } catch {
            loadState = .failed
        }
    }

    /// Vuelve a leer qué da Plus. Una suscripción que caducó deja de aparecer en
    /// `currentEntitlements`, así que basta con llamarla al volver a la app.
    func refreshEntitlements() async {
        var active: String?
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  ProductID.all.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            if let expiration = transaction.expirationDate, expiration < Date() { continue }
            active = transaction.productID
            if transaction.productID == ProductID.lifetime { break }
        }
        activeProductID = active
        isPlus = active != nil || Self.debugUnlocked
        UserDefaults.standard.set(active != nil, forKey: Self.cacheKey)
    }

    /// Compra con la acción de SwiftUI (`@Environment(\.purchase)`), que sabe en
    /// qué escena mostrar la hoja de pago.
    func purchase(_ product: Product, with action: PurchaseAction) async throws -> PurchaseOutcome {
        switch try await action(product) {
        case .success(let verification):
            let transaction = try verification.payloadValue
            await transaction.finish()
            await refreshEntitlements()
            return .purchased
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    /// «Restaurar compras»: obligatorio para la App Store, y lo que salva a quien
    /// estrena teléfono sin copia de seguridad.
    func restore() async throws {
        try await AppStore.sync()
        await refreshEntitlements()
    }

    func canCreateCountdown(ownCount: Int) -> Bool {
        isPlus || ownCount < Self.freeCountdownLimit
    }

    /// `-demoPlus` desbloquea Plus en Debug, para capturas y pruebas sin compra.
    private static var debugUnlocked: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-demoPlus")
        #else
        false
        #endif
    }
}

// MARK: - Piezas de interfaz compartidas

/// La etiqueta «Plus» junto a lo que hace falta Plus para elegir.
struct PlusBadge: View {
    var body: some View {
        Label {
            Text(verbatim: "Plus")
        } icon: {
            Image(systemName: "sparkles")
        }
        .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.gradient))
            .accessibilityLabel(Text("Requiere Calarmi Plus"))
    }
}

extension View {
    /// Abre el paywall marcando la función que llevó hasta él.
    func plusPaywall(for feature: Binding<PlusFeature?>) -> some View {
        sheet(item: feature) { feature in
            PlusPaywallView(highlight: feature)
        }
    }
}
