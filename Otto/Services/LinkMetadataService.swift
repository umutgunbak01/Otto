import Foundation
#if canImport(LinkPresentation)
import LinkPresentation
#endif

/// Fetches Open Graph metadata (image, description, favicon, site name) from URLs
actor LinkMetadataService {
    static let shared = LinkMetadataService()

    struct LinkMetadata {
        var ogImageUrl: String?
        var ogDescription: String?
        var faviconUrl: String?
        var siteName: String?
        var title: String?
    }

    /// Fetch OG metadata by parsing the HTML of the given URL
    func fetchMetadata(for urlString: String) async -> LinkMetadata? {
        guard let url = URL(string: urlString) else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            // Pretend to be a browser so sites serve full HTML with OG tags
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            // Try UTF-8 first, then Latin1
            let html: String
            if let utf8 = String(data: data, encoding: .utf8) {
                html = utf8
            } else if let latin1 = String(data: data, encoding: .isoLatin1) {
                html = latin1
            } else {
                return nil
            }

            return parseOGTags(from: html, baseURL: url)
        } catch {
            print("LinkMetadata fetch error for \(urlString): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - HTML Parsing

    private func parseOGTags(from html: String, baseURL: URL) -> LinkMetadata {
        var metadata = LinkMetadata()

        // og:image
        metadata.ogImageUrl = extractMetaContent(from: html, property: "og:image")
            ?? extractMetaContent(from: html, property: "twitter:image")
            ?? extractMetaContent(from: html, name: "twitter:image")

        // og:description
        metadata.ogDescription = extractMetaContent(from: html, property: "og:description")
            ?? extractMetaContent(from: html, name: "description")
            ?? extractMetaContent(from: html, property: "twitter:description")

        // og:site_name
        metadata.siteName = extractMetaContent(from: html, property: "og:site_name")

        // og:title (fallback for display)
        metadata.title = extractMetaContent(from: html, property: "og:title")
            ?? extractMetaContent(from: html, property: "twitter:title")

        // Favicon — look for <link rel="icon"> or construct from domain
        metadata.faviconUrl = extractFaviconUrl(from: html, baseURL: baseURL)

        // Make relative image URLs absolute
        if let imageUrl = metadata.ogImageUrl, !imageUrl.hasPrefix("http") {
            if imageUrl.hasPrefix("//") {
                metadata.ogImageUrl = "https:" + imageUrl
            } else if imageUrl.hasPrefix("/") {
                metadata.ogImageUrl = "\(baseURL.scheme ?? "https")://\(baseURL.host ?? "")\(imageUrl)"
            }
        }

        return metadata
    }

    /// Extract content from <meta property="X" content="Y"> or <meta name="X" content="Y">
    private func extractMetaContent(from html: String, property: String? = nil, name: String? = nil) -> String? {
        // Build pattern to match meta tags
        // <meta property="og:image" content="https://...">
        // <meta name="description" content="...">
        let attrName: String
        let attrValue: String

        if let property = property {
            attrName = "property"
            attrValue = property
        } else if let name = name {
            attrName = "name"
            attrValue = name
        } else {
            return nil
        }

        // Case-insensitive regex matching both orderings:
        // <meta property="X" content="Y"> and <meta content="Y" property="X">
        let patterns = [
            "<meta[^>]*\(attrName)=[\"']\(attrValue)[\"'][^>]*content=[\"']([^\"']*)[\"'][^>]*/?>",
            "<meta[^>]*content=[\"']([^\"']*)[\"'][^>]*\(attrName)=[\"']\(attrValue)[\"'][^>]*/?>",
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let value = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return value
                }
            }
        }

        return nil
    }

    /// Extract favicon URL from <link rel="icon" href="..."> or use Google's favicon service
    private func extractFaviconUrl(from html: String, baseURL: URL) -> String? {
        // Look for <link rel="icon" href="..."> or <link rel="shortcut icon" href="...">
        let patterns = [
            "<link[^>]*rel=[\"'](?:shortcut )?icon[\"'][^>]*href=[\"']([^\"']*)[\"'][^>]*/?>",
            "<link[^>]*href=[\"']([^\"']*)[\"'][^>]*rel=[\"'](?:shortcut )?icon[\"'][^>]*/?>",
            "<link[^>]*rel=[\"']apple-touch-icon[\"'][^>]*href=[\"']([^\"']*)[\"'][^>]*/?>",
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                var faviconPath = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !faviconPath.isEmpty {
                    // Make absolute
                    if faviconPath.hasPrefix("//") {
                        faviconPath = "https:" + faviconPath
                    } else if faviconPath.hasPrefix("/") {
                        faviconPath = "\(baseURL.scheme ?? "https")://\(baseURL.host ?? "")\(faviconPath)"
                    } else if !faviconPath.hasPrefix("http") {
                        faviconPath = "\(baseURL.scheme ?? "https")://\(baseURL.host ?? "")/\(faviconPath)"
                    }
                    return faviconPath
                }
            }
        }

        // Fallback: Google's favicon service
        if let host = baseURL.host {
            return "https://www.google.com/s2/favicons?domain=\(host)&sz=64"
        }

        return nil
    }
}
