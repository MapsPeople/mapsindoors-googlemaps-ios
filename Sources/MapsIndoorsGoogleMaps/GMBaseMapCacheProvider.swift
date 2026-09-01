import Foundation
@_spi(Private) import MapsIndoors

/// No-op implementation of ``MapProviderBaseMapCache`` for the Google Maps provider.
///
/// Google Maps does not support native offline tile caching via the MapsIndoors
/// SDK — all mutating methods throw ``MPError/baseMapCachingNotSupported``.
final class GMBaseMapCacheProvider: MapProviderBaseMapCache {
    func cacheRegion(
        bounds: MPGeoBounds,
        minZoom: Double,
        maxZoom: Double,
        id: String,
        styleSource: MPMapboxStyleSource
    ) async throws {
        throw MPError.baseMapCachingNotSupported
    }

    func removeCachedRegion(id: String) async throws {
        throw MPError.baseMapCachingNotSupported
    }

    func cachedRegionIds() async -> [String] { [] }

    var cachedRegionSize: UInt64 { 0 }

    func cachedRegionSize(forRegionIds ids: [String]) async -> UInt64 { 0 }
}
