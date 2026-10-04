// What one completion used, as OpenRouter reports it at the end of the
// stream: tokens, and what they cost.

/// The tokens a completion used, and their cost.
public struct ORUsage: Sendable, Equatable {
    /// The prompt's tokens, those read from the provider's cache included.
    public var prompt: Int
    /// Of `prompt`, the tokens read from the cache.
    public var cached: Int
    public var completion: Int
    /// Dollars (OpenRouter's credits), when reported.
    public var cost: Double?

    public init(prompt: Int, cached: Int = 0, completion: Int, cost: Double? = nil) {
        self.prompt = prompt
        self.cached = cached
        self.completion = completion
        self.cost = cost
    }

    /// This and `more` together; a cost once either has one.
    public func adding(_ more: ORUsage) -> ORUsage {
        let cost: Double? = self.cost == nil && more.cost == nil ? nil : (self.cost ?? 0) + (more.cost ?? 0)
        return ORUsage(prompt: prompt + more.prompt, cached: cached + more.cached, completion: completion + more.completion, cost: cost)
    }
}
