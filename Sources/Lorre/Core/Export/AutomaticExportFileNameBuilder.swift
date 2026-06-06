import Foundation

enum AutomaticExportFileNameBuilder {
    static let maximumBaseNameLength = 96

    static func fileName(
        session: SessionManifest,
        transcript: TranscriptDocument,
        template: String,
        now: Date = Date()
    ) -> String {
        let normalizedTemplate = AutomaticMarkdownExportConfiguration.normalizedFileNameTemplate(template)
        let smartTitle = smartTitle(for: transcript) ?? session.displayTitle
        let keywords = keywordTitle(for: transcript, maximumWordCount: 6) ?? smartTitle
        let tokenValues = makeTokenValues(
            session: session,
            transcript: transcript,
            smartTitle: smartTitle,
            keywords: keywords,
            now: now
        )

        var rendered = normalizedTemplate
        for token in tokenValues.keys.sorted(by: { $0.count > $1.count }) {
            rendered = rendered.replacingOccurrences(of: token, with: tokenValues[token] ?? "")
        }
        return sanitizedMarkdownFileName(from: rendered)
    }

    static func previewFileName(template: String, now: Date = Date()) -> String {
        let session = SessionManifest(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            title: "Product Review",
            status: .ready,
            recordedAt: now,
            durationSeconds: 42 * 60,
            recordingSource: .microphoneAndSystemAudio,
            audioFileName: "audio.caf",
            transcriptFileName: "transcript.json"
        )
        let transcript = TranscriptDocument(
            sessionId: session.id,
            languageHint: "nl",
            sourceEngine: "Preview",
            segments: [
                TranscriptSegment(
                    startMs: 0,
                    endMs: 4_000,
                    text: "Vandaag bespreken we de onboarding flow, pricing pagina en openstaande bugs.",
                    speakerId: "S1"
                )
            ],
            speakers: [
                SpeakerProfile.defaultProfile(id: "S1"),
                SpeakerProfile.defaultProfile(id: "S2")
            ]
        )
        return fileName(session: session, transcript: transcript, template: template, now: now)
    }

    private static func makeTokenValues(
        session: SessionManifest,
        transcript: TranscriptDocument,
        smartTitle: String,
        keywords: String,
        now: Date
    ) -> [String: String] {
        [
            "{date}": dateString(now),
            "{time}": timeString(now),
            "{datetime}": dateTimeString(now),
            "{session_title}": session.displayTitle,
            "{keywords}": keywords,
            "{smart_title}": smartTitle,
            "{source}": session.recordingSource.label,
            "{language}": transcript.languageHint ?? "unknown",
            "{duration}": durationToken(session.durationSeconds),
            "{speaker_count}": speakerCountToken(transcript),
            "{session_id_short}": String(session.id.uuidString.prefix(8)).lowercased()
        ]
    }

    private static func smartTitle(for transcript: TranscriptDocument) -> String? {
        let sampledSentences = sampledText(for: transcript)
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for sentence in sampledSentences {
            if let phrase = topicPhrase(from: sentence),
               let title = titleFromOrderedWords(in: phrase, maximumWordCount: 8) {
                return title
            }
        }

        return keywordTitle(for: transcript, maximumWordCount: 8)
    }

    private static func topicPhrase(from sentence: String) -> String? {
        let normalizedSentence = normalizeForMatching(sentence)
        let patterns = [
            "vandaag bespreken we",
            "vandaag gaan we het hebben over",
            "we gaan het hebben over",
            "we gaan praten over",
            "het onderwerp is",
            "de call gaat over",
            "deze call gaat over",
            "dit gesprek gaat over",
            "we bespreken",
            "today we discuss",
            "today we are discussing",
            "today we're discussing",
            "this call is about",
            "the topic is",
            "we are talking about",
            "we're talking about",
            "we will cover",
            "we'll cover"
        ]

        for pattern in patterns {
            guard let range = normalizedSentence.range(of: pattern) else { continue }
            let lowerDistance = normalizedSentence.distance(from: normalizedSentence.startIndex, to: range.upperBound)
            let startIndex = sentence.index(sentence.startIndex, offsetBy: min(lowerDistance, sentence.count))
            let phrase = String(sentence[startIndex...])
            if !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return phrase
            }
        }

        guard normalizedSentence.hasPrefix("agenda") else { return nil }
        if let separator = sentence.firstIndex(where: { $0 == ":" || $0 == "-" }) {
            return String(sentence[sentence.index(after: separator)...])
        }
        return sentence
    }

    private static func keywordTitle(for transcript: TranscriptDocument, maximumWordCount: Int) -> String? {
        let words = significantWords(in: sampledText(for: transcript))
        guard !words.isEmpty else { return nil }

        var stats: [String: (count: Int, firstIndex: Int)] = [:]
        for (index, word) in words.enumerated() {
            if let existing = stats[word] {
                stats[word] = (existing.count + 1, existing.firstIndex)
            } else {
                stats[word] = (1, index)
            }
        }

        let ranked = stats
            .map { word, stat in
                let earlyBoost = max(0, 12 - min(stat.firstIndex, 12))
                let digitBoost = word.contains(where: { $0.isNumber }) ? 2 : 0
                return (word: word, score: (stat.count * 5) + earlyBoost + digitBoost, firstIndex: stat.firstIndex)
            }
            .sorted {
                if $0.score == $1.score {
                    return $0.firstIndex < $1.firstIndex
                }
                return $0.score > $1.score
            }

        let selected = ranked
            .prefix(maximumWordCount)
            .sorted { $0.firstIndex < $1.firstIndex }
            .map(\.word)
        guard !selected.isEmpty else { return nil }
        return selected.joined(separator: " ")
    }

    private static func titleFromOrderedWords(in text: String, maximumWordCount: Int) -> String? {
        let words = significantWords(in: text)
        var selected: [String] = []
        for word in words where !selected.contains(word) {
            selected.append(word)
            if selected.count == maximumWordCount {
                break
            }
        }
        return selected.isEmpty ? nil : selected.joined(separator: " ")
    }

    private static func sampledText(for transcript: TranscriptDocument) -> String {
        let earlySegments = transcript.segments
            .sorted { $0.startMs < $1.startMs }
            .filter { $0.startMs <= 120_000 }
            .prefix(20)

        let selected = earlySegments.isEmpty
            ? transcript.segments.sorted { $0.startMs < $1.startMs }.prefix(20)
            : earlySegments

        return selected
            .map(\.text)
            .joined(separator: " ")
    }

    private static func significantWords(in text: String) -> [String] {
        normalizeForMatching(text)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter(isSignificantWord)
    }

    private static func isSignificantWord(_ word: String) -> Bool {
        let shortAllowed = ["ai", "ui", "ux", "qa", "api", "q1", "q2", "q3", "q4"]
        guard word.count >= 3 || shortAllowed.contains(word) else { return false }
        guard !stopWords.contains(word) else { return false }
        guard !genericCallWords.contains(word) else { return false }
        return true
    }

    private static func sanitizedMarkdownFileName(from renderedTemplate: String) -> String {
        let trimmed = renderedTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseWithoutExtension: String
        if trimmed.lowercased().hasSuffix(".md") {
            baseWithoutExtension = String(trimmed.dropLast(3))
        } else {
            baseWithoutExtension = trimmed
        }

        var output = ""
        var previousWasSeparator = false
        for scalar in transliterated(baseWithoutExtension).unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                output.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                output.append("-")
                previousWasSeparator = true
            }
        }

        var base = output.trimmingCharacters(in: CharacterSet(charactersIn: "-_ ."))
        if base.isEmpty {
            base = "transcript"
        }
        if base.count > maximumBaseNameLength {
            base = String(base.prefix(maximumBaseNameLength))
                .trimmingCharacters(in: CharacterSet(charactersIn: "-_ ."))
        }
        return "\(base).md"
    }

    private static func normalizeForMatching(_ text: String) -> String {
        transliterated(text)
            .lowercased()
    }

    private static func transliterated(_ text: String) -> String {
        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        return mutable as String
    }

    private static func dateString(_ date: Date) -> String {
        dateFormatter("yyyy-MM-dd").string(from: date)
    }

    private static func timeString(_ date: Date) -> String {
        dateFormatter("HH-mm").string(from: date)
    }

    private static func dateTimeString(_ date: Date) -> String {
        dateFormatter("yyyy-MM-dd-HH-mm").string(from: date)
    }

    private static func dateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    private static func durationToken(_ durationSeconds: Double?) -> String {
        guard let durationSeconds, durationSeconds > 0 else { return "0m" }
        let totalMinutes = max(1, Int((durationSeconds / 60).rounded()))
        if totalMinutes < 60 {
            return "\(totalMinutes)m"
        }
        return "\(totalMinutes / 60)h\(String(format: "%02d", totalMinutes % 60))m"
    }

    private static func speakerCountToken(_ transcript: TranscriptDocument) -> String {
        let usedSpeakerIDs = Set(transcript.segments.map { $0.speakerId ?? "UNK" })
        let count = max(usedSpeakerIDs.count, transcript.speakers.isEmpty ? 0 : 1)
        return "\(count)spk"
    }

    private static let genericCallWords: Set<String> = [
        "agenda", "bespreken", "bespreking", "call", "calls", "conversation", "gesprek",
        "meeting", "meetings", "onderwerp", "praten", "talking", "topic"
    ]

    private static let stopWords: Set<String> = [
        "aan", "about", "after", "all", "als", "also", "an", "and", "are", "as", "at",
        "be", "bij", "but", "by", "can", "dat", "de", "den", "der", "dit", "do", "door",
        "dus", "een", "eh", "en", "er", "for", "gaan", "goed", "haar", "had", "has",
        "have", "he", "het", "hier", "hij", "hoe", "i", "if", "in", "is", "it", "ja",
        "je", "jij", "kan", "kun", "la", "le", "let", "like", "maar", "me", "met",
        "mijn", "naar", "nee", "niet", "of", "ok", "oke", "om", "on", "ons", "onze",
        "or", "over", "right", "she", "so", "that", "the", "their", "them", "then",
        "there", "they", "this", "to", "uh", "um", "van", "vandaag", "voor", "was",
        "we", "wel", "we'll", "we're", "were", "wij", "will", "with", "you", "zijn",
        "zo"
    ]
}
