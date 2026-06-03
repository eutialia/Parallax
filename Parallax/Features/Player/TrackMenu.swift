import SwiftUI
import ParallaxPlayback
import ParallaxJellyfin

// MARK: - Private primitives

private struct MenuHeader: View {
    let systemImage: String
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: Space.s8) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(Color.secondaryLabel)
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.label)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.tertiaryLabel)
            }
        }
        .padding(.horizontal, Space.s14)
        .padding(.top, Space.s8)
        .padding(.bottom, Space.s8)
    }
}

private struct MenuCheckColumn: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.label)
            }
        }
        .frame(width: 22)
    }
}

private struct AudioStatusBadge: View {
    let isTranscode: Bool
    let transcodeTarget: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(isTranscode ? "Transcode" : "Direct Play")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isTranscode ? Color.label : Color.secondaryLabel)
            if isTranscode, let transcodeTarget {
                Text("→ \(transcodeTarget)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.tertiaryLabel)
            }
        }
    }
}

private struct MenuMiniBadge: View {
    let text: String
    var prominent: Bool = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .tracking(0.3)
            .foregroundStyle(prominent ? Color.label : Color.secondaryLabel)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(Color.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct MenuFootnote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.s8) {
            Image(systemName: "bolt.fill")
                .font(.caption2)
                .foregroundStyle(Color.tertiaryLabel)
            Text(text)
                .font(.caption2)
                .foregroundStyle(Color.tertiaryLabel)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s14)
        .padding(.top, Space.s8)
    }
}

private struct MenuRow<Trailing: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Trailing

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, Space.s12)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    isSelected ? Color.selectionFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Public content views

struct AudioTrackMenu: View {
    let tracks: [AudioTrack]
    let selectedID: TrackID?
    let onSelect: (AudioTrack) -> Void

    private var anyTranscode: Bool { tracks.contains { $0.isTranscode } }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuHeader(
                systemImage: "waveform",
                title: "Audio",
                trailing: "\(tracks.count) track\(tracks.count == 1 ? "" : "s")"
            )
            ForEach(tracks, id: \.id) { track in
                MenuRow(isSelected: track.id == selectedID, action: { onSelect(track) }) {
                    HStack(spacing: Space.s12) {
                        MenuCheckColumn(isSelected: track.id == selectedID)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.displayName)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(Color.label)
                                .lineLimit(1)
                            if let codecLabel = track.codecLabel {
                                Text(codecLabel)
                                    .font(.caption)
                                    .foregroundStyle(Color.secondaryLabel)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: Space.s8)
                        AudioStatusBadge(
                            isTranscode: track.isTranscode,
                            transcodeTarget: track.transcodeTarget
                        )
                    }
                }
            }
            if anyTranscode {
                MenuFootnote(text: "Lossless and surround tracks are transcoded to AAC on this device.")
            }
        }
    }
}

struct SubtitleTrackMenu: View {
    let tracks: [SubtitleTrack]
    let selectedID: TrackID?
    let onSelect: (SubtitleTrack?) -> Void

    private var anyExternal: Bool {
        tracks.contains { ($0.sourceLabel ?? "") == "External" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuHeader(
                systemImage: "captions.bubble",
                title: "Subtitles",
                trailing: "\(tracks.count + 1) options"
            )
            // Off row
            MenuRow(isSelected: selectedID == nil, action: { onSelect(nil) }) {
                HStack(spacing: Space.s12) {
                    MenuCheckColumn(isSelected: selectedID == nil)
                    Text("Off")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.label)
                    Spacer(minLength: 0)
                }
            }
            ForEach(tracks, id: \.id) { track in
                MenuRow(isSelected: track.id == selectedID, action: { onSelect(track) }) {
                    HStack(spacing: Space.s12) {
                        MenuCheckColumn(isSelected: track.id == selectedID)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.displayName)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(Color.label)
                                .lineLimit(1)
                            if let sourceLabel = track.sourceLabel {
                                Text(sourceLabel)
                                    .font(.caption)
                                    .foregroundStyle(Color.secondaryLabel)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: Space.s8)
                        HStack(spacing: 6) {
                            if track.isForced { MenuMiniBadge(text: "Forced", prominent: true) }
                            if track.isSDH { MenuMiniBadge(text: "SDH", prominent: true) }
                            if let formatLabel = track.formatLabel { MenuMiniBadge(text: formatLabel) }
                        }
                    }
                }
            }
            if anyExternal {
                MenuFootnote(text: "External subtitles are matched by filename or fetched automatically.")
            }
        }
    }
}

struct ChapterMenu: View {
    let chapters: [Chapter]
    let onSelect: (Chapter) -> Void

    var body: some View {
        // LazyVStack (not VStack): a movie can carry 30–60 chapters, and the
        // popover's ScrollView eagerly builds+measures every row of a plain VStack
        // on present — the brief hang when opening the chip. Lazy defers off-screen
        // rows. (Audio/Subtitle/Speed stay plain VStacks: a handful of rows each.)
        LazyVStack(alignment: .leading, spacing: 2) {
            MenuHeader(systemImage: "list.bullet", title: "Chapters", trailing: "\(chapters.count)")
            ForEach(chapters) { chapter in
                MenuRow(isSelected: false, action: { onSelect(chapter) }) {
                    HStack(spacing: Space.s12) {
                        Text("\(chapter.index + 1)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Color.tertiaryLabel)
                            .frame(width: 22)
                        Text(chapter.name ?? "Chapter \(chapter.index + 1)")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color.label)
                            .lineLimit(1)
                        Spacer(minLength: Space.s8)
                        Text(Self.timecode(chapter.start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.secondaryLabel)
                    }
                }
            }
        }
    }

    private static func timecode(_ duration: Duration) -> String {
        let total = Int(duration.components.seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

struct SpeedMenu: View {
    let options: [Double]
    let selected: Double
    let onSelect: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuHeader(systemImage: "timer", title: "Playback Speed")
            ForEach(options, id: \.self) { rate in
                MenuRow(isSelected: rate == selected, action: { onSelect(rate) }) {
                    HStack(spacing: Space.s12) {
                        MenuCheckColumn(isSelected: rate == selected)
                        Text(Self.label(rate))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color.label)
                        Spacer(minLength: Space.s8)
                        if rate == 1.0 {
                            Text("Normal")
                                .font(.caption)
                                .foregroundStyle(Color.tertiaryLabel)
                        }
                    }
                }
            }
        }
    }

    /// Shared "1.5×" formatter — also used by the speed chip label so the chip and
    /// the menu can't drift.
    static func label(_ rate: Double) -> String {
        let s = String(format: rate == rate.rounded() ? "%.0f" : "%g", rate)
        return s + "×"
    }
}

// MARK: - Previews

#Preview("Track menus", traits: .sizeThatFitsLayout) {
    VStack(spacing: 24) {
        AudioTrackMenu(
            tracks: [
                AudioTrack(
                    id: .jellyfinStream(1),
                    displayName: "English",
                    languageCode: "eng",
                    codecLabel: "TrueHD · 7.1",
                    isTranscode: true,
                    transcodeTarget: "AAC · 7.1"
                ),
                AudioTrack(
                    id: .jellyfinStream(2),
                    displayName: "English",
                    languageCode: "eng",
                    codecLabel: "AAC · Stereo",
                    isTranscode: false,
                    transcodeTarget: nil
                ),
            ],
            selectedID: .jellyfinStream(1),
            onSelect: { _ in }
        )
        SubtitleTrackMenu(
            tracks: [
                SubtitleTrack(
                    id: .jellyfinStream(3),
                    displayName: "English",
                    languageCode: "eng",
                    isForced: false,
                    sourceLabel: "External",
                    formatLabel: "SRT",
                    isSDH: true
                ),
                SubtitleTrack(
                    id: .jellyfinStream(4),
                    displayName: "Spanish",
                    languageCode: "spa",
                    isForced: true,
                    sourceLabel: "Embedded",
                    formatLabel: "ASS",
                    isSDH: false
                ),
            ],
            selectedID: .jellyfinStream(3),
            onSelect: { _ in }
        )
    }
    .padding()
    .frame(width: 360)
    .background(Color.background)
    .preferredColorScheme(.dark)
}
