import Foundation

public enum AtlasResources {
  public static var bundle: Bundle {
    #if SWIFT_PACKAGE
      return .module
    #else
      return Bundle(for: ResourceLocator.self)
    #endif
  }
}
private final class ResourceLocator {}
