//
//  PlusPaywallView.swift
//  Calarm
//
//  La pantalla de Calarmi Plus: qué incluye, los dos planes (anual con prueba
//  gratis y de por vida) y lo que la App Store exige en una compra: precio y
//  renovación a la vista, «Restaurar compras», términos y privacidad.
//

import StoreKit
import SwiftUI

struct PlusPaywallView: View {
    /// La función que llevó hasta aquí; se resalta en la lista.
    var highlight: PlusFeature?

    @State private var store = PlusStore.shared
    @State private var plan: Plan = .yearly
    @State private var isWorking = false
    @State private var message: Message?
    @State private var showingManage = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.purchase) private var purchase

    private enum Plan: Hashable {
        case yearly, lifetime
    }

    private struct Message {
        let title: String
        let body: String
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.xxl) {
                    header
                    featureList
                    if store.isPlus {
                        activeCard
                    } else {
                        planPicker
                    }
                }
                .padding(.horizontal, DS.Spacing.xl)
                .padding(.bottom, DS.Spacing.xxl)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                if !store.isPlus {
                    purchaseBar
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(Text("Cerrar"))
                }
            }
            .task {
                if store.loadState != .loaded {
                    await store.loadProducts()
                }
                // Si la suscripción no está a la venta, no se deja marcada.
                if store.yearly == nil, store.lifetime != nil {
                    plan = .lifetime
                }
            }
            .alert(
                message?.title ?? "",
                isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } }),
                presenting: message
            ) { _ in
                Button("Entendido", role: .cancel) {}
            } message: { message in
                Text(message.body)
            }
            .manageSubscriptionsSheet(isPresented: $showingManage)
        }
    }

    // MARK: - Cabecera y lista

    private var header: some View {
        VStack(spacing: DS.Spacing.md) {
            Image(AppIconOption.current.previewName)
                .resizable()
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                .accessibilityHidden(true)
            HStack(spacing: DS.Spacing.xs) {
                Text(verbatim: "Calarmi")
                Text(verbatim: "Plus")
                    .foregroundStyle(Color.accentColor.gradient)
            }
            .font(.largeTitle.weight(.bold))
            .accessibilityElement(children: .combine)
            Text("Lo esencial sigue siendo gratis. Plus suma extras y ayuda a que Calarmi siga mejorando.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            VStack(spacing: 0) {
                ForEach(PlusFeature.allCases) { feature in
                    featureRow(feature)
                }
            }
            .padding(DS.Spacing.xs)
            .background(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).fill(Color.dsCard))

            Text("Siempre gratis: alarmas, repeticiones, calendario, compartir, Siri y el asistente.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, DS.Spacing.xs)
        }
    }

    private func featureRow(_ feature: PlusFeature) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.md) {
            Image(systemName: feature.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous).fill(Color.accentColor.gradient))
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(feature.localizedTitle)
                    .font(.headline)
                Text(feature.localizedDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.md)
        .background {
            if feature == highlight {
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Planes

    @ViewBuilder
    private var planPicker: some View {
        switch store.loadState {
        case .loaded:
            VStack(spacing: DS.Spacing.md) {
                if let yearly = store.yearly {
                    planCard(
                        .yearly,
                        title: appLocalized("Anual"),
                        detail: appLocalized("Equivale a \((yearly.price / 12).formatted(yearly.priceFormatStyle)) al mes."),
                        badge: trialOffer(for: yearly).map(trialDescription),
                        price: yearly.displayPrice,
                        priceCaption: appLocalized("al año")
                    )
                }
                if let lifetime = store.lifetime {
                    planCard(
                        .lifetime,
                        title: appLocalized("De por vida"),
                        detail: appLocalized("Un solo pago, sin renovaciones."),
                        badge: nil,
                        price: lifetime.displayPrice,
                        priceCaption: appLocalized("una vez")
                    )
                }
            }
        case .failed:
            VStack(spacing: DS.Spacing.md) {
                Text("No se pudo conectar con la App Store.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Reintentar") {
                    Task { await store.loadProducts() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.lg)
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Spacing.xxl)
        }
    }

    private func planCard(
        _ value: Plan,
        title: String,
        detail: String,
        badge: String?,
        price: String,
        priceCaption: String
    ) -> some View {
        let isSelected = plan == value
        return Button {
            Haptics.selection()
            withAnimation(DS.Motion.snappy) { plan = value }
        } label: {
            HStack(spacing: DS.Spacing.md) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    HStack(spacing: DS.Spacing.xs) {
                        Text(title)
                            .font(.headline)
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.green))
                        }
                    }
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.Spacing.sm)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(price)
                        .font(.headline)
                        .monospacedDigit()
                    Text(priceCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(DS.Spacing.lg)
            .background(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).fill(Color.dsCard))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var activeCard: some View {
        VStack(spacing: DS.Spacing.md) {
            Label("Tienes Calarmi Plus", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(Color.accentColor)
            Group {
                if store.hasLifetime {
                    Text("Es tuyo para siempre. ¡Gracias por apoyar Calarmi!")
                } else {
                    Text("¡Gracias por apoyar Calarmi!")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            if store.activeProductID == PlusStore.ProductID.yearly {
                Button("Gestionar suscripción") {
                    showingManage = true
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(DS.Spacing.lg)
        .background(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).fill(Color.dsCard))
    }

    // MARK: - Compra

    private var purchaseBar: some View {
        VStack(spacing: DS.Spacing.sm) {
            Button(action: buy) {
                ZStack {
                    Text(callToAction)
                        .opacity(isWorking ? 0 : 1)
                    if isWorking {
                        ProgressView()
                            .tint(.white)
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Spacing.xs)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selectedProduct == nil || isWorking)

            if let legal = legalText {
                Text(legal)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: DS.Spacing.lg) {
                Button("Restaurar compras", action: restore)
                Link("Términos de uso", destination: AppLinks.terms)
                Link("Privacidad", destination: AppLinks.privacy)
            }
            .font(.caption.weight(.medium))
            .disabled(isWorking)
        }
        .padding(.horizontal, DS.Spacing.xl)
        .padding(.top, DS.Spacing.md)
        .padding(.bottom, DS.Spacing.xs)
        .background(.bar)
    }

    private var selectedProduct: Product? {
        plan == .yearly ? store.yearly : store.lifetime
    }

    private var callToAction: String {
        guard let product = selectedProduct else { return appLocalized("Continuar") }
        if plan == .yearly {
            return trialOffer(for: product) != nil
                ? appLocalized("Empezar la prueba gratis")
                : appLocalized("Suscribirme por \(product.displayPrice) al año")
        }
        return appLocalized("Comprar por \(product.displayPrice)")
    }

    /// Lo que la App Store pide mostrar junto al botón de una suscripción: qué
    /// se cobra, cada cuánto, que se renueva sola y cómo cancelarla.
    private var legalText: String? {
        guard let product = selectedProduct else { return nil }
        guard plan == .yearly else {
            return appLocalized("Pago único. Plus queda en todos tus dispositivos con la misma cuenta de Apple.")
        }
        let renewal = appLocalized("Se renueva sola cada año hasta que la canceles. Puedes cancelarla en Ajustes › tu nombre › Suscripciones, al menos 24 horas antes de la renovación.")
        if let offer = trialOffer(for: product) {
            return appLocalized("\(trialDescription(offer)), luego \(product.displayPrice) al año.") + " " + renewal
        }
        return appLocalized("\(product.displayPrice) al año.") + " " + renewal
    }

    /// La prueba gratis, si la suscripción la tiene y esta cuenta aún no la usó.
    private func trialOffer(for product: Product) -> Product.SubscriptionOffer? {
        guard store.isEligibleForTrial,
              let offer = product.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else { return nil }
        return offer
    }

    private func trialDescription(_ offer: Product.SubscriptionOffer) -> String {
        let period = offer.period
        switch period.unit {
        case .day: return appLocalized("\(period.value) días gratis")
        case .week: return appLocalized("\(period.value * 7) días gratis")
        case .month: return period.value == 1 ? appLocalized("1 mes gratis") : appLocalized("\(period.value) meses gratis")
        case .year: return appLocalized("1 año gratis")
        @unknown default: return appLocalized("Prueba gratis")
        }
    }

    private func buy() {
        guard let product = selectedProduct else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                switch try await store.purchase(product, with: purchase) {
                case .purchased:
                    Haptics.success()
                    dismiss()
                case .pending:
                    message = Message(
                        title: appLocalized("Compra pendiente"),
                        body: appLocalized("La compra necesita una aprobación, por ejemplo de quien organiza En familia. Plus se activará solo cuando se apruebe.")
                    )
                case .cancelled:
                    break
                }
            } catch {
                message = Message(title: appLocalized("No se pudo completar la compra"), body: error.localizedDescription)
            }
        }
    }

    private func restore() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await store.restore()
                if store.isPlus {
                    Haptics.success()
                    dismiss()
                } else {
                    message = Message(
                        title: appLocalized("No hay compras que restaurar"),
                        body: appLocalized("Esta cuenta de Apple no tiene Calarmi Plus. Si lo compraste con otra, inicia sesión con ella en Ajustes › tu nombre.")
                    )
                }
            } catch StoreKitError.userCancelled {
                // Cerró el inicio de sesión de la App Store: no hay nada que decir.
            } catch {
                message = Message(title: appLocalized("No se pudo restaurar"), body: error.localizedDescription)
            }
        }
    }
}
