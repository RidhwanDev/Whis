import Foundation
import SwiftData
import SwiftUI
import Combine

struct CommandToastData: Identifiable, Equatable {
    let id = UUID()
    let phrase: String
    let action: String
    let isError: Bool
}

struct AmbiguousPrompt: Equatable {
    let phrase: String
    let value: Int
}

private struct UndoState {
    let exerciseID: UUID
    let setIndex: Int
    let weightKg: Double?
    let reps: Int?
    let isCompleted: Bool
    let completedAt: Date?
    let currentSetIndex: Int
}

enum CommandSource {
    case phone
    case watch
}

private struct CompoundVoiceIntent {
    var exerciseName: String?
    var weightKg: Double?
    var reps: Int?
    var markDone: Bool
}

@MainActor
final class WorkoutStore: ObservableObject {
    @Published private(set) var catalog: [ExerciseCatalogItem] = []
    @Published var currentSession: WorkoutSession?
    @Published var selectedExerciseID: UUID?
    @Published var restEndDate: Date?
    @Published var toast: CommandToastData?
    @Published var pendingAmbiguity: AmbiguousPrompt?
    @Published var showingSummary = false

    private var modelContext: ModelContext?
    private var undoStack: [UndoState] = []
    private var lastEditedField: LastEditedField?
    private let parser = CommandParser()
    private let syncManager: WatchSyncManager
#if os(iOS)
    private let speechFeedback = SpeechFeedbackService.shared
#endif

    init(syncManager: WatchSyncManager? = nil) {
        self.syncManager = syncManager ?? WatchSyncManager.shared
        self.syncManager.onIntentReceived = { [weak self] intent in
            Task { @MainActor in
                self?.handleWatchIntent(intent)
            }
        }
    }

    var selectedExercise: WorkoutExercise? {
        guard let currentSession else { return nil }
        let sorted = currentSession.exercises.sorted { $0.name < $1.name }
        if let selectedExerciseID,
           let exercise = sorted.first(where: { $0.id == selectedExerciseID }) {
            return exercise
        }

        return sorted.first
    }

    var currentSet: WorkoutSet? {
        guard let exercise = selectedExercise else { return nil }
        ensureSetPresence(for: exercise)
        let sorted = sortedSets(for: exercise)
        guard sorted.indices.contains(exercise.currentSetIndex) else {
            return sorted.first
        }
        return sorted[exercise.currentSetIndex]
    }

    var restRemainingSeconds: Int? {
        guard let restEndDate else { return nil }
        let remaining = Int(restEndDate.timeIntervalSinceNow.rounded())
        return max(0, remaining)
    }

    func configure(context: ModelContext) {
        guard modelContext == nil else { return }
        modelContext = context
        seedCatalogIfNeeded()
        loadCatalog()
    }

    func startWorkout() {
        guard let modelContext else { return }

        let session = WorkoutSession(name: "Workout")
        modelContext.insert(session)
        currentSession = session
        selectedExerciseID = nil
        restEndDate = nil
        undoStack.removeAll()
        showingSummary = false

        if let first = catalog.first {
            selectExercise(named: first.name)
        }

        saveContext()
        pushSnapshotToWatch()
    }

    func finishWorkout() {
        showingSummary = true
    }

    func saveWorkout() {
        currentSession?.endedAt = .now
        saveContext()
        showingSummary = false
        currentSession = nil
        selectedExerciseID = nil
        restEndDate = nil
        toast = nil
        pendingAmbiguity = nil
        pushSnapshotToWatch()
    }

    func discardWorkout() {
        guard let modelContext, let currentSession else { return }
        modelContext.delete(currentSession)
        saveContext()
        showingSummary = false
        self.currentSession = nil
        selectedExerciseID = nil
        restEndDate = nil
        toast = nil
        pendingAmbiguity = nil
        pushSnapshotToWatch()
    }

    func selectExercise(named name: String) {
        guard let currentSession else { return }

        if let existing = currentSession.exercises.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            selectedExerciseID = existing.id
            ensureSetPresence(for: existing)
            return
        }

        let item = catalog.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        let targetSetCount = item?.defaultSetCount ?? 3
        let restSeconds = item?.defaultRestSeconds ?? defaultRestSeconds
        let exercise = WorkoutExercise(name: name, targetSetCount: targetSetCount, defaultRestSeconds: restSeconds)
        for index in 0..<targetSetCount {
            exercise.sets.append(WorkoutSet(index: index))
        }
        exercise.session = currentSession
        currentSession.exercises.append(exercise)
        selectedExerciseID = exercise.id
        saveContext()
    }

    func updateCurrentWeight(by delta: Double) {
        guard let set = currentSet else { return }
        pushUndoSnapshot()
        let base = set.weightKg ?? 0
        set.weightKg = max(0, base + delta)
        lastEditedField = .weight
        saveContext()
        presentToast(phrase: "adjust weight", action: "Set weight to \(formattedWeight(set.weightKg)) kg", isError: false)
    }

    func updateCurrentReps(by delta: Int) {
        guard let set = currentSet else { return }
        pushUndoSnapshot()
        let base = set.reps ?? 0
        set.reps = max(0, base + delta)
        lastEditedField = .reps
        saveContext()
        presentToast(phrase: "adjust reps", action: "Set reps to \(set.reps ?? 0)", isError: false)
    }

    func applyTranscription(_ phrase: String, source: CommandSource) {
        if applyCompoundIntentIfPresent(phrase, source: source) {
            return
        }
        
        let interpretation = parser.interpret(phrase, lastEditedField: lastEditedField)
        let parsed = interpretation.result
        
        if interpretation.confidence == .low {
            presentToast(
                phrase: phrase,
                action: "Low confidence. Try saying: weight 80 or 8 reps",
                isError: true
            )
            return
        }

        switch parsed {
        case .recognized(let command):
            apply(command: command, phrase: phrase, source: source)
        case .ambiguousNumber(let value):
            if source == .watch {
                apply(command: .setWeight(Double(value)), phrase: phrase, source: source)
                presentToast(
                    phrase: phrase,
                    action: "Ambiguous number; treated as \(value) kg",
                    isError: true
                )
            } else {
                pendingAmbiguity = AmbiguousPrompt(phrase: phrase, value: value)
                presentToast(
                    phrase: phrase,
                    action: "Did you mean \(value) kg or \(value) reps?",
                    isError: true
                )
            }
        case .unrecognized:
            presentToast(
                phrase: phrase,
                action: "Could not parse command. Try \"weight 80\" or \"8 reps\"",
                isError: true
            )
        }
    }
    
    private func applyCompoundIntentIfPresent(_ phrase: String, source: CommandSource) -> Bool {
        guard let intent = extractCompoundIntent(from: phrase) else {
            return false
        }
        
        if intent.exerciseName != nil {
            if let match = fuzzyMatchExercise(intent.exerciseName ?? "") {
                selectExercise(named: match.name)
            } else {
                presentToast(phrase: phrase, action: "No matching exercise found", isError: true)
                return true
            }
        }
        
        guard let _ = selectedExercise, let set = currentSet else {
            presentToast(phrase: phrase, action: "Start a workout first", isError: true)
            return true
        }
        
        pushUndoSnapshot()
        
        var appliedParts: [String] = []
        
        if let weight = intent.weightKg {
            set.weightKg = weight
            lastEditedField = .weight
            appliedParts.append("weight \(formattedWeight(weight)) kg")
        }
        
        if let reps = intent.reps {
            set.reps = reps
            lastEditedField = .reps
            appliedParts.append("reps \(reps)")
        }
        
        if intent.markDone {
            let completed = completeAndAdvanceCurrentSet(
                exercise: selectedExercise,
                set: set,
                phrase: phrase,
                pushUndo: false
            )
            if completed {
#if os(iOS)
                if source == .watch {
                    pushSnapshotToWatch()
                }
#endif
            }
            return true
        }
        
        guard !appliedParts.isEmpty else {
            return false
        }
        
        saveContext()
        presentToast(phrase: phrase, action: "Applied: \(appliedParts.joined(separator: ", "))", isError: false)
        
#if os(iOS)
        if source == .watch {
            pushSnapshotToWatch()
        }
#endif
        return true
    }
    
    private func extractCompoundIntent(from phrase: String) -> CompoundVoiceIntent? {
        let normalized = parser.normalizeForMatching(phrase)
        guard !normalized.isEmpty else { return nil }
        
        let markDone = containsWord("done", in: normalized)
            || containsWord("complete", in: normalized)
            || containsWord("completed", in: normalized)
            || containsWord("finish", in: normalized)
        
        let weightFromUnit = captureDouble("\\b([0-9]+(?:\\.[0-9]+)?)\\s*kg\\b", in: normalized)
        let weightFromKeyword = captureDouble("\\bweight\\s+([0-9]+(?:\\.[0-9]+)?)\\b", in: normalized)
        let weight = weightFromUnit ?? weightFromKeyword
        
        let repsFromSuffix = captureInt("\\b([0-9]+)\\s*reps?\\b", in: normalized)
        let repsFromPrefix = captureInt("\\breps?\\s*([0-9]+)\\b", in: normalized)
        let reps = repsFromSuffix ?? repsFromPrefix
        
        let exercise = bestExerciseMatch(in: normalized)
        
        let hasCompoundSignal = markDone || weight != nil || reps != nil || exercise != nil
        guard hasCompoundSignal else { return nil }
        
        return CompoundVoiceIntent(exerciseName: exercise, weightKg: weight, reps: reps, markDone: markDone)
    }
    
    private func bestExerciseMatch(in normalizedPhrase: String) -> String? {
        var best: String?
        var bestTokenCount = 0
        
        for item in catalog {
            let candidate = item.name.lowercased()
            if normalizedPhrase.contains(candidate) {
                let tokenCount = candidate.split(separator: " ").count
                if tokenCount > bestTokenCount {
                    best = item.name
                    bestTokenCount = tokenCount
                }
            }
        }
        
        return best
    }
    
    private func containsWord(_ word: String, in text: String) -> Bool {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
    
    private func captureInt(_ pattern: String, in text: String) -> Int? {
        guard let value = captureString(pattern, in: text) else { return nil }
        return Int(value)
    }
    
    private func captureDouble(_ pattern: String, in text: String) -> Double? {
        guard let value = captureString(pattern, in: text) else { return nil }
        return Double(value)
    }
    
    private func captureString(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        guard match.numberOfRanges > 1 else { return nil }
        guard let captureRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captureRange])
    }

    func resolveAmbiguousNumber(asReps: Bool) {
        guard let prompt = pendingAmbiguity else { return }
        pendingAmbiguity = nil

        if asReps {
            apply(command: .setReps(prompt.value), phrase: prompt.phrase, source: .phone)
        } else {
            apply(command: .setWeight(Double(prompt.value)), phrase: prompt.phrase, source: .phone)
        }
    }

    func lastThreeCompletedSets() -> [WorkoutSet] {
        guard let selectedExercise else { return [] }
        return selectedExercise
            .sets
            .filter { $0.isCompleted }
            .sorted { $0.index > $1.index }
            .prefix(3)
            .map { $0 }
    }

    func heartbeat() {
        if let restEndDate, restEndDate <= .now {
            self.restEndDate = nil
        }
        pushSnapshotToWatch()
    }

    private func apply(command: VoiceCommand, phrase: String, source: CommandSource) {
        guard let exercise = selectedExercise, let set = currentSet else {
            presentToast(phrase: phrase, action: "Start a workout first", isError: true)
            return
        }

        switch command {
        case .setWeight(let value):
            pushUndoSnapshot()
            set.weightKg = value
            lastEditedField = .weight
            saveContext()
            presentToast(phrase: phrase, action: "Set weight to \(formattedWeight(value)) kg", isError: false)

        case .setReps(let value):
            pushUndoSnapshot()
            set.reps = value
            lastEditedField = .reps
            saveContext()
            presentToast(phrase: phrase, action: "Set reps to \(value)", isError: false)

        case .done:
            _ = completeAndAdvanceCurrentSet(
                exercise: exercise,
                set: set,
                phrase: phrase
            )

        case .doneWithReps(let value):
            _ = completeAndAdvanceCurrentSet(
                exercise: exercise,
                set: set,
                phrase: phrase,
                repsOverride: value
            )

        case .next:
            _ = completeAndAdvanceCurrentSet(
                exercise: exercise,
                set: set,
                phrase: phrase
            )

        case .previous:
            if exercise.currentSetIndex > 0 {
                pushUndoSnapshot()
                exercise.currentSetIndex -= 1
                saveContext()
                presentToast(phrase: phrase, action: "Moved to set \(exercise.currentSetIndex + 1)", isError: false)
            } else {
                presentToast(phrase: phrase, action: "Already at first set", isError: true)
            }

        case .rest(let seconds):
            restEndDate = .now.addingTimeInterval(TimeInterval(seconds))
            presentToast(phrase: phrase, action: "Started rest for \(seconds)s", isError: false)

        case .stopRest:
            restEndDate = nil
            presentToast(phrase: phrase, action: "Rest stopped", isError: false)

        case .undo:
            undoLastAction(phrase: phrase)

        case .clear:
            pushUndoSnapshot()
            set.reps = nil
            set.weightKg = nil
            set.isCompleted = false
            set.completedAt = nil
            saveContext()
            presentToast(phrase: phrase, action: "Cleared current set values", isError: false)

        case .switchExercise(let spokenName):
            if let match = fuzzyMatchExercise(spokenName) {
                selectExercise(named: match.name)
                presentToast(phrase: phrase, action: "Switched to \(match.name)", isError: false)
            } else {
                presentToast(phrase: phrase, action: "No matching exercise found", isError: true)
            }
        }

#if os(iOS)
        if source == .watch {
            pushSnapshotToWatch()
        }
#endif
    }

    private func completeAndAdvanceCurrentSet(
        exercise: WorkoutExercise?,
        set: WorkoutSet,
        phrase: String,
        repsOverride: Int? = nil,
        pushUndo: Bool = true
    ) -> Bool {
        guard let exercise else { return false }
        
        if pushUndo {
            pushUndoSnapshot()
        }
        
        if let repsOverride {
            set.reps = repsOverride
            lastEditedField = .reps
        }
        
        guard set.reps != nil || set.weightKg != nil else {
            presentToast(
                phrase: phrase,
                action: "Enter reps or weight before completing set",
                isError: true
            )
            return false
        }
        
        set.isCompleted = true
        set.completedAt = .now
        
        if exercise.currentSetIndex + 1 < exercise.targetSetCount {
            exercise.currentSetIndex += 1
            let sorted = sortedSets(for: exercise)
            if sorted.indices.contains(exercise.currentSetIndex) {
                let nextSet = sorted[exercise.currentSetIndex]
                if nextSet.weightKg == nil {
                    nextSet.weightKg = set.weightKg
                }
                if nextSet.reps == nil {
                    nextSet.reps = set.reps
                }
            }
            saveContext()
            presentToast(
                phrase: phrase,
                action: "Completed set \(set.index + 1). Ready for set \(exercise.currentSetIndex + 1)",
                isError: false
            )
        } else {
            saveContext()
            presentToast(
                phrase: phrase,
                action: "Completed final set \(set.index + 1)",
                isError: false
            )
        }
        return true
    }

    private func fuzzyMatchExercise(_ spokenName: String) -> ExerciseCatalogItem? {
        let normalized = spokenName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = catalog.first(where: { $0.name.lowercased() == normalized }) {
            return exact
        }

        return catalog.first(where: { $0.name.lowercased().contains(normalized) || normalized.contains($0.name.lowercased()) })
    }

    private func handleWatchIntent(_ intent: WatchIntent) {
        guard let command = intent.payload.toVoiceCommand() else { return }
        let phrase = intent.phrase ?? "watch command"
        apply(command: command, phrase: phrase, source: .watch)
    }

    private func undoLastAction(phrase: String) {
        guard let snapshot = undoStack.popLast() else {
            presentToast(phrase: phrase, action: "Nothing to undo", isError: true)
            return
        }

        guard let exercise = currentSession?.exercises.first(where: { $0.id == snapshot.exerciseID }) else {
            presentToast(phrase: phrase, action: "Undo target not found", isError: true)
            return
        }

        guard let set = exercise.sets.first(where: { $0.index == snapshot.setIndex }) else {
            presentToast(phrase: phrase, action: "Undo set not found", isError: true)
            return
        }

        set.weightKg = snapshot.weightKg
        set.reps = snapshot.reps
        set.isCompleted = snapshot.isCompleted
        set.completedAt = snapshot.completedAt
        exercise.currentSetIndex = snapshot.currentSetIndex
        saveContext()

        presentToast(phrase: phrase, action: "Undid last action", isError: false)
    }

    private func pushUndoSnapshot() {
        guard let exercise = selectedExercise, let set = currentSet else { return }

        undoStack.append(
            UndoState(
                exerciseID: exercise.id,
                setIndex: set.index,
                weightKg: set.weightKg,
                reps: set.reps,
                isCompleted: set.isCompleted,
                completedAt: set.completedAt,
                currentSetIndex: exercise.currentSetIndex
            )
        )
    }

    private func presentToast(phrase: String, action: String, isError: Bool) {
        toast = CommandToastData(phrase: phrase, action: action, isError: isError)
        pushSnapshotToWatch()
#if os(iOS)
        speechFeedback.speakConfirmation(action: action, isError: isError)
#endif

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if self.toast?.phrase == phrase {
                self.toast = nil
                self.pushSnapshotToWatch()
            }
        }
    }

    private func loadCatalog() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<ExerciseCatalogItem>(sortBy: [SortDescriptor(\.name)])
        catalog = (try? modelContext.fetch(descriptor)) ?? []
    }

    private func seedCatalogIfNeeded() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<ExerciseCatalogItem>()
        let count = (try? modelContext.fetchCount(descriptor)) ?? 0
        guard count == 0 else { return }

        let defaults: [ExerciseCatalogItem] = [
            ExerciseCatalogItem(name: "Bench Press", defaultSetCount: 3, defaultRestSeconds: 120),
            ExerciseCatalogItem(name: "Squat", defaultSetCount: 3, defaultRestSeconds: 120),
            ExerciseCatalogItem(name: "Deadlift", defaultSetCount: 3, defaultRestSeconds: 150),
            ExerciseCatalogItem(name: "Overhead Press", defaultSetCount: 3, defaultRestSeconds: 120),
            ExerciseCatalogItem(name: "Barbell Row", defaultSetCount: 3, defaultRestSeconds: 90),
            ExerciseCatalogItem(name: "Pull-Up", defaultSetCount: 3, defaultRestSeconds: 90),
            ExerciseCatalogItem(name: "Dumbbell Curl", defaultSetCount: 3, defaultRestSeconds: 75),
            ExerciseCatalogItem(name: "Romanian Deadlift", defaultSetCount: 3, defaultRestSeconds: 120),
            ExerciseCatalogItem(name: "Leg Press", defaultSetCount: 3, defaultRestSeconds: 90),
            ExerciseCatalogItem(name: "Lat Pulldown", defaultSetCount: 3, defaultRestSeconds: 90)
        ]

        for item in defaults {
            modelContext.insert(item)
        }
        saveContext()
    }

    private func ensureSetPresence(for exercise: WorkoutExercise) {
        if exercise.sets.isEmpty {
            for index in 0..<exercise.targetSetCount {
                exercise.sets.append(WorkoutSet(index: index))
            }
        }

        if exercise.currentSetIndex < 0 {
            exercise.currentSetIndex = 0
        }

        if exercise.currentSetIndex >= exercise.targetSetCount {
            exercise.currentSetIndex = max(0, exercise.targetSetCount - 1)
        }
    }

    private func sortedSets(for exercise: WorkoutExercise) -> [WorkoutSet] {
        exercise.sets.sorted { $0.index < $1.index }
    }

    private func saveContext() {
        try? modelContext?.save()
    }

    private var defaultRestSeconds: Int {
        let value = UserDefaults.standard.integer(forKey: "settings.defaultRest")
        return value == 0 ? 90 : value
    }

    var weightIncrement: Double {
        let value = UserDefaults.standard.double(forKey: "settings.weightIncrement")
        return value == 0 ? 2.5 : value
    }

    private func pushSnapshotToWatch() {
#if os(iOS)
        guard let exercise = selectedExercise else { return }
        let set = currentSet
        let snapshot = WorkoutSnapshot(
            exerciseName: exercise.name,
            setIndex: exercise.currentSetIndex,
            setCount: exercise.targetSetCount,
            weightKg: set?.weightKg,
            reps: set?.reps,
            restRemaining: restRemainingSeconds,
            phrase: toast?.phrase,
            action: toast?.action,
            isError: toast?.isError ?? false
        )
        syncManager.sendSnapshot(snapshot)
#endif
    }

    func intent(for command: VoiceCommand, phrase: String?) -> WatchIntent {
        WatchIntent(payload: IntentPayload(command: command), phrase: phrase)
    }

    private func formattedWeight(_ value: Double?) -> String {
        guard let value else { return "0" }
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}
