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
            // Lock Screen / banner presentation — and, in the `.small` family, the
            // Apple Watch Smart Stack.
            LockScreenView(context: context)
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
                        StopButton(context: context, size: 32)
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
        // The Apple Watch mirrors iPhone Live Activities into the Smart Stack. Without
        // declaring `.small` the watch gets the iPhone layout squeezed into a strip
        // where the alarm's name is the first thing to be dropped — which is how a
        // ringing alarm ends up looking like a generic "Calarm" card on the wrist.
        .supplementalActivityFamilies([.small])
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
    /// `.small` is the Apple Watch Smart Stack; `.medium` the iPhone/iPad.
    @Environment(\.activityFamily) private var family

    var body: some View {
        switch family {
        case .small: watchBody
        default: phoneBody.padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    /// Apple Watch: the name of the alarm comes FIRST and gets the room it needs —
    /// on the wrist that's the only thing that tells one alarm from another.
    private var watchBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(context.attributes.tintColor)
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                StatusView(context: context)
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(context.attributes.tintColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var phoneBody: some View {
        HStack(spacing: 12) {
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
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(context.attributes.tintColor)

            // Cancel sits at the trailing edge as a round X — no full-width bar.
            StopButton(context: context, size: 40)
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
    /// Diameter of the circle — smaller inside the Dynamic Island.
    let size: CGFloat

    var body: some View {
        Button(intent: StopAlarmIntent(alarmID: context.state.alarmID.uuidString)) {
            Image(systemName: "xmark")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(context.attributes.tintColor, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Detener"))
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
