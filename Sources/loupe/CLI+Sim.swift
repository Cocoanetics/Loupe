import ArgumentParser
import LoupeKit
import LoupeSim

struct Sim: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sim",
        abstract: "Simulator-only helpers that make screenshots deterministic.",
        subcommands: [StatusBar.self, Appearance.self, Install.self, Privacy.self])

    struct StatusBar: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status-bar",
            abstract: "Freeze the status bar so the clock cannot cause a false diff.")

        @Argument(help: "Simulator target, e.g. booted.")
        var device: String = "booted"

        @Option(help: "Time to display.") var time: String = "9:41"
        @Option(help: "Battery level 0-100.") var battery: Int = 100
        @Option(help: "Wi-Fi bars 0-3.") var wifiBars: Int = 3
        @Option(help: "Cellular bars 0-4.") var cellularBars: Int = 4
        @Flag(help: "Clear any override instead of setting one.") var clear = false

        func run() async throws {
            let driver = SimDriver(deviceLocator: device)
            try await driver.prepare()
            if clear {
                print(try await driver.clearStatusBar().message)
            } else {
                let result = try await driver.setStatusBar(
                    time: time, batteryLevel: battery, wifiBars: wifiBars, cellularBars: cellularBars)
                print(result.message)
            }
        }
    }

    struct Appearance: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "appearance", abstract: "Switch the simulator between light and dark.")

        @Argument(help: "light or dark.") var mode: String
        @Option(help: "Simulator target.") var device: String = "booted"

        func run() async throws {
            let driver = SimDriver(deviceLocator: device)
            try await driver.prepare()
            print(try await driver.setAppearance(mode).message)
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install", abstract: "Install a .app bundle on the simulator.")

        @Argument(help: "Path to the .app.") var path: String
        @Option(help: "Simulator target.") var device: String = "booted"

        func run() async throws {
            let driver = SimDriver(deviceLocator: device)
            try await driver.prepare()
            let installed = try await driver.install(path: path)
            print(installed.bundleID)
        }
    }

    struct Privacy: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "privacy",
            abstract: "Pre-grant a permission so no dialog appears in your screenshot.")

        @Argument(help: "Service: photos, camera, microphone, location, contacts, calendar, all…")
        var service: String
        @Argument(help: "Bundle id.") var bundleID: String
        @Option(help: "Simulator target.") var device: String = "booted"
        @Flag(help: "Revoke instead of grant.") var revoke = false

        func run() async throws {
            let driver = SimDriver(deviceLocator: device)
            try await driver.prepare()
            if revoke {
                print(try await driver.resetPrivacy(service: service, bundleID: bundleID).message)
            } else {
                print(try await driver.grantPrivacy(service: service, bundleID: bundleID).message)
            }
        }
    }
}
