//
//  CalarmAlarmLiveActivity.swift
//  CalarmWidgets
//
//  AlarmKit Live Activity. AlarmKit drives the activity's lifecycle and content
//  state (`AlarmPresentationState`); this widget just draws it. The key job is the
//  COUNTDOWN: when the user taps "Posponer", AlarmKit puts the alarm into a
//  `.countdown` state and we show a live "rings again in mm:ss" timer here.
//

import ActivityKit
import AlarmKit
import AppIntents
import SwiftUI
import WidgetKit

struct CalarmAlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<CalarmAlarmMetadata>.self) { context in
            // Lock Screen / banner presentation.
            LockScreenView(context: context)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(title(context)).lineLimit(1)
                    } icon: {
                        Image(systemName: symbol(context))
                    }
                    .font(.headline)
                    .foregroundStyle(context.attributes.tintColor)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StatusView(context: context)
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(context.attributes.tintColor)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(subtitle(context))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        StopButton(context: context, compact: true)
                    }
                }
            } compactLeading: {
                Image(systemName: symbol(context))
                    .foregroundStyle(context.attributes.tintColor)
            } compactTrailing: {
                StatusView(context: context)
                    .monospacedDigit()
                    .foregroundStyle(context.attributes.tintColor)
                    .frame(maxWidth: 64)
            } minimal: {
                Image(systemName: symbol(context))
                    .foregroundStyle(context.attributes.tintColor)
            }
            .keylineTint(context.attributes.tintColor)
        }
    }

    private func title(_ context: ActivityViewContext<AlarmAttributes<CalarmAlarmMetadata>>) -> String {
        let t = context.attributes.metadata?.title ?? ""
        return t.isEmpty ? "Alarma" : t
    }

    private func symbol(_ context: ActivityViewContext<AlarmAttributes<CalarmAlarmMetadata>>) -> String {
        let s = context.attributes.metadata?.symbolName ?? ""
        return s.isEmpty ? "alarm.fill" : s
    }

    private func subtitle(_ context: ActivityViewContext<AlarmAttributes<CalarmAlarmMetadata>>) -> String {
        switch context.state.mode {
        case .countdown: return "Suena de nuevo en…"
        case .paused: return "En pausa"
        case .alert: return "Sonando ahora"
        }
    }
}

/// The Lock Screen / banner layout: icon + title on the left, the live countdown
/// (or paused remaining) on the right.
private struct LockScreenView: View {
    let context: ActivityViewContext<AlarmAttributes<CalarmAlarmMetadata>>

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(context.attributes.tintColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                StatusView(context: context)
                    .font(.title.weight(.semibold).monospacedDigit())
                    .foregroundStyle(context.attributes.tintColor)
            }

            StopButton(context: context, compact: false)
        }
    }

    private var title: String {
        let t = context.attributes.metadata?.title ?? ""
        return t.isEmpty ? "Alarma" : t
    }

    private var symbol: String {
        let s = context.attributes.metadata?.symbolName ?? ""
        return s.isEmpty ? "alarm.fill" : s
    }

    private var label: String {
        switch context.state.mode {
        case .countdown: return "Suena de nuevo en"
        case .paused: return "En pausa"
        case .alert: return "Sonando ahora"
        }
    }
}

/// Stops the alarm from the Live Activity itself — without it the user has no way
/// to cancel a snoozed countdown short of waiting for it to ring again. The
/// `LiveActivityIntent` (shared source file, compiled into both targets) runs in
/// the app's process, where AlarmKit authorization lives.
private struct StopButton: View {
    let context: ActivityViewContext<AlarmAttributes<CalarmAlarmMetadata>>
    /// Compact = capsule sized for the Dynamic Island bottom region.
    let compact: Bool

    var body: some View {
        Button(intent: StopAlarmIntent(alarmID: context.state.alarmID.uuidString)) {
            Label("Detener", systemImage: "xmark")
                .font(compact ? .caption.weight(.semibold) : .headline)
                .frame(maxWidth: compact ? nil : .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(context.attributes.tintColor)
        .foregroundStyle(.white)
    }
}

/// Renders the current timing for whatever mode the alarm is in. The countdown
/// case uses `Text(timerInterval:)` so it ticks live without timeline reloads.
private struct StatusView: View {
    let context: ActivityViewContext<AlarmAttributes<CalarmAlarmMetadata>>

    var body: some View {
        switch context.state.mode {
        case .countdown(let countdown):
            Text(timerInterval: countdown.startDate...countdown.fireDate, countsDown: true)
                .multilineTextAlignment(.trailing)
        case .paused(let paused):
            let remaining = max(0, paused.totalCountdownDuration - paused.previouslyElapsedDuration)
            Text(Duration.seconds(remaining).formatted(.time(pattern: .minuteSecond)))
        case .alert:
            Image(systemName: "bell.and.waves.left.and.right.fill")
                .symbolRenderingMode(.hierarchical)
        }
    }
}
