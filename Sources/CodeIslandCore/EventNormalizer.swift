import Foundation

public enum EventNormalizer {
    /// Normalize event names from various CLIs to internal PascalCase names
    public static func normalize(_ name: String) -> String {
        // Claude and Codex already emit PascalCase events — the normalizer is a
        // passthrough for those. Kept as a seam in case a future CLI needs aliasing.
        return name
    }
}
