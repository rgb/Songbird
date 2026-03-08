import Songbird

/// Event type string constants for the WarblerCatalog domain.
public enum CatalogEventTypes {
    public static let videoPublished = "VideoPublished"
    public static let videoPublishedV1 = "VideoPublished_v1"
    public static let videoMetadataUpdated = "VideoMetadataUpdated"
    public static let videoTranscodingCompleted = "VideoTranscodingCompleted"
    public static let videoUnpublished = "VideoUnpublished"
}
