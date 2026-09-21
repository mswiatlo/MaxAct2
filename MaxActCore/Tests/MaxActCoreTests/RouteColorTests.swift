import Foundation
import Testing

@testable import MaxActCore

@Suite struct RouteColorTests {
    @Test("an unset or unrecognised stored value falls back to the default")
    func storageFallback() {
        #expect(RouteColor(storageKey: nil) == .default)
        #expect(RouteColor(storageKey: "") == .default)
        // A value written by a future version that removed a colour must not crash or blank out.
        #expect(RouteColor(storageKey: "chartreuse") == .default)
    }

    @Test("a stored value round-trips")
    func storageRoundTrip() {
        for color in RouteColor.allCases {
            #expect(RouteColor(storageKey: color.rawValue) == color)
        }
    }

    @Test("cache tokens are distinct, so thumbnails can't be shared between colours")
    func cacheTokensAreDistinct() {
        let tokens = Set(RouteColor.allCases.map(\.cacheToken))
        #expect(tokens.count == RouteColor.allCases.count)
    }

    @Test("every colour is saturated enough to read over map tiles")
    func coloursAreVivid() {
        // The bug this replaces was a grey track. Grey is exactly the case where the channels sit
        // close together, so require a wide spread — and enough brightness to show on dark tiles.
        for color in RouteColor.allCases {
            let (red, green, blue) = color.components
            let channels = [red, green, blue]
            let spread = channels.max()! - channels.min()!
            #expect(spread > 0.4, "\(color.displayName) is too close to grey")
            #expect(channels.max()! > 0.5, "\(color.displayName) is too dark")
        }
    }

    @Test("the default is the vivid orange-red, which the settings picker relies on being present")
    func defaultIsListed() {
        #expect(RouteColor.default == .sunset)
        #expect(RouteColor.allCases.contains(.default))
    }
}
