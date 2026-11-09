/// The remote player's HUD: which surface owns the remote (`PlayerHUDState`), plus what the user
/// is doing inside the full chrome. The chrome's controls are mounted only while `state.chromeUp`,
/// so a fold takes their panels with it — the interaction cannot outlive the chrome.
public struct PlayerTVHUD: Equatable, Sendable {
    public var state: PlayerHUDState {
        didSet { if !state.chromeUp { interaction = PlayerHUDInteraction() } }
    }
    public var interaction = PlayerHUDInteraction()

    public init(state: PlayerHUDState) { self.state = state }
}
