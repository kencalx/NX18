// The sweep a game's start from Beam gets (LaunchSweep.swift): which starts get it, the plain fade under Reduce Motion, its timing and the logo's dashes
import Foundation
import Testing
@testable import NX_18_Beam

@Suite struct LaunchSweepTests {
    @Test func whichStartsGetIt() {
        #expect(LaunchSweep.style(beamActive: true, reduceMotion: false) == .sweep, "a start from Beam in front: the dashes")
        #expect(LaunchSweep.style(beamActive: true, reduceMotion: true) == .fade, "Reduce Motion: the veil's fade alone")
        #expect(LaunchSweep.style(beamActive: false, reduceMotion: false) == nil, "Beam not in front: nothing over the other app")
        #expect(LaunchSweep.style(beamActive: false, reduceMotion: true) == nil)
    }
    @Test func timing() {
        let s = LaunchSweep.timeline(.sweep), f = LaunchSweep.timeline(.fade)
        #expect(s.shown >= 0.8 && s.shown <= 1.2, "the sweep runs about a second")
        #expect(f.motion == 0, "the fade has no motion")
        #expect(f.shown <= 0.3 && f.out <= 0.3, "the fade is short")
        #expect(s.hold <= 2 && f.hold <= 2, "the still veil never holds long when the game is slow to show")
    }
    @Test func dashesAsTheLogo() {
        #expect(LaunchSweep.dashes.map(\.length) == [34, 58, 34], "make_logo.py: the middle dash longest")
        #expect(LaunchSweep.dashes.map(\.dy) == [-34, 0, 34])
        #expect(LaunchSweep.unit(height: 900) == 1)
    }
}
