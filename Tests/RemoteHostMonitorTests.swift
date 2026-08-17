import Testing
@testable import SwarmBar

@Suite("Remote host monitor")
struct RemoteHostMonitorTests {
    @Test("a reinstall is skipped while backoff is still below the cap")
    func belowCapSkipsReinstall() {
        #expect(RemoteHostMonitor.shouldReinstall(afterBackoff: 1) == false)
        #expect(RemoteHostMonitor.shouldReinstall(afterBackoff: 8) == false)
        #expect(RemoteHostMonitor.shouldReinstall(afterBackoff: 59) == false)
    }

    @Test("a reinstall fires once backoff reaches the cap")
    func atCapReinstalls() {
        #expect(RemoteHostMonitor.shouldReinstall(afterBackoff: 60) == true)
    }

    @Test("a reinstall keeps firing above the cap")
    func aboveCapReinstalls() {
        #expect(RemoteHostMonitor.shouldReinstall(afterBackoff: 61) == true)
        #expect(RemoteHostMonitor.shouldReinstall(afterBackoff: 999) == true)
    }

    @Test("the install wait is bounded, and by less than one poll's worth of stalling")
    func installWaitIsBounded() {
        // The point of the bound is that a half-open connection cannot wedge
        // a host's loop before its do/catch, where nothing updates
        // reachability. It has to outlast a connect (10s) and be short
        // enough that the host recovers on its own.
        #expect(RemoteHostMonitor.installTimeout > 10)
        #expect(RemoteHostMonitor.installTimeout <= 60)
    }
}
