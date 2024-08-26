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
        DispatchQueue.global(qos: .userInteractive).async {
            let tile = self._tileProvider.getTile(x: x, y: y, zoom: zoom)
            DispatchQueue.main.async {
                receiver.receiveTileWith(x: x, y: y, zoom: zoom, image: tile)
            }
        }
    }
}
