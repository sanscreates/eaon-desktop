import AppKit

enum BrandLogoLoader {
    private static let bundle: Bundle = {
        if let url = Bundle.main.url(forResource: "Eaon-desktop_Eaon-desktop", withExtension: "bundle"),
           let resourceBundle = Bundle(url: url) {
            return resourceBundle
        }
        return Bundle.module
    }()

    private static var cache: [String: NSImage] = [:]

    /// Vector marks (verified real logos sourced as SVG) alongside the
    /// original raster set — checked first since .svg stays crisp at any
    /// display scale, matching NSImage's native SVG rendering support.
    private static let extensions = ["svg", "png"]

    static func image(named name: String) -> NSImage? {
        if let cached = cache[name] {
            return cached
        }

        for ext in extensions {
            if let url = bundle.url(forResource: name, withExtension: ext),
               let image = NSImage(contentsOf: url) {
                cache[name] = image
                return image
            }
        }

        let fallback = bundle.image(forResource: NSImage.Name(name))
        if let fallback { cache[name] = fallback }
        return fallback
    }
}
