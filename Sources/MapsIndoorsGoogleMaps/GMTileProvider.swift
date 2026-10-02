import Foundation
@preconcurrency import GoogleMaps
import MapsIndoorsCore

class GMTileProvider: GMSTileLayer {
    required init(provider: MPTileProvider) {
        _tileProvider = provider
        super.init()
        tileSize = Int(provider.tileSize())
    }

    var _tileProvider: MPTileProvider

    override func requestTileFor(x: UInt, y: UInt, zoom: UInt, receiver: GMSTileReceiver) {
        // A global queue, not a `Task`: `getTile` blocks on a synchronous network download (`Data(contentsOf:)`)
        // when the tile is not cached. A blocked task would hold one of the cooperative pool's few threads (one
        // per core) for up to the request timeout, and a viewport asks for tens of tiles, which can starve every
        // actor and task in the process on a slow network. GCD grows threads for blocking work; the pool does
        // not. Only the Sendable tile provider is captured; `receiver` is a Google Maps object that the SDK is
        // expected to call back from any thread.
        let tileProvider = _tileProvider
        DispatchQueue.global(qos: .userInteractive).async {
            let tile = tileProvider.getTile(x: x, y: y, zoom: zoom)
            receiver.receiveTileWith(x: x, y: y, zoom: zoom, image: tile)
        }
    }
}
