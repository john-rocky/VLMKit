/// What a model/backend can do. Used for capability negotiation so recipes can
/// check requirements (e.g. multi-image) before running.
public struct VLMCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let imageInput     = VLMCapabilities(rawValue: 1 << 0)
    public static let multipleImages = VLMCapabilities(rawValue: 1 << 1)
    public static let videoInput     = VLMCapabilities(rawValue: 1 << 2)
    public static let streaming      = VLMCapabilities(rawValue: 1 << 3)
    public static let toolCalling    = VLMCapabilities(rawValue: 1 << 4)
}
