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

    /// The model named by a Tesla VIN's fourth character, e.g. "Model Y"; nil if it isn't one.
    static func modelName(_ vin: String) -> String? {
        guard vin.count == 17 else { return nil }
        return switch vin[vin.index(vin.startIndex, offsetBy: 3)] {
        case "S": "Model S"
        case "3": "Model 3"
        case "X": "Model X"
        case "Y": "Model Y"
        case "C": "Cybertruck"
        default: nil
        }
    }
}
