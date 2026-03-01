import Foundation

enum LastEditedField {
    case weight
    case reps
}

enum VoiceCommand: Equatable {
    case setWeight(Double)
    case setReps(Int)
    case done
    case doneWithReps(Int)
    case next
    case previous
    case rest(Int)
    case stopRest
    case undo
    case clear
    case switchExercise(String)
}

enum ParsedCommand: Equatable {
    case recognized(VoiceCommand)
    case ambiguousNumber(Int)
    case unrecognized
}

enum ParseConfidence: Equatable {
    case high
    case medium
    case low
}

struct ParseInterpretation: Equatable {
    let result: ParsedCommand
    let normalizedPhrase: String
    let confidence: ParseConfidence
}

struct CommandParser {
    private let aliasToCanonical: [String: String] = [
        "wait": "weight",
        "way": "weight",
        "weights": "weight",
        "rep": "reps",
        "repetition": "reps",
        "repetitions": "reps",
        "prev": "previous",
        "mins": "minutes",
        "min": "minutes",
        "sec": "seconds",
        "secs": "seconds",
        "kilo": "kg",
        "kilos": "kg"
    ]

    private let fuzzyVocabulary: Set<String> = [
        "weight", "reps", "done", "next", "previous", "rest", "stop", "end", "undo", "clear", "exercise", "kg", "minutes", "seconds"
    ]
    
    private let spokenNumberTokens: [String: Int] = [
        "zero": 0,
        "oh": 0,
        "one": 1,
        "won": 1,
        "two": 2,
        "to": 2,
        "too": 2,
        "three": 3,
        "four": 4,
        "for": 4,
        "five": 5,
        "six": 6,
        "seven": 7,
        "eight": 8,
        "ate": 8,
        "nine": 9,
        "ten": 10,
        "eleven": 11,
        "twelve": 12,
        "thirteen": 13,
        "fourteen": 14,
        "fifteen": 15,
        "sixteen": 16,
        "seventeen": 17,
        "eighteen": 18,
        "nineteen": 19,
        "twenty": 20
    ]

    func parse(_ phrase: String, lastEditedField: LastEditedField?) -> ParsedCommand {
        interpret(phrase, lastEditedField: lastEditedField).result
    }
    
    func normalizeForMatching(_ phrase: String) -> String {
        normalizePhrase(phrase).phrase
    }

    func interpret(_ phrase: String, lastEditedField: LastEditedField?) -> ParseInterpretation {
        let normalization = normalizePhrase(phrase)
        let normalized = normalization.phrase
        guard !normalized.isEmpty else {
            return ParseInterpretation(result: .unrecognized, normalizedPhrase: normalized, confidence: .low)
        }
        
        let confidence = confidenceLevel(forCorrectionCount: normalization.correctionCount)

        if let reps = captureInt("^done\\s+(\\d+)$", in: normalized) {
            return ParseInterpretation(result: .recognized(.doneWithReps(reps)), normalizedPhrase: normalized, confidence: confidence)
        }

        if normalized == "done" {
            return ParseInterpretation(result: .recognized(.done), normalizedPhrase: normalized, confidence: confidence)
        }

        if normalized == "next" {
            return ParseInterpretation(result: .recognized(.next), normalizedPhrase: normalized, confidence: confidence)
        }

        if normalized == "previous" {
            return ParseInterpretation(result: .recognized(.previous), normalizedPhrase: normalized, confidence: confidence)
        }

        if normalized == "undo" {
            return ParseInterpretation(result: .recognized(.undo), normalizedPhrase: normalized, confidence: confidence)
        }

        if normalized == "clear" {
            return ParseInterpretation(result: .recognized(.clear), normalizedPhrase: normalized, confidence: confidence)
        }

        if normalized == "stop rest" || normalized == "end rest" {
            return ParseInterpretation(result: .recognized(.stopRest), normalizedPhrase: normalized, confidence: confidence)
        }

        if let seconds = parseRestSeconds(from: normalized) {
            return ParseInterpretation(result: .recognized(.rest(seconds)), normalizedPhrase: normalized, confidence: confidence)
        }

        if let weight = captureDouble("^weight\\s+([0-9]+(?:\\.[0-9]+)?)$", in: normalized) {
            return ParseInterpretation(result: .recognized(.setWeight(weight)), normalizedPhrase: normalized, confidence: confidence)
        }

        if let weightWithUnit = captureDouble("^([0-9]+(?:\\.[0-9]+)?)\\s*(kg)$", in: normalized) {
            return ParseInterpretation(result: .recognized(.setWeight(weightWithUnit)), normalizedPhrase: normalized, confidence: confidence)
        }

        if let reps = captureInt("^reps\\s*(\\d+)$", in: normalized) {
            return ParseInterpretation(result: .recognized(.setReps(reps)), normalizedPhrase: normalized, confidence: confidence)
        }

        if let reps = captureInt("^(\\d+)\\s*reps$", in: normalized) {
            return ParseInterpretation(result: .recognized(.setReps(reps)), normalizedPhrase: normalized, confidence: confidence)
        }

        if let exerciseName = captureString("^exercise\\s+(.+)$", in: normalized) {
            return ParseInterpretation(result: .recognized(.switchExercise(exerciseName)), normalizedPhrase: normalized, confidence: confidence)
        }

        if let bareInt = captureInt("^(\\d+)$", in: normalized) {
            if lastEditedField == .reps {
                return ParseInterpretation(result: .recognized(.setReps(bareInt)), normalizedPhrase: normalized, confidence: confidence)
            }
            return ParseInterpretation(result: .ambiguousNumber(bareInt), normalizedPhrase: normalized, confidence: confidence)
        }

        if let bareDouble = captureDouble("^([0-9]+(?:\\.[0-9]+)?)$", in: normalized) {
            return ParseInterpretation(result: .recognized(.setWeight(bareDouble)), normalizedPhrase: normalized, confidence: confidence)
        }

        return ParseInterpretation(result: .unrecognized, normalizedPhrase: normalized, confidence: confidence == .high ? .medium : .low)
    }

    private func normalizePhrase(_ phrase: String) -> (phrase: String, correctionCount: Int) {
        let lower = phrase.lowercased()
        let separatedUnits = lower.replacingOccurrences(
            of: "([0-9]+(?:\\.[0-9]+)?)(kg|kilo|kilos)\\b",
            with: "$1 $2",
            options: .regularExpression
        )
        let cleaned = separatedUnits.replacingOccurrences(of: "[^a-z0-9\\s.]", with: " ", options: .regularExpression)
        let rawTokens = cleaned.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !rawTokens.isEmpty else { return ("", 0) }

        var tokens: [String] = []
        var correctionCount = 0
        for (index, rawToken) in rawTokens.enumerated() {
            let token = trimTrailingPeriodsIfNeeded(rawToken)
            guard !token.isEmpty else { continue }

            if index >= 1, tokens.first == "exercise" {
                tokens.append(token)
                continue
            }

            if let canonical = aliasToCanonical[token] {
                tokens.append(canonical)
                correctionCount += 1
                continue
            }

            if let spokenNumber = spokenNumberTokens[token] {
                tokens.append(String(spokenNumber))
                correctionCount += 1
                continue
            }

            if isNumberToken(token) {
                tokens.append(token)
                continue
            }

            if let fuzzy = fuzzyCorrect(token) {
                tokens.append(fuzzy)
                if fuzzy != token {
                    correctionCount += 1
                }
            } else {
                tokens.append(token)
            }
        }

        return (tokens.joined(separator: " "), correctionCount)
    }

    private func confidenceLevel(forCorrectionCount count: Int) -> ParseConfidence {
        if count == 0 { return .high }
        if count <= 2 { return .medium }
        return .low
    }

    private func trimTrailingPeriodsIfNeeded(_ token: String) -> String {
        if token.contains("."), Double(token) != nil {
            return token
        }
        return token.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private func fuzzyCorrect(_ token: String) -> String? {
        var bestWord: String?
        var bestDistance = Int.max

        for candidate in fuzzyVocabulary {
            let distance = levenshteinDistance(token, candidate)
            if distance < bestDistance {
                bestDistance = distance
                bestWord = candidate
            }
        }

        guard let bestWord else { return nil }
        let maxDistance = token.count <= 4 ? 1 : 2
        return bestDistance <= maxDistance ? bestWord : nil
    }

    private func isNumberToken(_ token: String) -> Bool {
        Double(token) != nil
    }

    private func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        var matrix = Array(
            repeating: Array(repeating: 0, count: rhsChars.count + 1),
            count: lhsChars.count + 1
        )

        for i in 0...lhsChars.count {
            matrix[i][0] = i
        }
        for j in 0...rhsChars.count {
            matrix[0][j] = j
        }

        guard !lhsChars.isEmpty, !rhsChars.isEmpty else {
            return max(lhsChars.count, rhsChars.count)
        }

        for i in 1...lhsChars.count {
            for j in 1...rhsChars.count {
                let substitutionCost = lhsChars[i - 1] == rhsChars[j - 1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i - 1][j] + 1,
                    matrix[i][j - 1] + 1,
                    matrix[i - 1][j - 1] + substitutionCost
                )
            }
        }

        return matrix[lhsChars.count][rhsChars.count]
    }

    private func parseRestSeconds(from normalized: String) -> Int? {
        if let seconds = captureInt("^rest\\s+(\\d+)\\s*(s|second|seconds)?$", in: normalized) {
            return seconds
        }

        if let minutes = captureDouble("^rest\\s+([0-9]+(?:\\.[0-9]+)?)\\s*(m|minute|minutes)$", in: normalized) {
            return Int(minutes * 60.0)
        }

        return nil
    }

    private func captureInt(_ pattern: String, in text: String) -> Int? {
        guard let value = captureString(pattern, in: text) else {
            return nil
        }
        return Int(value)
    }

    private func captureDouble(_ pattern: String, in text: String) -> Double? {
        guard let value = captureString(pattern, in: text) else {
            return nil
        }
        return Double(value)
    }

    private func captureString(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }

        if match.numberOfRanges < 2, let fullRange = Range(match.range(at: 0), in: text) {
            return String(text[fullRange])
        }

        guard let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        return String(text[captureRange])
    }
}
