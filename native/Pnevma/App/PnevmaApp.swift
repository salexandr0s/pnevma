import Cocoa

#if SWIFT_PACKAGE
import Pnevma
#endif

@main
struct PnevmaApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
