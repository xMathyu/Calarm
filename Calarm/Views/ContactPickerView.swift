//
//  ContactPickerView.swift
//  Calarm
//

import Contacts
import SwiftUI

/// Sendable-safe struct with the data extracted from a CNContact.
struct SelectedContact: Identifiable, Sendable {
    let id: String
    let name: String
    let phoneNumbers: [String]

    var displayPhone: String { phoneNumbers.first ?? "" }
}

/// Full SwiftUI contact picker with search, permission request, and multi-select.
struct ContactPickerView: View {
    @Environment(\.dismiss) private var dismiss
    var onSelect: ([SelectedContact]) -> Void

    @State private var allContacts: [SelectedContact] = []
    @State private var selectedIDs: Set<String> = []
    @State private var searchText = ""
    @State private var authStatus = CNContactStore.authorizationStatus(for: .contacts)
    @State private var isLoading = false

    private var filtered: [SelectedContact] {
        guard !searchText.isEmpty else { return allContacts }
        let q = searchText.lowercased()
        return allContacts.filter {
            $0.name.lowercased().contains(q) || $0.displayPhone.contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch authStatus {
                case .authorized, .limited:
                    contactList
                case .denied, .restricted:
                    deniedView
                default:
                    requestView
                }
            }
            .navigationTitle("Invitar amigos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Listo") {
                        let result = allContacts.filter { selectedIDs.contains($0.id) }
                        onSelect(result)
                        dismiss()
                    }
                    .bold()
                    .disabled(selectedIDs.isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private var contactList: some View {
        if isLoading {
            ProgressView("Cargando contactos…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List(filtered) { contact in
                Button {
                    if selectedIDs.contains(contact.id) {
                        selectedIDs.remove(contact.id)
                    } else {
                        selectedIDs.insert(contact.id)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(contact.name)
                                .foregroundStyle(.primary)
                            if !contact.displayPhone.isEmpty {
                                Text(contact.displayPhone)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if selectedIDs.contains(contact.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Buscar contacto")
        }
    }

    private var requestView: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 60))
                .foregroundStyle(.blue)
            Text("Acceso a Contactos")
                .font(.title2.bold())
            Text("Para poder invitar amigos, Calarm necesita acceder a tus contactos.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Permitir acceso") {
                Task { await requestAccess() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.xmark")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("Permiso denegado")
                .font(.title2.bold())
            Text("Ve a Ajustes → Calarm → Contactos y activa el acceso.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Abrir Ajustes") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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
            CNContactPhoneNumbersKey as CNKeyDescriptor
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
                contacts.append(SelectedContact(
                    id: c.identifier,
                    name: name.isEmpty ? c.phoneNumbers.first?.value.stringValue ?? "" : name,
                    phoneNumbers: c.phoneNumbers.map { $0.value.stringValue }
                ))
            }
            return contacts
        }.value

        allContacts = result
        isLoading = false
    }
}

extension ContactPickerView {
    /// Convenience initializer that auto-loads contacts when the status is already authorized.
    init(onSelect: @escaping ([SelectedContact]) -> Void) {
        self.onSelect = onSelect
        let status = CNContactStore.authorizationStatus(for: .contacts)
        _authStatus = State(initialValue: status)
        if status == .authorized || status == .limited {
            _isLoading = State(initialValue: true)
        }
    }
}
