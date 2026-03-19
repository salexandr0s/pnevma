import Cocoa

#if SWIFT_PACKAGE
import Pnevma
#endif

private final class HostedUnitTestAppDelegate: NSObject, NSApplicationDelegate {}

@main
struct PnevmaApp {
    static func main() {
        let app = NSApplication.shared
        let delegate: NSObject & NSApplicationDelegate
        if AppLaunchContext.isUnitTesting && !AppLaunchContext.isUITesting {
            // Hosted XCTest launches the app before test code runs. Keep the
            // host process alive without bootstrapping the real runtime; tests
            // that need AppDelegate own that lifecycle explicitly.
            delegate = HostedUnitTestAppDelegate()
        } else {
            delegate = AppDelegate()
        }
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
