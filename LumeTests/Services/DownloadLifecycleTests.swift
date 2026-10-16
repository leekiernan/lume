@testable import Lume
import Testing

struct DownloadLifecycleTests {
    @Test func `cancelled callbacks cannot adopt or settle a replacement`() {
        var machine = DownloadLifecycle()
        machine.enqueue("movie")
        #expect(machine.start("movie", task: 1))
        machine.cancel("movie")
        #expect(!machine.beginCompletion("movie", task: 1))
        machine.enqueue("movie")
        #expect(!machine.beginCompletion("movie", task: 1))
        #expect(machine.start("movie", task: 2))
        #expect(!machine.finish("movie", task: 1))
        #expect(machine.beginCompletion("movie", task: 2))
        #expect(machine.finish("movie", task: 2))
        #expect(!machine.finish("movie", task: 2))
    }

    @Test func `relaunch adopts a task but duplicate callbacks settle once`() {
        var machine = DownloadLifecycle()
        #expect(machine.beginCompletion("episode", task: 4))
        #expect(!machine.beginCompletion("episode", task: 4))
        #expect(machine.finish("episode", task: 4))
        #expect(!machine.restore("episode", task: 4))
    }

    @Test func `validation failures settle a finishing attempt once`() {
        var machine = DownloadLifecycle()
        #expect(machine.beginCompletion("movie", task: 3))
        #expect(machine.fail("movie", task: 3))
        #expect(!machine.fail("movie", task: 3))
        machine.enqueue("movie")
        #expect(machine.start("movie", task: 4))
        #expect(!machine.fail("movie", task: 3))
    }
}
