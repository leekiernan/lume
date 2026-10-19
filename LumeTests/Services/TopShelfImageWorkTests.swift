#if canImport(UIKit)
    @testable import Lume
    import Testing

    struct TopShelfImageWorkTests {
        @Test func `image work stays bounded while every requested image completes`() async {
            let count = Counter()
            let results = await TopShelfImages.boundedMap(Array(0 ..< 30), concurrency: 3) { value in
                await count.enter()
                try? await Task.sleep(for: .milliseconds(5))
                await count.leave()
                return value
            }
            #expect(Set(results) == Set(0 ..< 30))
            #expect(await count.peak <= 3)
            #expect(await count.active == 0)
        }

        @Test func `cancelled rendering starts no additional images`() async {
            let count = Counter()
            let task = Task {
                await TopShelfImages.boundedMap(Array(0 ..< 30), concurrency: 1) { value in
                    await count.enter()
                    try? await Task.sleep(for: .seconds(60))
                    await count.leave()
                    return value
                }
            }
            while await count.peak == 0 {
                await Task.yield()
            }
            task.cancel()
            _ = await task.value
            #expect(await count.started == 1)
        }
    }

    private actor Counter {
        private(set) var active = 0
        private(set) var peak = 0
        private(set) var started = 0

        func enter() {
            active += 1
            started += 1
            peak = max(peak, active)
        }

        func leave() {
            active -= 1
        }
    }
#endif
