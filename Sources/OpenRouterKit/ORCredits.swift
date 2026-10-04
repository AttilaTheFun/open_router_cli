// The account's credits (`GET /credits`): bought, and spent.

/// The credits on the key's account, in dollars.
public struct ORCredits: Sendable, Equatable, Decodable {
    public var totalCredits: Double
    public var totalUsage: Double

    public init(totalCredits: Double, totalUsage: Double) {
        self.totalCredits = totalCredits
        self.totalUsage = totalUsage
    }

    enum CodingKeys: String, CodingKey {
        case totalCredits = "total_credits"
        case totalUsage = "total_usage"
    }
}
