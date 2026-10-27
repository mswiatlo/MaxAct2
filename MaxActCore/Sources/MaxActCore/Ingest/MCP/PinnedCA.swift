import CryptoKit
import Foundation
import Security

/// The certificate authority Health Auto Export creates on the phone when its MCP server is set
/// to HTTPS (issue 48). MaxAct trusts it for the phone link only — never system-wide, since its
/// private key lives on the phone.
///
/// Pinned to the CA rather than to the server certificate: HAE's server certificate names the
/// phone's IP address, so a phone that moves between networks presents a different one.
public struct PinnedCA: Sendable, Equatable {
    /// DER bytes, as stored.
    public let der: Data
    public let certificate: SecCertificate

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case unreadable
        case notACertificateAuthority

        public var description: String {
            switch self {
            case .unreadable: "That file isn't a certificate."
            case .notACertificateAuthority: "That certificate can't sign others, so it isn't the CA Health Auto Export exports."
            }
        }
    }

    /// From a PEM or DER file's contents.
    public init(contents: Data) throws(Problem) {
        let der = Self.der(from: contents) ?? contents
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { throw .unreadable }
        // The one thing a certificate needs to anchor a chain: to be one. A server certificate
        // pinned here by mistake would otherwise fail every connection with a vague TLS error.
        guard Self.isCA(der: der) else { throw .notACertificateAuthority }
        self.der = der
        self.certificate = certificate
    }

    /// SHA-256 of the certificate, as `AB:6A:…` — what HAE's export would show to compare with.
    public var fingerprint: String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    public var subjectSummary: String {
        (SecCertificateCopySubjectSummary(certificate) as String?) ?? ""
    }

    public static func == (lhs: PinnedCA, rhs: PinnedCA) -> Bool { lhs.der == rhs.der }

    private static func der(from contents: Data) -> Data? {
        guard let text = String(data: contents, encoding: .utf8),
              let begin = text.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = text.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<text.endIndex)
        else { return nil }
        return Data(base64Encoded: String(text[begin.upperBound..<end.lowerBound]), options: .ignoreUnknownCharacters)
    }

    /// Whether the certificate's basicConstraints extension says `CA:TRUE`. Read from the DER:
    /// evaluating it as its own anchor, tried first, accepted a `CA:FALSE` certificate (measured).
    static func isCA(der: Data) -> Bool {
        let bytes = [UInt8](der)
        let oid: [UInt8] = [0x06, 0x03, 0x55, 0x1D, 0x13]   // 2.5.29.19, basicConstraints
        guard var index = bytes.firstRange(of: oid)?.upperBound else { return false }
        // Optional `critical BOOLEAN`, then an OCTET STRING wrapping SEQUENCE { cA BOOLEAN DEFAULT FALSE, … }.
        if bytes[safe: index] == 0x01 { index += 3 }
        guard bytes[safe: index] == 0x04, let afterOctets = Self.skipLength(bytes, index + 1),
              bytes[safe: afterOctets] == 0x30, let inner = Self.skipLength(bytes, afterOctets + 1)
        else { return false }
        return bytes[safe: inner] == 0x01 && bytes[safe: inner + 1] == 0x01 && bytes[safe: inner + 2] == 0xFF
    }

    /// The index after a DER length starting at `index`.
    private static func skipLength(_ bytes: [UInt8], _ index: Int) -> Int? {
        guard let first = bytes[safe: index] else { return nil }
        return first < 0x80 ? index + 1 : index + 1 + Int(first & 0x7F)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
