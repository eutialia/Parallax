/// A human-language sort-direction option — a title + SF Symbol describing what a direction MEANS
/// for a field (e.g. "Newest" / `clock` for a date field, "A to Z" / `a.square` for a name). Generic
/// over the source's direction enum so the Jellyfin (`ItemSort.Direction`) and SMB
/// (`SMBBrowseSort.Direction`) sort vocabularies share one shape instead of each re-declaring an
/// identical struct.
struct SortDirectionOption<Direction> {
    let title: String
    let icon: String
    let direction: Direction
}
