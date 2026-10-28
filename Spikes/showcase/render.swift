import AppKit
import MapKit

// Draws each route in routes.json over an Apple Maps snapshot, for checking by eye. Not committed.
let routes = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "routes.json"))) as! [String: [[Double]]]
let names = CommandLine.arguments.dropFirst().isEmpty ? Array(routes.keys).sorted() : Array(CommandLine.arguments.dropFirst())
Task { @MainActor in
    for name in names {
        guard let points = routes[name] else { continue }
        let coords = points.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lons.min()! + lons.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: (lats.max()! - lats.min()!) * 1.25 + 0.002,
                                    longitudeDelta: (lons.max()! - lons.min()!) * 1.25 + 0.003)
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: center, span: span)
        options.size = CGSize(width: 900, height: 700)
        let snapshot = try! await MKMapSnapshotter(options: options).start()
        let image = NSImage(size: options.size)
        image.lockFocus()
        snapshot.image.draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
        let path = NSBezierPath()
        for (index, coordinate) in coords.enumerated() {
            let point = snapshot.point(for: coordinate)   // origin bottom-left on macOS
            index == 0 ? path.move(to: point) : path.line(to: point)
        }
        NSColor.systemRed.setStroke(); path.lineWidth = 2.5; path.stroke()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(name).png"))
        print("rendered \(name)")
    }
    exit(0)
}
RunLoop.main.run(until: Date().addingTimeInterval(120))
