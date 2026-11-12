//
//  PosterWindowTests.swift
//  LumeTests
//
//  What a page adds to a grid: new rows only, and one row per title.
//

@testable import Lume
import Testing

struct PosterWindowTests {
    @Test func `a page adds its new rows in order and says how many`() {
        var window = PosterWindow<Int>()
        #expect(window.accept([1, 2]) == 2)
        #expect(window.accept([2, 3]) == 1)
        #expect(window.items == [1, 2, 3])
    }

    @Test func `copies of a title shown already add nothing`() {
        var window = PosterWindow<String>(duplicateKey: { $0.first.map(AnyHashable.init) })
        #expect(window.accept(["a1", "a2", "b1"]) == 2)
        #expect(window.accept(["a3"]) == 0)
        #expect(window.items == ["a1", "b1"])
    }

    @Test func `rows without a key are never grouped`() {
        var window = PosterWindow<String>(duplicateKey: { $0.hasPrefix("x") ? nil : AnyHashable("same") })
        window.accept(["x1", "x2", "y1", "y2"])
        #expect(window.items == ["x1", "x2", "y1"])
    }

    @Test func `replacing starts the grouping again`() {
        var window = PosterWindow<String>(duplicateKey: { $0.first.map(AnyHashable.init) })
        window.accept(["a1"])
        window.replace(with: ["a2", "b1"])
        #expect(window.items == ["a2", "b1"])
    }
}
