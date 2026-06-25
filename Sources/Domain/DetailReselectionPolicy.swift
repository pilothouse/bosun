public enum DetailReselectionPolicy {
    /// Whether clicking `target` should (re)fetch its detail. Skips only when the loaded detail is
    /// already that exact item — re-clicking the open item is a no-op (no flash, no refetch). A click
    /// on any other item, or on one whose detail hasn't loaded (first open, or a retry after a
    /// failed/aborted fetch), fetches. Pure — one unit test, shared by the mouse path and any future
    /// keyboard-driven selection.
    public static func shouldFetchDetail(loadedDetailId: String?, target: String) -> Bool {
        loadedDetailId != target
    }
}
