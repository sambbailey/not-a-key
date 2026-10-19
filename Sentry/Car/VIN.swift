/// A vehicle identification number as typed by the owner.
enum VIN {
    /// Letters I, O and Q never appear in a VIN.
    private static let allowed = Set("ABCDEFGHJKLMNPRSTUVWXYZ0123456789")

    /// Uppercases `raw` and drops whitespace; nil unless that leaves a well-formed 17-character VIN.
    static func normalize(_ raw: String) -> String? {
        let vin = raw.filter { !$0.isWhitespace }.uppercased()
        guard vin.count == 17, vin.allSatisfy(allowed.contains) else { return nil }
        return vin
    }
}
