import Foundation

extension URL {
    // TOS: do not proxy media through an external cache (c.tonapi.io). Load the
    // source URL directly so no third-party service sees what the user views.
    var proxyURL: URL? {
        return self
    }
}
