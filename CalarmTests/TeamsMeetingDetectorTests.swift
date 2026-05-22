//
//  TeamsMeetingDetectorTests.swift
//  CalarmTests
//

import Foundation
import Testing
@testable import Calarm

struct TeamsMeetingDetectorTests {

    @Test func extractsFromDirectURL() {
        let url = URL(string: "https://teams.microsoft.com/l/meetup-join/abc")!
        let result = TeamsMeetingDetector.extractTeamsURL(url: url, location: nil, notes: nil)
        #expect(result == url)
    }

    @Test func extractsFromNotes() {
        let notes = "Join meeting: https://teams.microsoft.com/l/meetup-join/xyz Thanks!"
        let result = TeamsMeetingDetector.extractTeamsURL(url: nil, location: nil, notes: notes)
        #expect(result?.host == "teams.microsoft.com")
    }

    @Test func extractsFromLocation() {
        let result = TeamsMeetingDetector.extractTeamsURL(
            url: nil,
            location: "https://teams.live.com/meet/12345",
            notes: nil
        )
        #expect(result?.host == "teams.live.com")
    }

    @Test func ignoresNonTeamsURLs() {
        let url = URL(string: "https://zoom.us/j/123")!
        let result = TeamsMeetingDetector.extractTeamsURL(url: url, location: nil, notes: "https://meet.google.com/abc")
        #expect(result == nil)
    }

    @Test func handlesEmptyInputs() {
        let result = TeamsMeetingDetector.extractTeamsURL(url: nil, location: "", notes: "")
        #expect(result == nil)
    }

    @Test func isTeamsURLAcceptsSubdomains() {
        let url = URL(string: "https://gov.teams.microsoft.com/l/meetup/123")!
        #expect(TeamsMeetingDetector.isTeamsURL(url))
    }

    @Test func isTeamsURLRejectsLookAlikes() {
        let url = URL(string: "https://teams.microsoft.com.fake.com/path")!
        #expect(!TeamsMeetingDetector.isTeamsURL(url))
    }
}
