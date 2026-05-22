//
//  ContactPickerView.swift
//  Calarm
//

import Contacts
import SwiftUI

/// Sendable-safe struct with the data extracted from a CNContact.
struct SelectedContact: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let phoneNumbers: [String]
    let imageData: Data?

    var displayPhone: String { phoneNumbers.first ?? "" }
}

/// Polished SwiftUI contact picker.
/// - Selected contacts shown as horizontally-scrollable chips at the top.
/// - Alphabetical sections with sticky headers.
/// - Avatars (photo when available, otherwise colorful initials).
/// - Native haptics, spring animations, and modern empty/permission states.
struct ContactPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let preselected: [SelectedContact]
    let onSelect: ([SelectedContact]) -> Void

    @State private var allContacts: [SelectedContact] = []
    @State private var selectedIDs: [String]
    @State private var searchText = ""
    @State private var authStatus = CNContactStore.authorizationStatus(for: .contacts)
    @State private var isLoading = false
    /// Set to true when the user explicitly tapped a button that already
    /// handled the commit/discard decision. Prevents the auto-commit in
    /// `onDisappear` from firing twice or overriding an explicit cancel.
    @State private var didHandleDismissExplicitly = false

    init(preselected: [SelectedContact] = [], onSelect: @escaping ([SelectedContact]) -> Void) {
        self.preselected = preselected
        self.onSelect = onSelect
        // Seed synchronously so the very first render already reflects what's
        // selected — avoids a flash where preselected rows look unselected.
        _selectedIDs = State(initialValue: preselected.map(\.id))
    }

    private var selectedSet: Set<String> { Set(selectedIDs) }

    private var filtered: [SelectedContact] {
        guard !searchText.isEmpty else { return allContacts }
        let q = searchText.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        return allContacts.filter {
            $0.name.folding(options: .diacriticInsensitive, locale: .current).lowercased().contains(q)
            || $0.displayPhone.contains(searchText)
        }
    }

    private var sections: [(key: String, contacts: [SelectedContact])] {
        let grouped = Dictionary(grouping: filtered) { contact -> String in
            let first = contact.name.first.map { String($0).folding(options: .diacriticInsensitive, locale: .current).uppercased() }
            if let f = first, f.range(of: "[A-Z]", options: .regularExpression) != nil {
                return f
            }
            return "#"
        }
        return grouped.sorted { lhs, rhs in
            if lhs.key == "#" { return false }
            if rhs.key == "#" { return true }
            return lhs.key < rhs.key
        }.map { ($0.key, $0.value) }
    }

    private var selectedContacts: [SelectedContact] {
        // Start with preselected as fallback so chips render immediately even
        // before `allContacts` finishes loading, then override with the fresh
        // data from `allContacts` once available.
        var map: [String: SelectedContact] = Dictionary(uniqueKeysWithValues: preselected.map { ($0.id, $0) })
        let selectedSet = self.selectedSet
        for c in allContacts where selectedSet.contains(c.id) {
            map[c.id] = c
        }
        return selectedIDs.compactMap { map[$0] }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch authStatus {
                case .authorized, .limited:
                    mainContent
                case .denied, .restricted:
                    deniedView
                default:
                    requestView
                }
            }
            .navigationTitle(navigationTitleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") {
                        didHandleDismissExplicitly = true
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Listo") {
                        didHandleDismissExplicitly = true
                        onSelect(selectedContacts)
                        dismiss()
                    }
                    .bold()
                }
            }
            .task {
                let status = CNContactStore.authorizationStatus(for: .contacts)
                if (status == .authorized || status == .limited) && allContacts.isEmpty {
                    await loadContacts()
                }
            }
            .onDisappear {
                // Swipe-down or any other interactive dismissal commits the
                // current selection — matches the intuitive iOS pattern.
                guard !didHandleDismissExplicitly else { return }
                onSelect(selectedContacts)
            }
        }
    }

    private var navigationTitleText: String {
        selectedIDs.isEmpty
            ? "Invitar amigos"
            : "\(selectedIDs.count) seleccionado\(selectedIDs.count == 1 ? "" : "s")"
    }

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            if !selectedIDs.isEmpty {
                selectedChips
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if isLoading {
                loadingView
            } else {
                contactList
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedIDs)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar por nombre o teléfono")
    }

    // MARK: - Selected chips strip

    private var selectedChips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(selectedContacts) { contact in
                        SelectedContactChip(contact: contact) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                selectedIDs.removeAll { $0 == contact.id }
                            }
                            Haptics.light()
                        }
                        .id(contact.id)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.secondarySystemGroupedBackground))
            .overlay(alignment: .bottom) {
                Divider()
            }
            .onChange(of: selectedIDs) { _, newValue in
                if let last = newValue.last {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(last, anchor: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Contact list

    @ViewBuilder
    private var contactList: some View {
        if filtered.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                ForEach(sections, id: \.key) { section in
                    Section {
                        ForEach(section.contacts) { contact in
                            contactRow(for: contact)
                        }
                    } header: {
                        Text(section.key)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.interactively)
            .sensoryFeedback(.selection, trigger: selectedIDs.count)
        }
    }

    private func contactRow(for contact: SelectedContact) -> some View {
        let isSelected = selectedSet.contains(contact.id)
        return Button {
            toggle(contact)
        } label: {
            HStack(spacing: 12) {
                ContactAvatarView(name: contact.name, imageData: contact.imageData, size: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if !contact.displayPhone.isEmpty {
                        Text(contact.displayPhone)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? Color.accentColor : Color(.systemGray3), lineWidth: 1.5)
                        .frame(width: 24, height: 24)
                    if isSelected {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 24, height: 24)
                            .transition(.scale.combined(with: .opacity))
                        Image(systemName: "checkmark")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isSelected ? Color.accentColor.opacity(0.08) : Color.clear
        )
    }

    private func toggle(_ contact: SelectedContact) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if selectedSet.contains(contact.id) {
                selectedIDs.removeAll { $0 == contact.id }
            } else {
                selectedIDs.append(contact.id)
            }
        }
    }

    // MARK: - Loading / permission states

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Cargando contactos…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var requestView: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.25), Color.accentColor.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)
                Image(systemName: "person.2.fill")
                    .font(.system(size: 50, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.bounce, options: .nonRepeating)
            }
            VStack(spacing: 8) {
                Text("Acceso a Contactos")
                    .font(.title2.bold())
                Text("Para invitar amigos a tus eventos, Calarm necesita acceder a tus contactos.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
            }
            Button {
                Task { await requestAccess() }
            } label: {
                Text("Permitir acceso")
                    .frame(maxWidth: 280)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deniedView: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 120, height: 120)
                Image(systemName: "person.crop.circle.badge.xmark")
                    .font(.system(size: 50, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                Text("Permiso denegado")
                    .font(.title2.bold())
                Text("Ve a Ajustes → Calarm → Contactos y activa el acceso para invitar amigos.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
            }
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Abrir Ajustes")
                    .frame(maxWidth: 280)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private func requestAccess() async {
        let store = CNContactStore()
        _ = try? await store.requestAccess(for: .contacts)
        authStatus = CNContactStore.authorizationStatus(for: .contacts)
        if authStatus == .authorized || authStatus == .limited {
            await loadContacts()
        }
    }

    private func loadContacts() async {
        isLoading = true
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .givenName

        let result: [SelectedContact] = await Task.detached(priority: .userInitiated) {
            var contacts: [SelectedContact] = []
            let store = CNContactStore()
            try? store.enumerateContacts(with: request) { c, _ in
                guard !c.phoneNumbers.isEmpty else { return }
                let name = [c.givenName, c.familyName]
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                let resolvedName = name.isEmpty ? (c.phoneNumbers.first?.value.stringValue ?? "") : name
                contacts.append(SelectedContact(
                    id: c.identifier,
                    name: resolvedName,
                    phoneNumbers: c.phoneNumbers.map { $0.value.stringValue },
                    imageData: c.thumbnailImageData
                ))
            }
            return contacts
        }.value

        allContacts = result
        isLoading = false
    }
}

// MARK: - Chip

private struct SelectedContactChip: View {
    let contact: SelectedContact
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ContactAvatarView(name: contact.name, imageData: contact.imageData, size: 56)
                Button(action: onRemove) {
                    ZStack {
                        Circle()
                            .fill(Color(.systemGray))
                            .frame(width: 22, height: 22)
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .overlay(
                        Circle()
                            .strokeBorder(Color(.systemBackground), lineWidth: 2)
                    )
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .accessibilityLabel("Quitar \(contact.name)")
            }
            Text(firstName)
                .font(.caption2)
                .lineLimit(1)
                .frame(maxWidth: 64)
                .foregroundStyle(.primary)
        }
    }

    private var firstName: String {
        contact.name.split(separator: " ").first.map(String.init) ?? contact.name
    }
}

#Preview {
    ContactPickerView { _ in }
}
