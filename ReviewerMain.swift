import AppKit

@main
enum BarcodeReviewerMain {
    static var delegate: AppDelegate?

    static func main() {
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--scan" {
            CLI.run(path: CommandLine.arguments[2])
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let scanner = ScannerController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        scanner.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        scanner.add(urls: [URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        scanner.add(urls: urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About BarcodeScanner", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit BarcodeScanner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        let openItem = NSMenuItem(title: "Open Images…", action: #selector(ScannerController.openImage(_:)), keyEquivalent: "o")
        openItem.target = scanner
        fileMenu.addItem(openItem)
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}

enum CLI {
    static func run(path: String) {
        let url = URL(fileURLWithPath: path)
        do {
            let loaded = try ImageLoader.load(from: url)
            fputs("loaded display \(loaded.display.width)x\(loaded.display.height) sensor \(loaded.sensor.width)x\(loaded.sensor.height) orientation \(loaded.orientation.rawValue)\n", stderr)
            let barcodes = VisionScanner.detect(in: loaded) { message in
                fputs("\(message)\n", stderr)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(barcodes)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            fputs("count=\(barcodes.count)\n", stderr)
            exit(0)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
