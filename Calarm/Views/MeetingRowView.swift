//
//  MeetingRowView.swift
//  Calarm
//

import SwiftUI

struct MeetingRowView: View {
    let meeting: Meeting
    let leadTimes: [AlarmLeadTime]
    let alarmsEnabled: Bool

    @Environment(\.openURL) private var openURL

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title)
                        .font(.headline)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(Self.timeFormatter.string(from: meeting.startDate)) – \(Self.timeFormatter.string(from: meeting.endDate))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let organizer = meeting.organizer {
                        HStack(spacing: 6) {
                            Image(systemName: "person")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(organizer)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 0)

                alarmBadge
            }

            if let teamsURL = meeting.teamsURL {
                Button {
                    openURL(teamsURL)
                } label: {
                    Label("Unirse en Teams", systemImage: "video.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.appAccent)
            } else if let location = meeting.location, !location.isEmpty {
                Button {
                    openMaps(query: location)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse")
                        Text(location)
                            .lineLimit(1)
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var alarmBadge: some View {
        if !alarmsEnabled || leadTimes.isEmpty {
            Image(systemName: "bell.slash")
                .foregroundStyle(.secondary)
                .padding(8)
                .background(.secondary.opacity(0.15), in: Circle())
                .symbolEffect(.pulse, options: .nonRepeating, value: alarmsEnabled)
        } else if leadTimes.count == 1, let only = leadTimes.first {
            Label(only.shortTitle, systemImage: "bell.fill")
                .font(.caption.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.tint.opacity(0.15), in: Capsule())
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, options: .nonRepeating, value: leadTimes)
        } else {
            Label("\(leadTimes.count) avisos", systemImage: "bell.badge.fill")
                .font(.caption.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.tint.opacity(0.15), in: Capsule())
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, options: .nonRepeating, value: leadTimes.count)
        }
    }

    private func openMaps(query: String) {
        guard
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
            let url = URL(string: "http://maps.apple.com/?q=\(encoded)&dirflg=d")
        else { return }
        openURL(url)
    }
}
