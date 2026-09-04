import Foundation

// Compile-time proof that SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor reaches swiftc for this
// target. Under `nonisolated` default isolation, calling a @MainActor function synchronously
// from a non-isolated function is an error in Swift 6 language mode.
@MainActor func isolationProbe_mainActorOnly() {}

func isolationProbe_callsMainActorSynchronously() {
    isolationProbe_mainActorOnly()
}
