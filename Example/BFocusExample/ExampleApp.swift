import SwiftUI
import UIKit
import UserNotifications
import BFocusWidget

@main
struct ExampleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        ExampleSetup.start()
        return true
    }

    // Push: o app já tem o Firebase Messaging. No delegate dele:
    //   func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
    //       if let fcmToken { BFocus.shared.registerPushToken(fcmToken) }
    //   }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            // true = era do bFocus e o widget já abriu no chamado/conversa certo.
            if !BFocus.shared.handlePush(userInfo) {
                // notificação de outro sistema do app
            }
            completionHandler()
        }
    }
}

@MainActor
enum ExampleSetup {
    /// Variáveis do scheme (Edit Scheme → Run → Environment):
    /// - `BFOCUS_KEY`: chave pública `bf_pk_…`;
    /// - `BFOCUS_USER_HASH`: em produção, venha do SEU servidor (`sign_widget_identity`);
    /// - `BFOCUS_MOCK_URL`: `http://127.0.0.1:8787` para usar o servidor simulado
    ///   (`node widgets-native/conformance/mock-server.mjs`).
    static func start() {
        let env = ProcessInfo.processInfo.environment
        let mock = env["BFOCUS_MOCK_URL"].flatMap(URL.init(string:))
        BFocus.shared.onError = { error in
            print("bFocus erro: \(error)")
        }
        do {
            try BFocus.shared.initialize(config: BFocusConfig(
                publishableKey: env["BFOCUS_KEY"] ?? "bf_pk_test_123",
                user: BFocusUser(externalId: "USR-1", name: "Ana Souza", email: "ana@empresa.com.br"),
                customer: BFocusCustomer(externalId: "ACME-1", name: "ACME Ltda"),
                userHash: env["BFOCUS_USER_HASH"],
                apiBaseUrl: mock ?? BFocusConfig.defaultApiBaseUrl,
                embedBaseUrl: mock?.appendingPathComponent("v1") ?? BFocusConfig.defaultEmbedBaseUrl
            ))
        } catch {
            print("bFocus: \(error.localizedDescription)")
        }
    }
}
