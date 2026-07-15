import ParallaxJellyfin
import ParallaxCore

/// Everything the detail page's open-ledger metadata section shows below the hero and OUTSIDE the
/// season shelf — the overview/tagline plus the labeled ledger (Genres, Director, Studios, Cast &
/// Crew). Bundling it in one value lets `DetailMetadataSection` render from a single source, and
/// lets Movie and Series build the payload the same way instead of each detail view re-plumbing the
/// fields. The fact line (year · runtime · rating · quality) lives in the hero only — it is not
/// repeated here.
struct DetailInfo: Equatable {
    var tagline: String?
    var overview: String?
    var genres: [String]
    var directors: [String]
    var studios: [String]
    var castAndCrew: [String]

    /// At least one thing worth showing. Gates the whole section so a bare item (nothing at all)
    /// renders nothing — and, on tvOS, doesn't add an empty focusable region. Includes `tagline`: a
    /// title whose only prose is the tagline still deserves the section (and the tvOS scroll target).
    var hasContent: Bool {
        overview?.isEmpty == false
            || tagline?.isEmpty == false
            || !genres.isEmpty || !directors.isEmpty || !studios.isEmpty || !castAndCrew.isEmpty
    }

    /// The labeled lists in display order, empty ones dropped — drives the ledger so each call site
    /// doesn't re-check `isEmpty`. Genres render as chips, the rest as comma-joined text. The label
    /// stays singular "Director" per the design even when several are joined.
    var fields: [DetailInfoField] {
        [
            DetailInfoField(label: "Genres", values: genres, presentation: .chips),
            DetailInfoField(label: "Director", values: directors, presentation: .text),
            DetailInfoField(label: "Studios", values: studios, presentation: .text),
            DetailInfoField(label: "Cast & Crew", values: castAndCrew, presentation: .text),
        ].filter { !$0.values.isEmpty }
    }
}

/// One labeled metadata list (e.g. Genres → [Action, Drama]) rendered as a block in the ledger.
struct DetailInfoField: Identifiable, Equatable {
    enum Presentation { case chips, text }
    var id: String { label }
    var label: String
    var values: [String]
    var presentation: Presentation
}

extension DetailInfo {
    init(movie md: MovieDetail) {
        self.init(
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

    init(series sd: SeriesDetail) {
        self.init(
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

#if DEBUG
extension DetailInfo {
    /// Shared sample for `DetailMetadataSection` previews.
    static let preview = DetailInfo(
        tagline: "The key to the future is finally unearthed.",
        // Two paragraphs on purpose: the detail overview must render Jellyfin's `\n` breaks in
        // BOTH clamp states (the collapsed text is no longer flattened).
        overview: """
        Thirty years after the events of the first film, a new blade runner, LAPD Officer K, \
        unearths a long-buried secret that has the potential to plunge what's left of society into \
        chaos. K's discovery leads him on a quest to find Rick Deckard, a former LAPD blade runner \
        who has been missing for thirty years.

        Officer K's search forces him to question what it means to be human — and to whom the \
        future belongs.
        """,
        genres: ["Science Fiction", "Drama", "Thriller", "Mystery"],
        directors: ["Denis Villeneuve"],
        studios: ["Alcon Entertainment", "Columbia Pictures"],
        castAndCrew: ["Ryan Gosling", "Harrison Ford", "Ana de Armas"]
    )
}
#endif
