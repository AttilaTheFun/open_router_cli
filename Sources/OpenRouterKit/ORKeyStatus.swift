// The key's own figures (`GET /key`): what it has spent, and the limit
// set on it, if any.

/// What OpenRouter says of the key in use, in dollars.
public struct ORKeyStatus: Sendable, Equatable, Decodable {
    /// The most the key may spend (in each period, when it resets); nil
    /// when it has no limit.
    public var limit: Double?
    /// What is left of the limit.
    public var limitRemaining: Double?
    /// When the limit starts over: "daily", "weekly", "monthly", or nil
    /// for never.
    public var limitReset: String?
    /// What the key has spent in all.
    public var usage: Double
    public var isFreeTier: Bool

    public init(limit: Double? = nil, limitRemaining: Double? = nil, limitReset: String? = nil, usage: Double, isFreeTier: Bool = false) {
        self.limit = limit
        self.limitRemaining = limitRemaining
        self.limitReset = limitReset
        self.usage = usage
        self.isFreeTier = isFreeTier
    }

    enum CodingKeys: String, CodingKey {
        case limit, usage
        case limitRemaining = "limit_remaining"
        case limitReset = "limit_reset"
        case isFreeTier = "is_free_tier"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        limit = try c.decodeIfPresent(Double.self, forKey: .limit)
        limitRemaining = try c.decodeIfPresent(Double.self, forKey: .limitRemaining)
        limitReset = try c.decodeIfPresent(String.self, forKey: .limitReset)
        usage = try c.decodeIfPresent(Double.self, forKey: .usage) ?? 0
        isFreeTier = try c.decodeIfPresent(Bool.self, forKey: .isFreeTier) ?? false
    }
}
