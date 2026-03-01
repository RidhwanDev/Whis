import Foundation
import SwiftData

@Model
final class WorkoutSession {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var name: String?
    @Relationship(deleteRule: .cascade, inverse: \WorkoutExercise.session)
    var exercises: [WorkoutExercise]

    init(
        id: UUID = UUID(),
        startedAt: Date = .now,
        endedAt: Date? = nil,
        name: String? = nil,
        exercises: [WorkoutExercise] = []
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.name = name
        self.exercises = exercises
    }
}

@Model
final class WorkoutExercise {
    var id: UUID
    var name: String
    var currentSetIndex: Int
    var targetSetCount: Int
    var defaultRestSeconds: Int
    var session: WorkoutSession?
    @Relationship(deleteRule: .cascade, inverse: \WorkoutSet.exercise)
    var sets: [WorkoutSet]

    init(
        id: UUID = UUID(),
        name: String,
        currentSetIndex: Int = 0,
        targetSetCount: Int = 3,
        defaultRestSeconds: Int = 90,
        session: WorkoutSession? = nil,
        sets: [WorkoutSet] = []
    ) {
        self.id = id
        self.name = name
        self.currentSetIndex = currentSetIndex
        self.targetSetCount = targetSetCount
        self.defaultRestSeconds = defaultRestSeconds
        self.session = session
        self.sets = sets
    }
}

@Model
final class WorkoutSet {
    var id: UUID
    var index: Int
    var weightKg: Double?
    var reps: Int?
    var completedAt: Date?
    var isCompleted: Bool
    var exercise: WorkoutExercise?

    init(
        id: UUID = UUID(),
        index: Int,
        weightKg: Double? = nil,
        reps: Int? = nil,
        completedAt: Date? = nil,
        isCompleted: Bool = false,
        exercise: WorkoutExercise? = nil
    ) {
        self.id = id
        self.index = index
        self.weightKg = weightKg
        self.reps = reps
        self.completedAt = completedAt
        self.isCompleted = isCompleted
        self.exercise = exercise
    }
}

@Model
final class ExerciseCatalogItem {
    var id: UUID
    var name: String
    var defaultSetCount: Int
    var defaultRestSeconds: Int

    init(
        id: UUID = UUID(),
        name: String,
        defaultSetCount: Int,
        defaultRestSeconds: Int
    ) {
        self.id = id
        self.name = name
        self.defaultSetCount = defaultSetCount
        self.defaultRestSeconds = defaultRestSeconds
    }
}
