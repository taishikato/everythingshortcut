/// Pairs the windows a scan planned (from the window list) with the app's AX windows.
/// Generic over `Handle`, so the shell passes `AXUIElement` and tests pass `Int`.
public enum WindowMatching {
    public struct Result<Handle> {
        public var pairs: [(window: WindowInfo, handle: Handle)] = []
        /// Nil when every frame the match needed was read. Otherwise `pairs` is a valid partial result,
        /// and the scan of this app ends.
        public var stop: StopReason?
    }

    /// A planned window pairs with the handle that has its id, else with the first unidentified handle
    /// whose frame equals its bounds.
    ///
    /// Invariants:
    /// - Matching by id costs no IPC.
    /// - `frame` costs one IPC. It runs only when some planned window has no handle by id, and then at
    ///   most once per unidentified handle, however many planned windows fall back to frames.
    /// - `shouldStop` is checked before every `frame` call. Cancellation and the scan deadline both feed it.
    /// - `.unresponsive` from `frame` ends the frame reads. Any other error leaves that handle unmatched.
    /// - After a stop, windows are still paired by id, and no window is paired by frame.
    public static func pair<Handle>(
        planned: [WindowInfo],
        identified: [WindowID: Handle],
        unidentified: [Handle],
        frame: (Handle) throws(ReadError) -> GlobalRect?,
        shouldStop: () -> Bool
    ) -> Result<Handle> {
        var result = Result<Handle>()
        var frames: [GlobalRect?]?
        for info in planned {
            if let handle = identified[info.id] {
                result.pairs.append((info, handle))
                continue
            }
            if frames == nil {
                var read: [GlobalRect?] = []
                for handle in unidentified {
                    if shouldStop() { result.stop = .budget; break }
                    do throws(ReadError) {
                        read.append(try frame(handle))
                    } catch {
                        if error == .unresponsive { result.stop = .unresponsive; break }
                        read.append(nil)
                    }
                }
                frames = read
            }
            guard result.stop == nil, let index = frames?.firstIndex(of: info.bounds) else { continue }
            result.pairs.append((info, unidentified[index]))
        }
        return result
    }
}
