import Foundation

public struct DeviceIdentity: Sendable, Hashable {
    public let client: String
    public let deviceName: String
    public let deviceID: String
    public let version: String

    public init(client: String, deviceName: String, deviceID: String, version: String) {
        self.client = client
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.version = version
    }
}
