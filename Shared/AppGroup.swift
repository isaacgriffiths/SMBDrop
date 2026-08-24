import Foundation

enum SMBDropAppGroup {
    static let identifier = "group.com.isaacgriffiths.smbdrop"
}

enum SMBDropProcess {
    /// Shared by every outbox user in this process, but changes after a crash or relaunch.
    static let sessionID = UUID()
}
