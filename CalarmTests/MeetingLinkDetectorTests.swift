//
//  MeetingLinkDetectorTests.swift
//  CalarmTests
//

import Foundation
import Testing
@testable import Calarm

struct MeetingLinkDetectorTests {

    // MARK: - Teams

    @Test func extractsFromDirectURL() {
        let url = URL(string: "https://teams.microsoft.com/l/meetup-join/abc")!
        let result = MeetingLinkDetector.extractMeetingLink(url: url, location: nil, notes: nil)
        #expect(result?.url == url)
        #expect(result?.provider == .teams)
    }

    @Test func extractsFromNotes() {
        let notes = "Join meeting: https://teams.microsoft.com/l/meetup-join/xyz Thanks!"
        let result = MeetingLinkDetector.extractMeetingLink(url: nil, location: nil, notes: notes)
        #expect(result?.url.host == "teams.microsoft.com")
    }

    @Test func extractsFromLocation() {
        let result = MeetingLinkDetector.extractMeetingLink(
            url: nil,
            location: "https://teams.live.com/meet/12345",
            notes: nil
        )
        #expect(result?.url.host == "teams.live.com")
        #expect(result?.provider == .teams)
    }

    @Test func prefersJoinLinkOverMobileBrowserRouter() {
        // Real-world invite layout: the visit.teams.microsoft.com WebRTC router
        // appears BEFORE the actual join link in the notes.
        let notes = """
        Join the Teams Meeting from your mobile web browser:
         https://visit.teams.microsoft.com/webrtc-svc/api/route?tid=abc&convId=19:meeting_X@thread.v2
        Reunión de Microsoft Teams
        Unirse: https://teams.microsoft.com/meet/276461119725387?p=n91332a7n
        Ayuda: https://aka.ms/JoinTeamsMeeting?omkt=es-PE
        Opciones de la reunión: https://teams.microsoft.com/meetingOptions/?organizerId=abc
        """
        let result = MeetingLinkDetector.extractMeetingLink(url: nil, location: nil, notes: notes)
        #expect(result?.url.host == "teams.microsoft.com")
        #expect(result?.url.path.hasPrefix("/meet/") == true)
    }

    @Test func prefersJoinLinkInNotesOverRouterInURLField() {
        let routerURL = URL(string: "https://visit.teams.microsoft.com/webrtc-svc/api/route?tid=abc")!
        let notes = "Unirse: https://teams.microsoft.com/l/meetup-join/19%3ameeting_X%40thread.v2/0"
        let result = MeetingLinkDetector.extractMeetingLink(url: routerURL, location: nil, notes: notes)
        #expect(result?.url.path.hasPrefix("/l/meetup-join") == true)
    }

    @Test func fallsBackToRouterWhenNoJoinLinkExists() {
        let notes = "https://visit.teams.microsoft.com/webrtc-svc/api/route?tid=abc"
        let result = MeetingLinkDetector.extractMeetingLink(url: nil, location: nil, notes: notes)
        #expect(result?.url.host == "visit.teams.microsoft.com")
    }

    // MARK: - Zoom

    @Test func extractsZoomJoinLink() {
        let notes = "Únete a la reunión Zoom: https://us02web.zoom.us/j/85123456789?pwd=abcDEF123"
        let result = MeetingLinkDetector.extractMeetingLink(url: nil, location: nil, notes: notes)
        #expect(result?.provider == .zoom)
        #expect(result?.url.host == "us02web.zoom.us")
        #expect(result?.url.path.hasPrefix("/j/") == true)
    }

    @Test func extractsCorporateZoomLinkFromLocation() {
        let result = MeetingLinkDetector.extractMeetingLink(
            url: nil,
            location: "https://empresa.zoom.us/j/123456789",
            notes: nil
        )
        #expect(result?.provider == .zoom)
    }

    @Test func prefersZoomJoinLinkOverGenericZoomURL() {
        let notes = """
        Más info en https://zoom.us/es/support
        Unirse: https://zoom.us/j/99887766554
        """
        let result = MeetingLinkDetector.extractMeetingLink(url: nil, location: nil, notes: notes)
        #expect(result?.url.path.hasPrefix("/j/") == true)
    }

    // MARK: - Google Meet

    @Test func extractsGoogleMeetLink() {
        let notes = "Unirse con Google Meet: https://meet.google.com/abc-defg-hij"
        let result = MeetingLinkDetector.extractMeetingLink(url: nil, location: nil, notes: notes)
        #expect(result?.provider == .googleMeet)
        #expect(result?.url.path == "/abc-defg-hij")
    }

    @Test func extractsGoogleMeetFromURLField() {
        let url = URL(string: "https://meet.google.com/lookup/xyz123")!
        let result = MeetingLinkDetector.extractMeetingLink(url: url, location: nil, notes: nil)
        #expect(result?.provider == .googleMeet)
    }

    // MARK: - Negatives

    @Test func ignoresNonMeetingURLs() {
        let url = URL(string: "https://example.com/j/123")!
        let result = MeetingLinkDetector.extractMeetingLink(url: url, location: nil, notes: "https://github.com/abc")
        #expect(result == nil)
    }

    @Test func handlesEmptyInputs() {
        let result = MeetingLinkDetector.extractMeetingLink(url: nil, location: "", notes: "")
        #expect(result == nil)
    }

    @Test func providerAcceptsSubdomains() {
        let url = URL(string: "https://gov.teams.microsoft.com/l/meetup/123")!
        #expect(MeetingLinkDetector.provider(for: url) == .teams)
    }

    @Test func providerRejectsLookAlikes() {
        #expect(MeetingLinkDetector.provider(for: URL(string: "https://teams.microsoft.com.fake.com/path")!) == nil)
        #expect(MeetingLinkDetector.provider(for: URL(string: "https://notzoom.us/j/123")!) == nil)
        #expect(MeetingLinkDetector.provider(for: URL(string: "https://meet.google.com.evil.io/abc")!) == nil)
    }
}
