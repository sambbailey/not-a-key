import Testing
@testable import Sentry

struct VINTests {
    @Test("vinNormalization", arguments: [
        (" 7saygdee5ta123456 ", "7SAYGDEE5TA123456"),
        ("7SAYGDEE5TA12345", nil),        // 16 chars
        ("7SAYGDEE5TA12345O", nil),       // contains O
        ("7SAY GDEE5TA1\t23456", "7SAYGDEE5TA123456"),  // inner whitespace
        ("7SAYGDEE5TA12345I", nil),       // contains I
        ("7SAYGDEE5TA12345Q", nil),       // contains Q
        ("7SAYGDEE5TA12345-", nil),       // punctuation
        ("7SAYGDEE5TA1234567", nil),      // 18 chars
    ])
    func vinNormalization(raw: String, expected: String?) {
        #expect(VIN.normalize(raw) == expected)
    }
}
