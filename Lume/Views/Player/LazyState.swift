//
//  LazyState.swift
//  Lume
//
//  View-owned storage for an `@Observable` player coordinator, created once.
//

import SwiftUI

/// Owns a reference-type model for the life of a view, building it once.
///
/// `@StateObject` did this for the player coordinators while they were
/// `ObservableObject`s. `@State` doesn't: its initial value is evaluated again
/// every time the parent re-renders the view, and the extra copies are
/// discarded. That is harmless for a cheap model, but these coordinators build
/// an `AVPlayer`, a `VLCMediaPlayer` or an engine session in `init`, so a plain
/// `@State` would create and drop a player on every parent update. Here `@State`
/// keeps only a box holding the factory; the model is built on first access and
/// stays the same instance thereafter. Observation comes from the model's own
/// `@Observable` registrar, not from this wrapper.
@propertyWrapper
struct LazyState<Value: AnyObject>: DynamicProperty {
    @State private var box: Box

    init(wrappedValue make: @autoclosure @escaping () -> Value) {
        _box = State(initialValue: Box(make))
    }

    var wrappedValue: Value {
        box.value
    }

    private final class Box {
        private let make: () -> Value
        private(set) lazy var value: Value = make()

        init(_ make: @escaping () -> Value) {
            self.make = make
        }
    }
}
