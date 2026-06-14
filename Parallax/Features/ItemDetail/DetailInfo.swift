import ParallaxJellyfin

/// Everything a detail screen shows below the hero action row and OUTSIDE the season shelf — the
/// overview plus the labeled metadata (Genres, Studios, Cast & Crew) and the fact line (year,
/// runtime, rating, quality). Bundling it in one value lets `DetailInfoSection` (the clamped
/// teaser) and `DetailInfoModal` (the expanded card) render from a single source, and lets Movie
/// and Series build the payload the same way instead of each detail view re-plumbing the fields.
struct DetailInfo: Equatable {
    var title: String
    var tagline: String?
    var overview: String?
    /// Year · runtime · rating · age-rating, plus quality / CC badges — the hero's fact line,
    /// repeated in the card so the expanded view is self-contained.
    var facts: DetailMetadata
    var genres: [String]
    var studios: [String]
    var castAndCrew: [String]

    /// At least one thing worth showing. Gates the whole section so a bare item (nothing at all)
    /// renders nothing — and, on tvOS, doesn't add an empty focusable panel. Includes `facts` and
    /// `tagline`: a title whose only metadata is the fact line still deserves the section (and the
    /// tvOS scroll target), and `teaser` falls back to them so the card is never empty.
    var hasContent: Bool {
        overview?.isEmpty == false
            || tagline?.isEmpty == false
            || !facts.isEmpty
            || !genres.isEmpty || !studios.isEmpty || !castAndCrew.isEmpty
    }

    /// The collapsed teaser line shown in `DetailInfoSection`: the overview blurb, else the
    /// tagline, else the genres, else the fact line — so when `hasContent` is true the card always
    /// shows something above the "More" affordance instead of a lone chevron.
    var teaser: String {
        let blurb = OverviewFormatting.heroBlurb(from: overview ?? "")
        if !blurb.isEmpty { return blurb }
        if let tagline, !tagline.isEmpty { return tagline }
        if !genres.isEmpty { return genres.joined(separator: ", ") }
        return facts.textParts.joined(separator: " · ")
    }

    /// The labeled lists in display order, empty ones dropped — drives the modal's metadata
    /// column so each call site doesn't re-check `isEmpty`. Genres render as chips, the rest as
    /// comma-joined text.
    var fields: [DetailInfoField] {
        [
            DetailInfoField(label: "Genres", values: genres, presentation: .chips),
            DetailInfoField(label: "Studios", values: studios, presentation: .text),
            DetailInfoField(label: "Cast & Crew", values: castAndCrew, presentation: .text),
        ].filter { !$0.values.isEmpty }
    }
}

/// One labeled metadata list (e.g. Genres → [Action, Drama]) rendered as a block in the card.
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
            title: md.movie.title,
            tagline: md.tagline,
            overview: md.movie.overview,
            facts: DetailMetadata(movie: md.movie),
            genres: md.movie.genres,
            studios: md.studios,
            // People is the simplified flat name list; cap it like the old Cast & Crew line did.
            castAndCrew: Array(md.people.prefix(10))
        )
    }

    init(series sd: SeriesDetail) {
        self.init(
            title: sd.series.title,
            tagline: sd.tagline,
            overview: sd.series.overview,
            facts: DetailMetadata(series: sd.series),
            genres: sd.series.genres,
            studios: sd.studios,
            castAndCrew: Array(sd.people.prefix(10))
        )
    }
}

#if DEBUG
extension DetailInfo {
    /// Shared sample for `DetailInfoSection` / `DetailInfoModal` previews.
    static let preview = DetailInfo(
        title: "Blade Runner 2049",
        tagline: "The key to the future is finally unearthed.",
        overview: """
        Thirty years after the events of the first film, a new blade runner, LAPD Officer K, \
        unearths a long-buried secret that has the potential to plunge what's left of society into \
        chaos. K's discovery leads him on a quest to find Rick Deckard, a former LAPD blade runner \
        who has been missing for thirty years.
        """,
        facts: DetailMetadata(textParts: ["2017", "164 min", "★ 8.0", "R"], qualityLabels: ["4K", "HDR"], hasSubtitles: true),
        genres: ["Science Fiction", "Drama", "Thriller", "Mystery"],
        studios: ["Alcon Entertainment", "Columbia Pictures"],
        castAndCrew: ["Ryan Gosling", "Harrison Ford", "Ana de Armas", "Denis Villeneuve"]
    )
}
#endif
