import Foundation
import GoogleMaps
import MapsIndoorsCore

class GMTileProvider: GMSTileLayer {
    required init(provider: MPTileProvider) {
        _tileProvider = provider
        super.init()
        tileSize = Int(provider.tileSize())
    }

    var _tileProvider: MPTileProvider

    override func requestTileFor(x: UInt, y: UInt, zoom: UInt, receiver: GMSTileReceiver) {
        let r = receiver
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            let tile = _tileProvider.getTile(x: x, y: y, zoom: zoom)
            r.receiveTileWith(x: x, y: y, zoom: zoom, image: tile)
        }
    }
}
