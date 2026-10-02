//
//  GMGoogleRoutingCapability.swift
//  MapsIndoorsGoogleMaps
//
//  Created by Aditya Singh Gaharwar on 05/06/2026.
//  Copyright © 2026 MapsPeople A/S. All rights reserved.
//

import Foundation
import os

/// Remembers, per Google API key, whether the Routes API is usable.
///
/// The SDK cannot introspect which APIs a Google key may call, so the first
/// routing request probes the Routes API and falls back to the legacy
/// Directions/Distance Matrix APIs on 403 (SPEX-1905). The outcome is cached
/// here so the doomed probe is not repeated on every request — it must be
/// static state because `GoogleMapProvider` constructs a fresh service
/// instance on every `routingService`/`distanceMatrixService` access.
enum GMGoogleRoutingCapability {
    enum State {
        /// Not probed yet — try the Routes API first.
        case unknown
        /// The Routes API answered — keep using it.
        case routesAvailable
        /// The Routes API returned 403 — use the legacy APIs only.
        case legacyOnly
    }

    private static let states = OSAllocatedUnfairLock(initialState: [String: State]())

    static func state(for apiKey: String) -> State {
        states.withLock { $0[apiKey] ?? .unknown }
    }

    static func set(_ state: State, for apiKey: String) {
        states.withLock { $0[apiKey] = state }
    }

    /// Test hook: forget all probe outcomes.
    static func reset() {
        states.withLock { $0.removeAll() }
    }
}
