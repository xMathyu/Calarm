//
//  RecurrencePickerView.swift
//  Calarm
//

import SwiftUI

struct RecurrencePickerView: View {
    @Binding var rule: RecurrenceRule
    let baseDate: Date

    @State private var kind: Kind
    @State private var interval: Int
    @State private var weekdays: Set<Weekday>

    enum Kind: String, CaseIterable, Identifiable {
        case once = "Una vez"
        case daily = "Diaria"
        case weekly = "Semanal"
        case monthly = "Mensual"
        case yearly = "Anual"
        var id: String { rawValue }
    }

    init(rule: Binding<RecurrenceRule>, baseDate: Date) {
        self._rule = rule
        self.baseDate = baseDate
        switch rule.wrappedValue {
        case .once:
            _kind = State(initialValue: .once)
            _interval = State(initialValue: 1)
            _weekdays = State(initialValue: [])
        case .daily(let n):
            _kind = State(initialValue: .daily)
            _interval = State(initialValue: n)
            _weekdays = State(initialValue: [])
        case .weekly(let n, let days):
            _kind = State(initialValue: .weekly)
            _interval = State(initialValue: n)
            _weekdays = State(initialValue: days)
        case .monthly(let n):
            _kind = State(initialValue: .monthly)
            _interval = State(initialValue: n)
            _weekdays = State(initialValue: [])
        case .yearly(let n):
            _kind = State(initialValue: .yearly)
            _interval = State(initialValue: n)
            _weekdays = State(initialValue: [])
        }
    }

    var body: some View {
        Form {
            Section("Frecuencia") {
                Picker("Tipo", selection: $kind) {
                    ForEach(Kind.allCases) { k in
                        Text(k.rawValue).tag(k)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            if kind != .once {
                Section("Cada") {
                    Stepper(value: $interval, in: 1...30) {
                        Text("\(interval) \(unitLabel(plural: interval != 1))")
                    }
                }
            }

            if kind == .weekly {
                Section("Días") {
                    weekdayChips
                }
            }

            Section("Próximas ocurrencias") {
                let preview = RecurrenceEngine.nextOccurrences(rule: currentRule, baseDate: baseDate, count: 3)
                if preview.isEmpty {
                    Text("Sin ocurrencias futuras")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(preview, id: \.self) { date in
                        Text(date, format: .dateTime.day().month(.wide).year().hour().minute())
                            .font(.subheadline)
                    }
                }
            }
        }
        .navigationTitle("Repetir")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: kind) { _, _ in rule = currentRule }
        .onChange(of: interval) { _, _ in rule = currentRule }
        .onChange(of: weekdays) { _, _ in rule = currentRule }
    }

    private var currentRule: RecurrenceRule {
        switch kind {
        case .once: .once
        case .daily: .daily(interval: interval)
        case .weekly: .weekly(interval: interval, weekdays: weekdays)
        case .monthly: .monthly(interval: interval)
        case .yearly: .yearly(interval: interval)
        }
    }

    private func unitLabel(plural: Bool) -> String {
        switch kind {
        case .daily: plural ? "días" : "día"
        case .weekly: plural ? "semanas" : "semana"
        case .monthly: plural ? "meses" : "mes"
        case .yearly: plural ? "años" : "año"
        case .once: ""
        }
    }

    private var weekdayChips: some View {
        HStack(spacing: 6) {
            ForEach(Weekday.allCases) { day in
                let isOn = weekdays.contains(day)
                Button {
                    withAnimation(DS.Motion.snappy) {
                        if isOn { weekdays.remove(day) } else { weekdays.insert(day) }
                    }
                    Haptics.selection()
                } label: {
                    Text(day.localizedShort)
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(isOn ? Color.accentColor : Color.dsFill)
                        )
                        .foregroundStyle(isOn ? .white : .primary)
                        .scaleEffect(isOn ? 1.05 : 1.0)
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.selection, trigger: isOn)
            }
        }
    }
}
