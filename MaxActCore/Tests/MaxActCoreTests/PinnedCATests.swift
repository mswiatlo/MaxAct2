import Foundation
import Testing

@testable import MaxActCore

/// Issue 48: the certificate MaxAct pins HTTPS to the phone with.
@Suite struct PinnedCATests {
    /// Throwaway certificates made for this test with `openssl req -x509`; their keys were
    /// discarded. The CA has `CA:TRUE`, the other `CA:FALSE`.
    static let caPEM = """
-----BEGIN CERTIFICATE-----
MIIBiTCCAS+gAwIBAgIUGBYrDy7a9vM8cED9GQ7r+WSHNAEwCgYIKoZIzj0EAwIw
EjEQMA4GA1UEAwwHVGVzdCBDQTAeFw0yNjEwMjcyMTExMjdaFw0zNjEwMjQyMTEx
MjdaMBIxEDAOBgNVBAMMB1Rlc3QgQ0EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNC
AASeQzt5gltoBsOkroRuzk/XSQxYVhmoSRjGkjvTLjSbrJe/Fv0JtN7JyMQiLW4K
/9OikMl+Nqh1B7B9rHIzsYv1o2MwYTAdBgNVHQ4EFgQUBsWeu5EVb5uY8YNt3idG
CWLMW/YwHwYDVR0jBBgwFoAUBsWeu5EVb5uY8YNt3idGCWLMW/YwDwYDVR0TAQH/
BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAgQwCgYIKoZIzj0EAwIDSAAwRQIhAP4g8t8C
tlqjfyuTjSGjsXj6TKDngkeHsSPw6g/4NXmNAiA3klhFfV/IxkpIcFOQKAzDp7xm
3PqUkDNOrtuFTQ3vvw==
-----END CERTIFICATE-----
"""
    static let notACAPEM = """
-----BEGIN CERTIFICATE-----
MIIBeDCCAR6gAwIBAgIURg2kS/CpDivIJd/hzuqaNFht0vAwCgYIKoZIzj0EAwIw
EzERMA8GA1UEAwwITm90IEEgQ0EwHhcNMjYxMDI3MjExMTI3WhcNMzYxMDI0MjEx
MTI3WjATMREwDwYDVQQDDAhOb3QgQSBDQTBZMBMGByqGSM49AgEGCCqGSM49AwEH
A0IABG9bKRIjm+pYB0TjeWcTD1mRDI9KOuOxWOmnQ8mVVNwPJK3U8d7Cq0NhkRlk
g8Z+tuWOCXUMGM72xLDNtcVk2bKjUDBOMB0GA1UdDgQWBBQ4rDF5RubLC5rE8YAP
CPPsY5Po7TAfBgNVHSMEGDAWgBQ4rDF5RubLC5rE8YAPCPPsY5Po7TAMBgNVHRMB
Af8EAjAAMAoGCCqGSM49BAMCA0gAMEUCIDu3mPZU+7ITJU0ayVRuEQTWHhF5A2is
vGdPoxARhshrAiEAwQ50JeWjNN29NTdSa1flM2jVDCcEKyiSXjkT1mjnHxU=
-----END CERTIFICATE-----
"""
    static let caFingerprint = "5A:A0:38:05:F9:C0:35:79:5E:D9:32:E2:AD:31:B2:49:BB:DC:07:4D:A7:8F:22:6C:54:88:08:D4:22:E0:5D:40"

    @Test("a CA loads from PEM or DER, with its SHA-256 fingerprint")
    func loadsACA() throws {
        let pem = try PinnedCA(contents: Data(Self.caPEM.utf8))
        #expect(pem.fingerprint == Self.caFingerprint, "matches openssl's")
        #expect(pem.subjectSummary == "Test CA")
        let der = try PinnedCA(contents: pem.der)
        #expect(der == pem)
    }

    @Test("a certificate that can't sign others is refused")
    func refusesANonCA() {
        #expect(throws: PinnedCA.Problem.notACertificateAuthority) {
            try PinnedCA(contents: Data(Self.notACAPEM.utf8))
        }
    }

    @Test("something that isn't a certificate is refused", arguments: ["", "hello", "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----"])
    func refusesGarbage(_ text: String) {
        #expect(throws: PinnedCA.Problem.unreadable) { try PinnedCA(contents: Data(text.utf8)) }
    }

    @Test("the HTTPS setting decides the scheme, whatever was typed")
    func endpointScheme() throws {
        let typed = try #require(MCPEndpoint("https://10.0.0.5:9001/mcp"))
        #expect(typed.with(https: false).url.absoluteString == "http://10.0.0.5:9001/mcp")
        #expect(typed.with(https: false).with(https: true) == typed)
        #expect(typed.isHTTPS && !typed.with(https: false).isHTTPS)
    }

    @Test("an untrusted certificate is reported as such, not as a cancellation")
    func untrustedIsNamed() {
        #expect(SyncProblem(error: GuardedSession.UntrustedCertificate()) == .certificateNotTrusted)
    }
}
