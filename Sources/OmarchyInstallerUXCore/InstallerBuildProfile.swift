#if os(macOS)
  import Foundation
  import OmarchyAppleInstallerTrustCore

  /// Private capability and state isolation are separate from encryption choice.
  public enum InstallerBuildProfile: Equatable, Sendable {
    case standard
    case privatePlain
    case privateLimine
    /// For bring-up teams: its sealed catalog may admit Macs the public
    /// catalogs don't, so its state never mixes with theirs.
    case developer

    public static var current: Self {
      resolve(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    public static func resolve(infoDictionary: [String: Any]) -> Self {
      // Preserve the restrictive legacy flag if an invalid bundle contains both.
      if infoDictionary["OmarchyPrivatePlainTest"] as? Bool == true {
        return .privatePlain
      }
      if infoDictionary["OmarchyPrivateLimineTest"] as? Bool == true {
        return .privateLimine
      }
      if infoDictionary["OmarchyDeveloperBuild"] as? Bool == true {
        return .developer
      }
      return .standard
    }

    /// Developer (J773g bring-up) builds install unencrypted: Omarchy's first-boot encryption has
    /// not been exercised on the M4 mini (andreinita21/OmarchyM4Mini docs/j773g-install.md), and a
    /// failed conversion on a screen that lights only once the kernel's display driver starts
    /// leaves nothing to read. Encryption can be enabled after the first boot.
    public var allowsEncryption: Bool { self != .privatePlain && self != .developer }
    public var showsReleaseChannels: Bool { self == .standard }

    public var workspaceName: String {
      switch self {
      case .standard: InstallerProductIdentity.appIdentifier
      case .privatePlain: InstallerProductIdentity.appIdentifier + ".private-m3-20260922"
      case .privateLimine: InstallerProductIdentity.appIdentifier + ".private-limine-20260922"
      case .developer: InstallerProductIdentity.appIdentifier + ".developer"
      }
    }

    public var startupSequence: String {
      switch self {
      case .standard, .privateLimine, .developer: "m1n1 → U-Boot → Limine → Omarchy"
      case .privatePlain: "m1n1 → U-Boot → GRUB → Omarchy"
      }
    }
  }
#endif
