// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

/// A manifest for a given user's conference.
struct Manifest: Codable {
    let clientID: String
    /// List of subscriptions this user should subscribe to.
    let subscriptions: [ManifestSubscription]
    /// List of publications this user should publish.
    let publications: [ManifestPublication]

    enum CodingKeys: String, CodingKey {
        case clientID = "clientId"
        case subscriptions, publications
    }
}

/// A set of related publication entries.
struct ManifestPublication: Codable {
    /// Details of the publication set.
    let mediaType, sourceName, sourceID, label: String
    /// The different individual publications and their profiles that should be published.
    let profileSet: ProfileSet

    enum CodingKeys: String, CodingKey {
        case mediaType, sourceName
        case sourceID = "sourceId"
        case label, profileSet
    }
}

/// A set of related subscription entries.
struct ManifestSubscription: Codable {
    /// Details of the subscription set.
    let mediaType, sourceName, sourceID, label: String
    /// The different individual subscriptions and their profiles that should be subscribed to.
    let profileSet: ProfileSet

    enum CodingKeys: String, CodingKey {
        case mediaType, sourceName
        case sourceID = "sourceId"
        case label, profileSet
    }
}

/// A profile set is a set of related profile or quality levels of a ``ManifestPublication`` or ``ManifestSubscription``.
struct ProfileSet: Codable {
    let type: String
    let profiles: [Profile]
}

/// A profile is an individual publication or subscription for a given quality profile,
struct Profile: Codable {
    /// A string describing the quality profile.
    let qualityProfile: String
    /// A list of TTLs for groups and/or objects in this profile.
    let expiry: [Int]?
    /// A list of priorities for groups and/or objects in this profile.
    let priorities: [Int]?
    /// The namespace this publication/subscription is for.
    let namespace: String

    enum CodingKeys: String, CodingKey {
        case qualityProfile, expiry, priorities
        case namespace = "quicrNamespace"
    }

    /// Ctreate a new quality profile from its parts.
    init(qualityProfile: String, expiry: [Int]?, priorities: [Int]?, namespace: String) {
        self.qualityProfile = qualityProfile
        self.expiry = expiry
        self.priorities = priorities
        self.namespace = namespace
    }

    /// Parse a profile from it's encoded representation.
    init(from decoder: Swift.Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        qualityProfile = try values.decode(String.self, forKey: .qualityProfile)
        expiry = try values.decodeIfPresent([Int].self, forKey: .expiry)
        priorities = try values.decodeIfPresent([Int].self, forKey: .priorities)
        namespace = try values.decode(String.self, forKey: .namespace)
    }
}

/// A conference is the joinable entity. A ``User`` joining a conference will receive a ``Manifest``.
struct Conference: Codable {
    let id: UInt32
    let title, starttime: String
    let duration: Int
    let state, type: String
    let meetingurl: String
    let clientindex: Int
    let participants, invitees: [String]
}

struct Config: Codable {
    let id: UInt32
    let configProfile: String
}

/// A ``User`` has one or more ``Client``s and joins a ``Conference``.
struct User: Codable {
    let id, name, email: String
    let clients: [Client]
}

/// A ``Client`` belongs to a ``User`` and has exposes its ``SendCapability``s and ``ReceiveCapability``s.
struct Client: Codable {
    let id, label: String
    let sendCaps: [SendCapability]
    let recvCaps: [ReceiveCapability]
}

/// What can be received by a ``Client`` instance.
struct ReceiveCapability: Codable {
    let mediaType, qualityProfie: String // TODO: Fix this in manifest to be "qualityProfile"
    let numStreams: Int
}

/// What can be sent by a ``Client`` instance.
struct SendCapability: Codable {
    let mediaType, sourceID, sourceName, label: String
    let profileSet: ProfileSet

    enum CodingKeys: String, CodingKey {
        case mediaType
        case sourceID = "sourceId"
        case sourceName, label, profileSet
    }
}
