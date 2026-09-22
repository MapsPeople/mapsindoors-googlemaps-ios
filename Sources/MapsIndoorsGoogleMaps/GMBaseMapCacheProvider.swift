import Foundation
@_spi(Private) import MapsIndoors

/// No-op implementation of ``MapProviderBaseMapCache`` for the Google Maps provider.
///
/// Google Maps does not support native offline tile caching via the MapsIndoors
/// SDK — all mutating methods throw ``MPError/baseMapCachingNotSupported``.
final class GMBaseMapCacheProvider: MapProviderBaseMapCache {
    /// Google Maps has no native offline tile store the SDK can drive, so this provider is
    /// registered (see `GoogleMapProvider`) but never usable. `synchronizeBaseMapTiles` reads
    /// this before doing any work, which is what turns the Google path into an immediate
    /// `baseMapCachingNotSupported` instead of a venue fetch followed by a throwing
    /// `cacheRegion`.
    let supportsBaseMapCaching = false

    func cacheRegion(
        bounds: MPGeoBounds,
        minZoom: Double,
        maxZoom: Double,
        id: String,
        styleSource: MPMapboxStyleSource
    ) async throws {
        throw MPError.baseMapCachingNotSupported
    }

    func estimateRegion(
        bounds: MPGeoBounds,
        minZoom: Double,
        maxZoom: Double,
        id: String,
        styleSource: MPMapboxStyleSource
    ) async throws -> MPBaseMapSizeEstimate {
        throw MPError.baseMapCachingNotSupported
    }

    func removeCachedRegion(id: String) async throws {
        throw MPError.baseMapCachingNotSupported
    }

    func cachedRegionIds() async -> [String] { [] }

    var cachedRegionSize: UInt64 { 0 }

    func cachedRegionSize(forRegionIds ids: [String]) async -> UInt64 { 0 }
}
