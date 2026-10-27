import Foundation

/// The showcase's routes (issue 36): real paths in Vancouver, from OpenStreetMap
/// (© OpenStreetMap contributors, ODbL), with elevations from the Copernicus DEM via Open-Meteo.
///
/// Built once by a script (see the Xcode conventions reference, "README screenshots"): routed
/// along OSM's route relations — the Seaside Greenway, the Grouse Grind, the Spirit Trail, the
/// Adanac Bikeway — thinned to 2 m and encoded. Each string is Google's encoded-polyline scheme
/// over three values per point: latitude and longitude in 1e-5 degrees, elevation in 0.1 m.
enum ShowcaseRoutes {
    static let encoded: [String: String] = [
        "adanac-commute": #"yowkHvadnV_NBt@f@[jw@bBhAn@vBUzp@SEhA{@Sde@g@GlIREV?Ud_@rD@`CRR~H?C`BR"#,
        "english-bay-walk": #"y}ykHv_snVwGYbA~C]j@?Mf@?g@x@?kBfBwBsCfEwBuCjDrDy@^?[??_D[bBsAB?sAd@nA_A`AcGSl@?Cd@?\bBbG@bA?]vB_Dm@bB~Cg@^?s@O?_@V?o@P?w@n@?eAh@?uA~@?[^?s@vAoUG`@?@xA?J~@S^vBfOJ~A??lAzEU~@_NUh@?eB|B~MQJ?{BTwBgA\{@m@F?kAK?g@\rDe@YgEUA?cBt@fEg@r@?a@B?QI?MS?QkA?u@qB?OkB?"#,
        "false-creek": #"qsvkHbvlnVsDBg@?AkA?SmAz@wCgIf@OO?_@M?cA{CSk@]?CY?Bq@?Ei@SOQ?g@EoAGI?BeA?G[z@y@}@?aB_@RQW?Gk@?DiCRF}@?AsA?b@aBf@NoRSNQ?nAC?Hm@?`@]f@|@a@?|@Q?~A?S^U{@b@I?nA?nAdAb@f@jA@?nAnA?AvF?E\?EdG?CzL?_@A?CfI?Tp@?r@p@?Zl@?d@bEg@~AzKf@@nA?c@zA?HjA?Lj@?FE?CI?N??MC?LD??E?MA??F?N???G?SC?AH?|CDwBcMSkCwFg@bBq@]?g@o@bBk@yA?m@{BRpDqGg@lCpHg@RlA{@@jA?Cf@?"#,
        "grouse-grind": #"mzilHjuinV_sDx@y@wLHY?s@u@?CK?BsAsSAU?Mg@?A[?DY?d@o@oPBe@?HS?f@_@?FcB_NPeAvLs@{@wLKm@wL]G?GI?MeA?Ao@wLI]?q@UoF_@o@?e@U?[_@?Em@sN_@iA?Cg@?De@_NWc@cVMsB_NMK?WT?]K?k@a@?Ka@?]K_]_@]?i@S?[Z?MB?UcAkHWF?Ut@_IOP?cAB?e@q@?m@Q_I[F?Iy@_XK_@?I??GT?IB?Ii@?e@cA?[_BkW_@M?KY?WK?Ga@cVs@qA?Ie@?_@s@{^iAaDoUE]?@[?b@oA?@UgYg@I?c@J?EO?EaA?k@KcLM_Bk\AeA?H]?Ka@?HOc`@?M?O]?@e@?[G?GM?PoAwVEm@?]G?}@h@?My@_IOY?WE?_@B?UK?_@a@kH"#,
        "kits-jericho": #"quvkHfutnV?rBPkCNF?@J?M~VScAjCcBu@VbGW`@?EXoAKhXnAHT?VT?vBD_DBrA?IJ?`ItX{@RfBbB?tGvBL??@cEwBIxT?k@nLg@DzAoAMp@?@j@?Mf@?oCvi@cB?t@?SfC?CbCRDbA?Q??Gl@?EbIz@Db@?fChKjCdAvGR_@hDRm@hEnAAlC?Ed@?cA|Cg@_AzDSgBdGz@"#,
        "lions-gate-dundarave": #"aqzkH`lpnVcB{@yAR[Iz@Uj@{@y@|@?{@pCRST?i@Z?Wb@?YdB?M`DSKd@?S\SSLf@O@?gDcAcBIp@?NLz@qAT?@X?_AV{@g@X?gCxBoAU\?oA`DgEyB~HsDKl@?k@dBg@kChG~CuFdIkMqAtA~CuAjAwB{BlAz@qEpB_DoC`@SyBF?u@GwBSF?yAC?cCQwBgGkA_DwDqAwBcCmAf@KS?mAk@?QA?aCgB{@oE{DbBq@sAnA[SnFU??c@U?{hA}bAb[f@T?BH?Cd@nAUD?o@w@oAiD{Az@?L?xBnA?|BtBR?\?UV?Wl@RwCjJg@Kz@?CdA?\b@?DA?JT?dAjE{@~@nCz@RpASFx@?AhEf@KhBSDpA?E~@?PX?j@V?p@CwBpB|@?h@J~H\A?PH?Z@?VXgEDN?Ad@?CZ?k@`BRu@jDRc@dAkC_C~HrDsAvDSoAxEf@eDvH?iHnTf@y@`E{@B\?RZz@e@z@{@y@_@?EJ?_AjKSz@N?Ef@?GP?MpW?Ap@?Gh@?AdSg@qA@cB"#,
        "stanley-park-seawall": #"{szkH`ipnVSaAdA{@S^?{@fCRUX?e@R?OR?a@~B?GdDSKd@?S\SSLf@AI?Y??mBe@cBqAw@?mAwA?]y@{EU}@?OsEf@XkC??_@zEIg@?aA}A?c@}@z@a@cAwBSgAcBY@?AG?YZ?k@BbBk@[gE[u@?c@qDwB]{AoA[}B?g@kBcBM{@?[{D?AuAfE{B_@kCIV?qDgDvG{A[?M_@?v@qAnFf@gA?vBcHbBVqA?`AuCkCTaAjCJeA?XgE?F_D?I_A?_@gA?]o@?a@i@?o@[?s@}@?Wu@?Ge@?IM??S?FV?RJ?Lj@?NT?pBxA?qByA?OU?Mk@?SK?GW??R?HL?Fd@?Vt@?r@|@?n@Z?`@h@?\n@?^fA?H~@?Ap@?KpD?OfB?O`B?U`AkCaAtCjCWpA?wBbHcBg@fA?w@pAoF_BrBrIuAtAgE_@bAfEGj@??b@?RtC?ApB?QhC?_@tCg@BX?g@hC{@Ub@?oAfAwG{@d@?oDjCgEi@Z?[BbQ[T?sBjBsIs@zArIyChI?Sr@cGOjA?Kd@?IH?Q@?iAUbBwBZ?iAd@sDcBnA?}@d@rImBh@sIgA|ArIiDdDgE}B|C{@sBtAoPgBv@bLe@l@?Sb@?Qp@{JWxB?Od@jWg@h@?oA^?ST?P~B?@lB?l@xC?Dn@?BfB?ZdB?XvD?d@nA?Hd@?VrF?d@jC?JzA?Z|B??dB?Hl@?dA`C?z@xC?^v@?~AbC?FX?fAN?fBG{Ef@NzEd@h@?j@nC?|@lB?d@n@?nAz@?`@h@?Zr@?H\?@d@?C`@?Mf@?Aj@?@R?HJ?b@A?d@H?TM?`@C?\U?f@G?nDT?~AXwBlAh@oA~@[?\??vBDcB|AV?xDBzEz@H?~Cv@nAXL?VV?b@t@?NjB?t@pB?PjA?LR?PH?`@C?f@s@?bBu@gET@?d@XfEf@]sDjAJ?l@G?fA]z@zBUvBPK?dB}B_NTi@?T_A~M?mA{EK_B?_@wBgOK_ARAyA?Fa@?Ri@?z@mAnUtA_A?dAi@?v@o@?n@Q?^W?OwA_ITmA~CNuBwBFC?E]?Nq@?p@m@RBY?l@A?Rm@?~@aAbGrAe@oArAC?~CZcBZ??x@_@?tCkDsDrCgEvBjBgBvBf@y@?Lg@?\k@?XcA_DYbA~CU\?k@T?IE?S{@_DgAMg@MmA?oBcESOVf@sB{DS@E?i@{@Re@mA?e@y@?m@u@RBe@?q@iAjCY{@f@KK??uA?aA_KnA[qFcBIQ?UKbBEO?k@wD?UO?Fg@?m@k@?m@eA{@Uu@REc@?D]?SW?`@]SNg@?Dk@?@{@?C??DiARVeB?HY?NS?d@S?TY?z@gCSR_@?`AeAz@"#,
    ]

    /// A route's points as (coordinate, elevation in metres), with the elevation model's noise
    /// smoothed out.
    ///
    /// - Parameter shoreline: for paths at the foot of cliffs (the seawall). At the model's 90 m
    ///   resolution the cliff tops bleed onto the path: a flat seawall walk measured +234 m of climb.
    ///   So take the lowest height within 60 m, then average over 100 m.
    static func points(_ name: String, shoreline: Bool) -> [(coordinate: Coordinate, elevation: Double)] {
        let raw = points(name)
        guard raw.count > 2 else { return raw }
        var along = [0.0]
        for (a, b) in zip(raw, raw.dropFirst()) {
            let lat = a.coordinate.latitude * .pi / 180
            along.append(along.last! + hypot((b.coordinate.latitude - a.coordinate.latitude) * 111_320,
                                             (b.coordinate.longitude - a.coordinate.longitude) * 111_320 * cos(lat)))
        }
        func window(_ i: Int, _ radius: Double) -> [Int] {
            raw.indices.filter { abs(along[$0] - along[i]) <= radius }
        }
        let floor = shoreline ? raw.indices.map { i in window(i, 60).map { raw[$0].elevation }.min()! } : raw.map(\.elevation)
        return raw.indices.map { i in
            let near = window(i, shoreline ? 100 : 25)
            return (raw[i].coordinate, near.map { floor[$0] }.reduce(0, +) / Double(near.count))
        }
    }

    /// A route's points as (coordinate, elevation in metres), as stored.
    static func points(_ name: String) -> [(coordinate: Coordinate, elevation: Double)] {
        guard let text = encoded[name] else { return [] }
        var values: [Int] = [], current = 0, shift = 0
        for scalar in text.unicodeScalars {
            let chunk = Int(scalar.value) - 63
            current |= (chunk & 0x1F) << shift
            shift += 5
            if chunk < 0x20 {
                values.append((current & 1) != 0 ? ~(current >> 1) : current >> 1)
                current = 0; shift = 0
            }
        }
        var latitude = 0, longitude = 0, elevation = 0
        return stride(from: 0, to: values.count - 2, by: 3).map { index in
            latitude += values[index]; longitude += values[index + 1]; elevation += values[index + 2]
            return (Coordinate(latitude: Double(latitude) / 1e5, longitude: Double(longitude) / 1e5),
                    Double(elevation) / 10)
        }
    }
}
