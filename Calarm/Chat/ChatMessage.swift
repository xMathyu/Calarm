//
//  ChatMessage.swift
//  Calarm
//

import Foundation

/// One turn in the conversation between the user and the on-device assistant.
struct ChatMessage: Identifiable, Equatable, Hashable {
    enum Role: String, Codable, Hashable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    /// Streaming may mutate this — keep it `var` so the chat view can show
    /// partial text as it arrives.
    var content: String
    let timestamp: Date

    init(id: UUID = UUID(), role: Role, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}
