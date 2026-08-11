// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "Loupe",
	platforms: [.macOS(.v14)],
	products: [
		.executable(name: "loupe", targets: ["loupe"]),
		.library(name: "LoupeKit", targets: ["LoupeKit"]),
		.library(name: "LoupeXCUI", targets: ["LoupeXCUI"]),
	],
	dependencies: [
		.package(url: "https://github.com/apple/swift-argument-parser", from: "1.4.0"),
		.package(url: "https://github.com/Cocoanetics/SwiftMCP.git", from: "1.10.1"),
		.package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
		.package(url: "https://github.com/Cocoanetics/SwiftScript.git", branch: "main"),
	],
	targets: [
		// Contracts, models, image math. No platform drivers, no dependencies.
		.target(name: "LoupeCore"),

		// One target per surface. Each vends a `UIDriver`.
		.target(name: "LoupeWeb", dependencies: ["LoupeCore"]),
		.target(name: "LoupeMac", dependencies: ["LoupeCore"]),
		.target(name: "LoupeSim", dependencies: ["LoupeCore"]),

		// Umbrella: target parsing -> driver resolution.
		.target(name: "LoupeKit", dependencies: ["LoupeCore", "LoupeWeb", "LoupeMac", "LoupeSim"]),

		// MCP server surface, so agents get the same verbs as the CLI.
		.target(
			name: "LoupeMCP",
			dependencies: [
				"LoupeKit",
				"LoupeXCUI",
				.product(name: "SwiftMCP", package: "SwiftMCP"),
				.product(name: "Logging", package: "swift-log"),
			]),

		// The XCUITest-shaped scripting surface: the same source that compiles
		// as a UI test, interpreted against Loupe's drivers.
		.target(
			name: "LoupeXCUI",
			dependencies: [
				"LoupeKit",
				.product(name: "SwiftScriptInterpreter", package: "SwiftScript"),
			]),

		.executableTarget(
			name: "loupe",
			dependencies: [
				"LoupeKit",
				"LoupeMCP",
				"LoupeXCUI",
				.product(name: "ArgumentParser", package: "swift-argument-parser"),
			]),

		.testTarget(name: "LoupeTests", dependencies: ["LoupeKit", "LoupeXCUI", "LoupeMCP"]),
	]
)
