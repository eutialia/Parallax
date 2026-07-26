import Foundation
import JellyfinAPI
import ParallaxCore

extension UserItemDataDto {
    func toUserItemData() -> UserItemData {
        UserItemData(
            played: isPlayed ?? false,
            playbackPositionTicks: Int64(playbackPositionTicks ?? 0),
            playCount: playCount ?? 0,
            isFavorite: isFavorite ?? false,
            lastPlayedDate: lastPlayedDate
        )
    }
}

extension UserItemData {
    static let absent = UserItemData(played: false, playbackPositionTicks: 0, playCount: 0, isFavorite: false)
}
