import MapKit
import MaxActCore

/// Framing a route for MapKit.
///
/// One place for the conversion so the detail map and the thumbnail renderer agree on what
/// "show the whole route" means, even though they pass different framing values.
extension MKCoordinateRegion {
    init(fitting bounds: CoordinateBounds, headroom: Double, minimumSpan: Double) {
        let span = bounds.displaySpan(headroom: headroom, minimumSpan: minimumSpan)
        self.init(
            center: CLLocationCoordinate2D(
                latitude: bounds.centre.latitude, longitude: bounds.centre.longitude
            ),
            span: MKCoordinateSpan(latitudeDelta: span.latitude, longitudeDelta: span.longitude)
        )
    }

    /// `nil` for an empty route, which is the caller's cue to show no map at all rather than an
    /// arbitrary region — an unaimed map renders as a blank grey rectangle.
    init?(fitting coordinates: [Coordinate], headroom: Double, minimumSpan: Double) {
        guard let bounds = CoordinateBounds(coordinates) else { return nil }
        self.init(fitting: bounds, headroom: headroom, minimumSpan: minimumSpan)
    }
}
