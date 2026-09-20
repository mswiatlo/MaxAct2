import Foundation
import Testing

@testable import MaxActCore

@Suite struct UnitsTests {
    @Test("kJ and kcal convert to the same canonical value")
    func energyVocabulariesAgree() throws {
        // The measured pair: one workout exported under both HAE unit settings.
        let fromKJ = try Units.value(1121.8603941990377, in: "kJ", as: .energy, field: "activeEnergyBurned")
        let fromKcal = try Units.value(268.13106935923463, in: "kcal", as: .energy, field: "activeEnergyBurned")
        #expect(abs(fromKJ - fromKcal) < 1e-9)
    }

    @Test("count/min and bpm are the same unit under different names")
    func rateVocabulariesAgree() throws {
        let a = try Units.value(140.04751754400314, in: "count/min", as: .rate, field: "avgHeartRate")
        let b = try Units.value(140.04751754400314, in: "bpm", as: .rate, field: "avgHeartRate")
        #expect(a == b)
    }

    @Test("count and steps are the same unit under different names")
    func countVocabulariesAgree() throws {
        #expect(try Units.value(79.0, in: "count", as: .count, field: "stepCount")
                == Units.value(79.0, in: "steps", as: .count, field: "stepCount"))
    }

    /// HAE labels avgSpeed/maxSpeed "km". Verified against the same workout's .hae measurements
    /// block, which gave averageSpeed 3.750324900751945 m/s — exactly 13.501169642707001 km/h.
    @Test("the km-labelled speed quirk is read as km/h, not as a length")
    func mislabelledSpeedIsHandled() throws {
        let metersPerSecond = try Units.value(13.501169642707001, in: "km", as: .speed, field: "avgSpeed")
        #expect(abs(metersPerSecond - 3.750324900751945) < 1e-12)
    }

    @Test("the quirk does not leak into length fields")
    func lengthStillTreatsKmAsDistance() throws {
        #expect(try Units.value(11.36361451074503, in: "km", as: .length, field: "distance") == 11363.61451074503)
    }

    @Test("imperial units fail loudly rather than being misread", arguments: [
        ("mi", Units.Dimension.length), ("ft", .length), ("mi/hr", .speed), ("lb", .energy),
    ])
    func imperialIsRejected(unit: String, dimension: Units.Dimension) {
        #expect(throws: UnknownUnitError.self) {
            try Units.value(1, in: unit, as: dimension, field: "distance")
        }
    }

    @Test("the error names the field, unit and dimension so the failure is actionable")
    func errorIsDiagnostic() {
        let error = UnknownUnitError(field: "distance", unit: "mi", dimension: .length)
        #expect(error.description == "unsupported unit 'mi' for length field 'distance'")
    }
}
