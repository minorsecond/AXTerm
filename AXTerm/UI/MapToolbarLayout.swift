import Foundation

/// What the iOS map's toolbar shows. On an iPad the centered tab bar leaves
/// room for three items; a fourth folded Layers and More into an overflow
/// menu. Car Mode, occasional on an iPad, moves into More there, so the
/// controls used most stay one tap away.
enum MapToolbarLayout {
    enum Item: Equatable { case carMode, stations, layers, more }

    static func barItems(regularWidth: Bool) -> [Item] {
        regularWidth ? [.stations, .layers, .more] : [.carMode, .stations, .layers, .more]
    }

    static func carModeInMore(regularWidth: Bool) -> Bool { regularWidth }
}
