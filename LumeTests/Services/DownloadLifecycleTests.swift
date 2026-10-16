@testable import Lume
import Testing

struct DownloadLifecycleTests {
    @Test func `cancelled callbacks cannot adopt or settle a replacement`() {
        var machine = DownloadLifecycle()
        machine.enqueue("movie")
        let accepted1 = machine.start("movie", task: 1)
        #expect(accepted1)
        machine.cancel("movie")
        let accepted2 = !machine.beginCompletion("movie", task: 1)
        #expect(accepted2)
        machine.enqueue("movie")
        let accepted3 = !machine.beginCompletion("movie", task: 1)
        #expect(accepted3)
        let accepted4 = machine.start("movie", task: 2)
        #expect(accepted4)
        let accepted5 = !machine.finish("movie", task: 1)
        #expect(accepted5)
        let accepted6 = machine.beginCompletion("movie", task: 2)
        #expect(accepted6)
        let accepted7 = machine.finish("movie", task: 2)
        #expect(accepted7)
        let accepted8 = !machine.finish("movie", task: 2)
        #expect(accepted8)
    }

    @Test func `relaunch adopts a task but duplicate callbacks settle once`() {
        var machine = DownloadLifecycle()
        let accepted9 = machine.beginCompletion("episode", task: 4)
        #expect(accepted9)
        let accepted10 = !machine.beginCompletion("episode", task: 4)
        #expect(accepted10)
        let accepted11 = machine.finish("episode", task: 4)
        #expect(accepted11)
        let accepted12 = !machine.restore("episode", task: 4)
        #expect(accepted12)
    }

    @Test func `validation failures settle a finishing attempt once`() {
        var machine = DownloadLifecycle()
        let accepted13 = machine.beginCompletion("movie", task: 3)
        #expect(accepted13)
        let accepted14 = machine.fail("movie", task: 3)
        #expect(accepted14)
        let accepted15 = !machine.fail("movie", task: 3)
        #expect(accepted15)
        machine.enqueue("movie")
        let accepted16 = machine.start("movie", task: 4)
        #expect(accepted16)
        let accepted17 = !machine.fail("movie", task: 3)
        #expect(accepted17)
    }
}
