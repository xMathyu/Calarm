//
//  LeadTimePickerSheet.swift
//  Calarm
//

import SwiftUI

/// Sheet that lets the user pick an `AlarmLeadTime` to add to a reminder or
/// meeting. Already-selected values can be hidden via `excluded`.
struct LeadTimePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let excluded: Set<AlarmLeadTime>
    let onSelect: (AlarmLeadTime) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(AlarmLeadTime.allCases.filter { !excluded.contains($0) }) { value in
                    Button {
                        onSelect(value)
                        Haptics.selection()
                        dismiss()
                    } label: {
                        Label(value.localizedTitle, systemImage: "bell")
                            .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Cuándo sonar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }
}
