import Foundation

/// The grid shape one page uses: `columns` × `rows` slots. `preset` is the fixed preset it came from
/// (what `auto` resolved to).
public struct MissionPageShape: Sendable, Equatable {
    public let preset: MissionLayoutPreset
    public let columns: Int
    public let rows: Int

    public init(preset: MissionLayoutPreset, columns: Int, rows: Int) {
        self.preset = preset
        self.columns = columns
        self.rows = rows
    }

    /// Sessions per page — fixed by the shape, so page boundaries don't move as sessions change state.
    public var perPage: Int { columns * rows }
}

/// Paging rules for Mission Control's grid. The grid never scrolls: sessions are split into pages of
/// `perPage`, and the user flips pages. Every page keeps the same slot shape, so tiles never change
/// size on a flip.
public enum MissionPagePolicy {

    /// Whether `columns` × `rows` tiles, `gap` apart, each stay at least `minTileWidth` × `minTileHeight`
    /// inside the area.
    public static func fits(columns: Int, rows: Int, areaWidth: Double, areaHeight: Double,
                            minTileWidth: Double, minTileHeight: Double, gap: Double) -> Bool {
        let tileWidth = (areaWidth - gap * Double(columns - 1)) / Double(columns)
        let tileHeight = (areaHeight - gap * Double(rows - 1)) / Double(rows)
        return tileWidth >= minTileWidth && tileHeight >= minTileHeight
    }

    /// The shape for `preset`. A fixed preset is used as-is. `auto` picks the smallest fixed preset that
    /// holds every session while its tiles stay usable; if none holds them all, the largest usable one
    /// (the rest go to later pages); if not even one tile is usable, a single tile. Between usable
    /// presets of the same size (1×2 vs 2×1) it takes the one with roomier tiles for this area.
    public static func shape(preset: MissionLayoutPreset, count: Int, areaWidth: Double, areaHeight: Double,
                             minTileWidth: Double, minTileHeight: Double, gap: Double) -> MissionPageShape {
        if let fixed = preset.shape {
            return MissionPageShape(preset: preset, columns: fixed.columns, rows: fixed.rows)
        }
        let usable = MissionLayoutPreset.fixed.filter { candidate in
            guard let grid = candidate.shape else { return false }
            return fits(columns: grid.columns, rows: grid.rows, areaWidth: areaWidth, areaHeight: areaHeight,
                        minTileWidth: minTileWidth, minTileHeight: minTileHeight, gap: gap)
        }
        func capacity(_ preset: MissionLayoutPreset) -> Int { preset.shape.map { $0.columns * $0.rows } ?? 0 }
        /// How far the tighter dimension clears its minimum — bigger is roomier.
        func room(_ preset: MissionLayoutPreset) -> Double {
            guard let grid = preset.shape else { return 0 }
            let tileWidth = (areaWidth - gap * Double(grid.columns - 1)) / Double(grid.columns)
            let tileHeight = (areaHeight - gap * Double(grid.rows - 1)) / Double(grid.rows)
            return min(tileWidth / minTileWidth, tileHeight / minTileHeight)
        }
        let holdingAll = usable.filter { capacity($0) >= count }
        let pool = holdingAll.isEmpty ? usable : holdingAll
        let target = holdingAll.isEmpty ? pool.map(capacity).max() : pool.map(capacity).min()
        let chosen = pool.filter { capacity($0) == target }.max { room($0) < room($1) } ?? .one
        let grid = chosen.shape ?? (1, 1)
        return MissionPageShape(preset: chosen, columns: grid.columns, rows: grid.rows)
    }

    /// The slot (column, row) of the session at `indexOnPage`. Slots keep the preset's exact shape on
    /// every page — a partial page leaves empty slots rather than stretching tiles — so the grid always
    /// looks like its icon and flipping pages never resizes a terminal.
    public static func slot(indexOnPage: Int, shape: MissionPageShape) -> (column: Int, row: Int) {
        let index = max(0, indexOnPage) % max(1, shape.perPage)
        return (index % shape.columns, index / shape.columns)
    }

    /// Empty slots on a page holding `count` sessions (shown as "new session" placeholders).
    public static func emptySlots(count: Int, shape: MissionPageShape) -> Int {
        max(0, shape.perPage - min(max(0, count), shape.perPage))
    }

    /// Number of pages for `count` sessions — at least 1, so an empty grid still has a page 1 of 1.
    public static func pageCount(count: Int, perPage: Int) -> Int {
        guard count > 0, perPage > 0 else { return 1 }
        return (count + perPage - 1) / perPage
    }

    /// The page (0-based) that the session at `index` lands on.
    public static func page(ofIndex index: Int, perPage: Int) -> Int {
        guard perPage > 0 else { return 0 }
        return max(0, index) / perPage
    }

    /// The session indices on `page` (0-based), clamped to `count`.
    public static func range(page: Int, perPage: Int, count: Int) -> Range<Int> {
        let start = min(max(0, page) * perPage, count)
        return start..<min(start + perPage, count)
    }

    /// `page` pulled back into range — e.g. after sessions on the last page closed.
    public static func clampPage(_ page: Int, count: Int, perPage: Int) -> Int {
        min(max(0, page), pageCount(count: count, perPage: perPage) - 1)
    }

    /// The preset one step towards more (`+1`) or fewer (`-1`) tiles, starting from what's on screen
    /// (`resolved` — what `auto` became). Stops at the ends; never returns `auto`.
    public static func step(from resolved: MissionLayoutPreset, by delta: Int) -> MissionLayoutPreset {
        let presets = MissionLayoutPreset.fixed
        let index = presets.firstIndex(of: resolved) ?? 0
        return presets[min(max(0, index + delta), presets.count - 1)]
    }
}
