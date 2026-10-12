import ParallaxJellyfin
import ParallaxCore

/// Everything the detail page's open-ledger metadata section shows below the hero and OUTSIDE the
/// season shelf — the overview/tagline plus the labeled ledger (Genres, Director, Studios, Cast &
/// Crew). Bundling it in one value lets `DetailMetadataSection` render from a single source, and
/// lets Movie and Series build the payload the same way instead of each detail view re-plumbing the
/// fields. The fact line (year · runtime · rating · quality) lives in the hero only — it is not
/// repeated here.
public nonisolated struct DetailInfo: Equatable {
    /// The item's name. Not rendered on the page (the hero already carries it) — it heads the tvOS
    /// overview reading panel, which covers the hero and would otherwise be an unattributed wall
    /// of prose.
    public var title: String
    public var tagline: String?
    public var overview: String?
    public var genres: [String]
    public var directors: [String]
    public var studios: [String]
    public var castAndCrew: [String]

    public init(
        title: String,
        tagline: String?,
        overview: String?,
        genres: [String],
        directors: [String],
        studios: [String],
        castAndCrew: [String]
    ) {
        self.title = title
        self.tagline = tagline
        self.overview = overview
        self.genres = genres
        self.directors = directors
        self.studios = studios
        self.castAndCrew = castAndCrew
    }

    /// At least one thing worth showing. Gates the whole section so a bare item (nothing at all)
    /// renders nothing — and, on tvOS, doesn't add an empty focusable region. Includes `tagline`: a
    /// title whose only prose is the tagline still deserves the section (and the tvOS scroll target).
    public var hasContent: Bool {
        overview?.isEmpty == false
            || tagline?.isEmpty == false
            || !genres.isEmpty || !directors.isEmpty || !studios.isEmpty || !castAndCrew.isEmpty
    }

    /// The labeled lists in display order, empty ones dropped — drives the ledger so each call site
    /// doesn't re-check `isEmpty`. Genres render as chips, the rest as comma-joined text. The label
    /// stays singular "Director" per the design even when several are joined.
    public var fields: [DetailInfoField] {
        [
            DetailInfoField(label: "Genres", values: genres, presentation: .chips),
            DetailInfoField(label: "Director", values: directors, presentation: .text),
            DetailInfoField(label: "Studios", values: studios, presentation: .text),
            DetailInfoField(label: "Cast & Crew", values: castAndCrew, presentation: .text),
        ].filter { !$0.values.isEmpty }
    }
}

/// One labeled metadata list (e.g. Genres → [Action, Drama]) rendered as a block in the ledger.
public nonisolated struct DetailInfoField: Identifiable, Equatable {
    public enum Presentation { case chips, text }
    public var id: String { label }
    public var label: String
    public var values: [String]
    public var presentation: Presentation
}

nonisolated extension DetailInfo {
    public init(movie md: MovieDetail) {
        self.init(
            title: md.movie.title,
            tagline: md.tagline,
            overview: md.movie.overview,
            genres: md.movie.genres,
            directors: md.directors,
            studios: md.studios,
            // People is the simplified flat name list; drop anyone already named on the Director row
            // so a director-who-also-acts doesn't appear twice, then cap it like the old line did.
            castAndCrew: Array(md.people.filter { !md.directors.contains($0) }.prefix(10))
        )
    }

    public init(series sd: SeriesDetail) {
        self.init(
            title: sd.series.title,
            tagline: sd.tagline,
            overview: sd.series.overview,
            genres: sd.series.genres,
            // Series carry per-episode directors, not a single show director — no Director row.
            directors: [],
            studios: sd.studios,
            castAndCrew: Array(sd.people.prefix(10))
        )
    }
}
