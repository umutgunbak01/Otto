import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Service that generates a text-based PDF from selected search results,
/// suitable as a context resource for Claude or other AI agents.
enum PDFExportService {

    // MARK: - Public API

    /// Generates a PDF `Data` blob from an array of search results.
    /// Each result becomes a section with title, metadata, and full content.
    static func generatePDF(
        from results: [UniversalSearchResult],
        title: String = "Otto Export"
    ) -> Data {
        let pageWidth: CGFloat = 612   // US Letter
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 50
        let contentWidth = pageWidth - margin * 2

        let mutableData = NSMutableData()

        #if os(macOS)
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let consumer = CGDataConsumer(data: mutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }

        var cursor: CGFloat = pageHeight - margin  // top of content area (PDF origin is bottom-left)

        func beginPage() {
            var box = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
            context.beginPage(mediaBox: &box)
            cursor = pageHeight - margin
        }

        func endPage() {
            context.endPage()
        }

        func ensureSpace(_ needed: CGFloat) {
            if cursor - needed < margin {
                endPage()
                beginPage()
            }
        }

        // Attribute helpers
        let titleFont = NSFont.systemFont(ofSize: 22, weight: .bold)
        let headingFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let metaFont = NSFont.systemFont(ofSize: 10, weight: .regular)
        let bodyFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        let separatorColor = NSColor.separatorColor

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor.labelColor
        ]
        let headingAttrs: [NSAttributedString.Key: Any] = [
            .font: headingFont,
            .foregroundColor: NSColor.labelColor
        ]
        let metaAttrs: [NSAttributedString.Key: Any] = [
            .font: metaFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: {
                let ps = NSMutableParagraphStyle()
                ps.lineSpacing = 3
                return ps
            }()
        ]

        // --- Draw functions ---

        func drawString(_ string: String, attributes: [NSAttributedString.Key: Any], maxWidth: CGFloat) -> CGFloat {
            let attrStr = NSAttributedString(string: string, attributes: attributes)
            let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
            let suggestedSize = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                CFRange(location: 0, length: attrStr.length),
                nil,
                CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                nil
            )
            let textHeight = ceil(suggestedSize.height)
            ensureSpace(textHeight + 4)

            let textRect = CGRect(x: margin, y: cursor - textHeight, width: maxWidth, height: textHeight)
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attrStr.length), path, nil)
            context.saveGState()
            CTFrameDraw(frame, context)
            context.restoreGState()

            cursor -= textHeight + 4
            return textHeight
        }

        func drawSeparator() {
            ensureSpace(12)
            cursor -= 6
            context.setStrokeColor(separatorColor.cgColor)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: margin, y: cursor))
            context.addLine(to: CGPoint(x: pageWidth - margin, y: cursor))
            context.strokePath()
            cursor -= 6
        }

        // --- Build PDF ---

        beginPage()

        // Document title
        _ = drawString(title, attributes: titleAttrs, maxWidth: contentWidth)

        // Subtitle
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short
        let subtitle = "Exported \(dateFormatter.string(from: Date())) • \(results.count) item\(results.count == 1 ? "" : "s")"
        _ = drawString(subtitle, attributes: metaAttrs, maxWidth: contentWidth)
        cursor -= 8

        drawSeparator()

        // Each result as a section
        for (index, result) in results.enumerated() {
            // Section heading: "[Type] Title"
            let sectionTitle = "[\(result.contentType.displayName)] \(result.title)"
            ensureSpace(40)
            _ = drawString(sectionTitle, attributes: headingAttrs, maxWidth: contentWidth)

            // Metadata line
            var metaParts: [String] = []
            if let sub = result.subtitle, !sub.isEmpty { metaParts.append(sub) }
            let df = DateFormatter()
            df.dateFormat = "d MMM yyyy, HH:mm"
            metaParts.append(df.string(from: result.date))
            if result.isArchived { metaParts.append("(Archived)") }
            let metaLine = metaParts.joined(separator: " • ")
            _ = drawString(metaLine, attributes: metaAttrs, maxWidth: contentWidth)
            cursor -= 2

            // Full content
            let fullContent = getFullContent(for: result)
            if !fullContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Split into chunks to avoid massive single-frame rendering
                let lines = fullContent.components(separatedBy: .newlines)
                var chunk = ""
                for line in lines {
                    if chunk.count + line.count > 2000 {
                        _ = drawString(chunk, attributes: bodyAttrs, maxWidth: contentWidth)
                        chunk = ""
                    }
                    chunk += (chunk.isEmpty ? "" : "\n") + line
                }
                if !chunk.isEmpty {
                    _ = drawString(chunk, attributes: bodyAttrs, maxWidth: contentWidth)
                }
            }

            // Separator between items
            if index < results.count - 1 {
                drawSeparator()
            }
        }

        endPage()
        context.closePDF()

        return mutableData as Data

        #else
        // iOS: use UIGraphicsPDFRenderer
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

        let data = renderer.pdfData { ctx in
            var cursor: CGFloat = margin

            func beginPage() {
                ctx.beginPage()
                cursor = margin
            }

            func ensureSpace(_ needed: CGFloat) {
                if cursor + needed > pageHeight - margin {
                    beginPage()
                }
            }

            let titleFont = UIFont.systemFont(ofSize: 22, weight: .bold)
            let headingFont = UIFont.systemFont(ofSize: 14, weight: .semibold)
            let metaFont = UIFont.systemFont(ofSize: 10, weight: .regular)
            let bodyFont = UIFont.systemFont(ofSize: 11, weight: .regular)

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: titleFont,
                .foregroundColor: UIColor.label
            ]
            let headingAttrs: [NSAttributedString.Key: Any] = [
                .font: headingFont,
                .foregroundColor: UIColor.label
            ]
            let metaAttrs: [NSAttributedString.Key: Any] = [
                .font: metaFont,
                .foregroundColor: UIColor.secondaryLabel
            ]
            let bodyAttrs: [NSAttributedString.Key: Any] = [
                .font: bodyFont,
                .foregroundColor: UIColor.label
            ]

            func drawString(_ string: String, attributes: [NSAttributedString.Key: Any]) -> CGFloat {
                let attrStr = NSAttributedString(string: string, attributes: attributes)
                let rect = CGRect(x: margin, y: cursor, width: contentWidth, height: .greatestFiniteMagnitude)
                let boundingRect = attrStr.boundingRect(with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                let height = ceil(boundingRect.height)
                ensureSpace(height + 4)
                attrStr.draw(in: CGRect(x: margin, y: cursor, width: contentWidth, height: height))
                cursor += height + 4
                return height
            }

            func drawSeparator() {
                ensureSpace(12)
                cursor += 6
                let path = UIBezierPath()
                path.move(to: CGPoint(x: margin, y: cursor))
                path.addLine(to: CGPoint(x: pageWidth - margin, y: cursor))
                UIColor.separator.setStroke()
                path.lineWidth = 0.5
                path.stroke()
                cursor += 6
            }

            beginPage()

            _ = drawString(title, attributes: titleAttrs)

            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .long
            dateFormatter.timeStyle = .short
            let subtitle = "Exported \(dateFormatter.string(from: Date())) • \(results.count) item\(results.count == 1 ? "" : "s")"
            _ = drawString(subtitle, attributes: metaAttrs)
            cursor += 8
            drawSeparator()

            for (index, result) in results.enumerated() {
                let sectionTitle = "[\(result.contentType.displayName)] \(result.title)"
                ensureSpace(40)
                _ = drawString(sectionTitle, attributes: headingAttrs)

                var metaParts: [String] = []
                if let sub = result.subtitle, !sub.isEmpty { metaParts.append(sub) }
                let df = DateFormatter()
                df.dateFormat = "d MMM yyyy, HH:mm"
                metaParts.append(df.string(from: result.date))
                if result.isArchived { metaParts.append("(Archived)") }
                _ = drawString(metaParts.joined(separator: " • "), attributes: metaAttrs)

                let fullContent = getFullContent(for: result)
                if !fullContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let lines = fullContent.components(separatedBy: .newlines)
                    var chunk = ""
                    for line in lines {
                        if chunk.count + line.count > 2000 {
                            _ = drawString(chunk, attributes: bodyAttrs)
                            chunk = ""
                        }
                        chunk += (chunk.isEmpty ? "" : "\n") + line
                    }
                    if !chunk.isEmpty {
                        _ = drawString(chunk, attributes: bodyAttrs)
                    }
                }

                if index < results.count - 1 {
                    drawSeparator()
                }
            }
        }

        return data
        #endif
    }

    /// Saves the PDF to a temporary file and returns the URL.
    static func exportToTempFile(
        from results: [UniversalSearchResult],
        title: String = "Otto Export"
    ) -> URL? {
        let data = generatePDF(from: results, title: title)
        guard !data.isEmpty else { return nil }

        let fileName = sanitizeFileName(title) + ".pdf"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            try data.write(to: tempURL)
            return tempURL
        } catch {
            print("[PDFExport] Failed to write PDF: \(error)")
            return nil
        }
    }

    // MARK: - Content extraction

    private static func getFullContent(for result: UniversalSearchResult) -> String {
        if let todo = result.todo {
            var parts = [todo.title]
            if !todo.description.isEmpty { parts.append(todo.description) }
            if let due = todo.dueDate {
                let df = DateFormatter()
                df.dateFormat = "d MMM yyyy"
                parts.append("Due: \(df.string(from: due))")
            }
            parts.append("Priority: \(todo.priority.rawValue)")
            if todo.isCompleted { parts.append("Status: Completed") }
            if !todo.subTasks.isEmpty {
                parts.append("Subtasks:")
                for sub in todo.subTasks {
                    parts.append("  \(sub.isCompleted ? "☑" : "☐") \(sub.title)")
                }
            }
            return parts.joined(separator: "\n")
        } else if let note = result.note {
            var parts = [note.title]
            parts.append("Category: \(note.primaryCategory.rawValue)")
            if !note.content.isEmpty { parts.append(note.content) }
            if !note.researchPrompt.isEmpty { parts.append("\nResearch Prompt:\n\(note.researchPrompt)") }
            return parts.joined(separator: "\n")
        } else if let idea = result.idea {
            var parts = [idea.title]
            parts.append("Category: \(idea.primaryCategory.rawValue) • Status: \(idea.status.rawValue)")
            if !idea.content.isEmpty { parts.append(idea.content) }
            if !idea.researchPrompt.isEmpty { parts.append("\nResearch:\n\(idea.researchPrompt)") }
            if !idea.validationPrompt.isEmpty { parts.append("\nValidation:\n\(idea.validationPrompt)") }
            return parts.joined(separator: "\n")
        } else if let reminder = result.reminder {
            var parts = [reminder.title]
            let df = DateFormatter()
            df.dateFormat = "d MMM yyyy, HH:mm"
            parts.append("Reminder: \(df.string(from: reminder.reminderDate))")
            if reminder.isTriggered { parts.append("Status: Triggered") }
            if reminder.isCompleted { parts.append("Status: Completed") }
            return parts.joined(separator: "\n")
        } else if let bookmark = result.bookmark {
            var parts = [bookmark.title]
            parts.append("URL: \(bookmark.url)")
            parts.append("Type: \(bookmark.mediaType.rawValue)")
            if !bookmark.description.isEmpty { parts.append(bookmark.description) }
            if let og = bookmark.ogDescription, !og.isEmpty { parts.append(og) }
            return parts.joined(separator: "\n")
        } else if let meeting = result.meeting {
            var parts = [meeting.title]
            let df = DateFormatter()
            df.dateFormat = "d MMM yyyy, HH:mm"
            parts.append("Date: \(df.string(from: meeting.meetingDate))")
            if !meeting.participants.isEmpty { parts.append("Participants: \(meeting.participants.joined(separator: ", "))") }
            if !meeting.overview.isEmpty { parts.append("\nOverview:\n\(meeting.overview)") }
            if !meeting.content.isEmpty { parts.append("\nTranscript/Content:\n\(meeting.content)") }
            if !meeting.actionItems.isEmpty { parts.append("\nAction Items:\n\(meeting.actionItems)") }
            return parts.joined(separator: "\n")
        } else if let email = result.email {
            var parts = ["Subject: \(email.subject)"]
            parts.append("From: \(email.displaySender)")
            if !email.recipients.isEmpty { parts.append("To: \(email.recipients.joined(separator: ", "))") }
            let df = DateFormatter()
            df.dateFormat = "d MMM yyyy, HH:mm"
            parts.append("Date: \(df.string(from: email.receivedDate))")
            if !email.body.isEmpty { parts.append("\n\(email.body)") }
            return parts.joined(separator: "\n")
        } else if let event = result.calendarEvent {
            var parts = [event.title]
            if let desc = event.description, !desc.isEmpty { parts.append(desc) }
            if let loc = event.location, !loc.isEmpty { parts.append("Location: \(loc)") }
            return parts.joined(separator: "\n")
        } else if let connection = result.connection {
            var parts = [connection.fullName]
            if !connection.headline.isEmpty { parts.append(connection.headline) }
            if !connection.company.isEmpty { parts.append("Company: \(connection.company)") }
            if !connection.location.isEmpty { parts.append("Location: \(connection.location)") }
            if !connection.notes.isEmpty { parts.append("\nNotes:\n\(connection.notes)") }
            if !connection.tags.isEmpty { parts.append("Tags: \(connection.tags.joined(separator: ", "))") }
            return parts.joined(separator: "\n")
        } else if let file = result.file {
            var parts = [file.name]
            parts.append("Type: \(file.fileType.displayName) • Size: \(file.formattedSize)")
            if !file.notes.isEmpty { parts.append("\nNotes:\n\(file.notes)") }
            if let text = file.extractedText, !text.isEmpty { parts.append("\nExtracted Text:\n\(text)") }
            return parts.joined(separator: "\n")
        } else if let post = result.xPost {
            var parts = ["@\(post.authorUsername) (\(post.authorDisplayName))"]
            parts.append(post.text)
            parts.append("Likes: \(post.likeCount) • Reposts: \(post.retweetCount)")
            return parts.joined(separator: "\n")
        } else if let follower = result.xFollower {
            var parts = ["\(follower.displayName) (@\(follower.username))"]
            if !follower.bio.isEmpty { parts.append(follower.bio) }
            parts.append("Followers: \(follower.followersCount) • Following: \(follower.followingCount)")
            return parts.joined(separator: "\n")
        } else if let dm = result.xDirectMessage {
            var parts = ["From: \(dm.senderDisplayName) (@\(dm.senderUsername))"]
            parts.append(dm.text)
            return parts.joined(separator: "\n")
        }
        return result.title
    }

    private static func sanitizeFileName(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let sanitized = name.components(separatedBy: invalidChars).joined(separator: "_")
        return sanitized.isEmpty ? "brain_export" : sanitized
    }
}
