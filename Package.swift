// swift-tools-version:5.9
// Pacote SwiftPM do widget bFocus para iOS (UIKit + SwiftUI + WKWebView).
// O núcleo (BFocusWidgetCore) é Swift puro + Foundation e também compila no macOS,
// o que permite rodar a suíte de conformidade com `swift test` sem simulador.
import PackageDescription

let package = Package(
    name: "BFocusWidget",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "BFocusWidget", targets: ["BFocusWidget"]),
        .library(name: "BFocusWidgetCore", targets: ["BFocusWidgetCore"]),
    ],
    targets: [
        .target(name: "BFocusWidgetCore"),
        .target(name: "BFocusWidget", dependencies: ["BFocusWidgetCore"]),
        .testTarget(
            name: "BFocusWidgetTests",
            dependencies: ["BFocusWidgetCore", "BFocusWidget"],
            // Cópia gerada por widgets-native/conformance/generate.mjs: nunca editar à mão.
            resources: [.copy("Resources/scenarios.json")]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
