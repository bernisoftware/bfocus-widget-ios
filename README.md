# BFocusWidget para iOS

> **English summary.** Native iOS (UIKit + SwiftUI) host for the bFocus support widget. It shows the
> same web embed (`embed.html` / `release-notes.html` from the bFocus CDN) inside a `WKWebView` and
> handles the native parts: launcher button with badge, release-notes version pill and mandatory
> acknowledgement banner, `launcher-state` polling (foreground only, widget closed), push (FCM token
> registration + `handlePush`), downloads, external links, offline screen. Swift Package Manager
> only (`https://github.com/bernisoftware/bfocus-widget-ios`, from `0.1.2`), iOS 15+, no third-party
> dependencies. Only the public key `bf_pk_…` and a `userHash` computed **on your server** go into
> the app. API: `BFocus.shared.initialize(config:)`, `open(_:)`, `close()`,
> `openReleaseNotesHistory()`, `refresh()`, `logout()`, `registerPushToken(_:)`, `handlePush(_:)`;
> Combine `@Published` state and closures `onBadgeChanged`, `onReleaseNotesChanged`, `onError`,
> `onOpen`, `onClose`. Views: `BFocusLauncher`, `BFocusReleaseBadge` (SwiftUI) and
> `BFocusLauncherButton` (UIKit).

O widget de suporte do bFocus (chamados, chat ao vivo e release notes) dentro do seu app iOS. É a
**mesma tela do widget web**, carregada da CDN numa `WKWebView`; o pacote cuida só do que é nativo:
botão com badge, pílula de versão, banner de ciência, consulta periódica, push, downloads, links e a
tela de "sem conexão".

- iOS 15+ (o núcleo `BFocusWidgetCore` também compila no macOS 12+).
- Swift Package Manager. Sem CocoaPods.
- **Sem dependências de terceiros**: só frameworks da Apple (Foundation, UIKit, SwiftUI, Combine,
  WebKit, Network).
- Header `X-bFocus-Client: ios/0.1.2`.

## Instalação

No Xcode: **File → Add Package Dependencies…** →
`https://github.com/bernisoftware/bfocus-widget-ios`, regra "Up to Next Major" a partir de `0.1.2`,
produto **BFocusWidget**.

Ou no `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/bernisoftware/bfocus-widget-ios", from: "0.1.2"),
],
targets: [
    .target(name: "MeuApp", dependencies: [
        .product(name: "BFocusWidget", package: "bfocus-widget-ios"),
    ]),
]
```

Antes de publicar, cadastre o **bundle id** do app no bFocus em **Integrações → Apps nativos**. Ele
vira a origem `app://<bundle id em minúsculas>`.

## Início rápido

```swift
import BFocusWidget

// O userHash vem do SEU servidor (nunca calcule no app).
let hash = try await meuBackend.bfocusUserHash()

try BFocus.shared.initialize(config: BFocusConfig(
    publishableKey: "bf_pk_…",
    user: BFocusUser(externalId: "USR-123", name: "Ana Souza", email: "ana@empresa.com.br"),
    customer: BFocusCustomer(externalId: "ACME-001", name: "ACME Ltda", document: "12.345.678/0001-90"),
    userHash: hash,
    userHashProvider: { try await meuBackend.bfocusUserHash() } // opcional, veja "Erros"
))
```

O `initialize` valida a configuração. Uma chave secreta (`bf_whs_…`, `bf_live_…`, `bf_sk_…`),
`http://` fora de `127.0.0.1`/`localhost` ou um id vazio geram `BFocusConfigError`. Chamar de novo
com a mesma configuração não faz nada. Com outro usuário, as WebViews são recriadas.

### Configuração

| Campo | Padrão | Descrição |
|---|---|---|
| `publishableKey` | — | chave pública `bf_pk_…` (obrigatória) |
| `appId` | `Bundle.main.bundleIdentifier` | bundle id cadastrado em Apps nativos |
| `user` / `customer` | — | `externalId` obrigatório; o resto é opcional |
| `userHash` | — | HMAC calculado no servidor |
| `userHashProvider` | — | `async` que devolve um `userHash` novo; chamado após `WIDGET_USER_HASH_INVALID` |
| `product` | — | slug do produto (release notes) |
| `audience` | — | `.external`, `.internal` ou `.both` |
| `locale` | idioma do aparelho | `.ptBR`, `.en` ou `.es` (`pt*` → pt_BR, `es*` → es, resto → en) |
| `showReleaseNotes` | `true` | `false` esconde o splash de novidades dentro dos chamados |
| `autoShowReleaseBanner` | `true` | abre sozinho o banner de ciência |
| `apiBaseUrl` / `embedBaseUrl` | produção | homologação e testes |
| `pollIntervalSeconds` | `60` | intervalo da consulta do `launcher-state` |

## Botão, pílula e abertura

SwiftUI:

```swift
ZStack(alignment: .bottomTrailing) {
    ConteudoDoApp()
    BFocusLauncher()          // botão de 56 pt com o badge ("•", "3", "99+")
        .padding(20)
}
.toolbar { BFocusReleaseBadge() }   // "v4.2.0" ou "—", com ponto quando há novidade
```

UIKit:

```swift
let botao = BFocusLauncherButton()        // 56 × 56, segue o BFocus.shared e abre ao tocar
botao.translatesAutoresizingMaskIntoConstraints = false
view.addSubview(botao)
NSLayoutConstraint.activate([
    botao.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
    botao.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
])
```

A pílula em UIKit: `UIHostingController(rootView: BFocusReleaseBadge())`.

Com o seu próprio botão, use só a API:

```swift
BFocus.shared.open()                    // lista (ou a última tela)
BFocus.shared.open(.new)                // novo chamado
BFocus.shared.open(.ticket("abc-123"))  // um chamado
BFocus.shared.open(.chat)               // chat ao vivo
BFocus.shared.openReleaseNotesHistory()
BFocus.shared.close()
BFocus.shared.refresh()                 // consulta o launcher-state agora
BFocus.shared.prewarm()                 // opcional: carrega a WebView antes do 1º toque
```

O widget abre em tela cheia sobre o controller do topo da janela. Para escolher de onde ele é
apresentado, use `BFocus.shared.presentingViewControllerProvider = { … }`. A WebView fica viva
entre aberturas: fechar só esconde e manda `bfocus:close`, o que desliga o stream do chat.

## Estado e eventos

```swift
// Closures
BFocus.shared.onBadgeChanged = { label in … }            // "" | "•" | "N" | "99+"
BFocus.shared.onReleaseNotesChanged = { state in … }     // state.label, state.dot, state.bannerIds
BFocus.shared.onError = { error in … }                   // error.code, error.detail
BFocus.shared.onOpen = { … }
BFocus.shared.onClose = { … }

// Combine / SwiftUI
BFocus.shared.$badgeLabel.sink { … }
BFocus.shared.errors.sink { … }
@ObservedObject var bfocus = BFocus.shared                // badgeLabel, releaseNotes, primaryColor, isOpen
```

Regras (as mesmas do widget web):

- **Consulta:** logo após o `initialize` e depois a cada 60 s, **só com o app em primeiro plano e
  o widget fechado**. Fechar o widget consulta na hora. Nada mais sai para o bFocus antes da
  primeira consulta terminar, porque ela cria o usuário. Isso inclui a WebView e o registro de push.
- **Badge fechado:** na primeira visita só grava a base (`last_seen`). Depois acende "•" quando há
  evento novo (compara instantes, não texto). O `last_seen` fica gravado por chave + usuário +
  cliente em `UserDefaults`.
- **Badge aberto:** segue o número de não lidos do embed.
- **Banner de ciência:** quando o `launcher-state` traz `banner_ids`, abre em tela cheia **sem
  fechar por gesto**. Ao terminar, fecha e consulta de novo.

## Erros

| Código | Quando | O que fazer |
|---|---|---|
| `WIDGET_USER_HASH_INVALID` | `userHash` recusado | calcule o hash no servidor com o segredo `bf_whs_…` (veja Segurança) |
| `WIDGET_VERIFIED_SESSION_REQUIRED` | o tenant exige `userHash` e ele não veio | passe `userHash` |
| `WIDGET_CONFIG_FAILED` | o embed não conseguiu carregar a configuração | veja `detail` |
| `WIDGET_USER_HASH_PROVIDER_FAILED` | o seu `userHashProvider` lançou erro | veja `detail` |
| outro código / `HTTP_<status>` | 4xx do `launcher-state` (ex.: origem `app://…` não cadastrada) | cadastre o bundle id em Apps nativos |

- Com `userHashProvider`, um 401 de identidade pede um hash novo **uma vez** e repete a chamada.
  O `onError` só é chamado se a repetição também for recusada. Sem provider, é chamado na hora.
- O mesmo código é avisado uma vez enquanto persistir e volta a ser avisado depois de um sucesso.
- Erro de rede e 5xx são ignorados em silêncio; o pacote tenta de novo no ciclo seguinte.
- Sem conexão, o widget mostra a própria tela de "sem conexão", com "Tentar novamente". Ele também
  tenta sozinho quando a rede volta.

## Push

O pacote **não** depende do Firebase: o seu app já tem o FCM e entrega o token e o `userInfo`.
Cadastre a credencial FCM do app no bFocus (Apps nativos). O FCM envia ao iOS com a chave APNs que
você sobe no Firebase.

```swift
// MessagingDelegate (Firebase)
func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
    if let fcmToken { BFocus.shared.registerPushToken(fcmToken) }  // platform padrão "ios"
}

// UNUserNotificationCenterDelegate
func userNotificationCenter(_ center: UNUserNotificationCenter,
                            didReceive response: UNNotificationResponse,
                            withCompletionHandler completionHandler: @escaping () -> Void) {
    let userInfo = response.notification.request.content.userInfo
    Task { @MainActor in
        if BFocus.shared.handlePush(userInfo) { /* era do bFocus: o widget abriu no item certo */ }
        completionHandler()
    }
}
```

- O `registerPushToken` espera a primeira consulta e guarda o token. Se chamado antes do
  `initialize`, ele registra quando a identidade existir; com outro usuário, registra de novo.
- O `logout()` cancela o registro. Depois do próximo login, chame `registerPushToken` de novo.
- O push do bFocus traz `data = {bfocus: "1", type, ticket_id, conversation_id?}`, com `type` entre
  `ticket.reply`, `ticket.status` e `chat.message`. Chamando `handlePush` antes do `initialize`
  (app aberto pelo toque), o widget abre assim que o `initialize` rodar.

## Logout

```swift
BFocus.shared.logout()
```

Para a consulta e cancela o registro de push. Apaga o `last_seen` e os dados da WebView da origem do
embed (localStorage, cookies, cache) e fecha as telas.

## Arquivos, links e downloads

- **Anexos:** o `<input type=file>` já funciona na `WKWebView`. Para "Tirar foto" e "Fototeca",
  declare `NSCameraUsageDescription` (e, se quiser, `NSPhotoLibraryUsageDescription`) no
  `Info.plist` do app.
- **Downloads:** o anexo é baixado com o nome original. Por padrão abre a folha de compartilhar,
  que inclui "Salvar em Arquivos". Para ir direto ao "salvar como":
  `BFocus.shared.downloadStyle = .saveToFiles`.
- **Links:** qualquer link fora da origem do embed abre no navegador do sistema. Para usar
  `SFSafariViewController`, defina `BFocus.shared.externalURLOpener`.

## Modo navegador

No iOS sempre existe `WKWebView`, então o pacote não precisa do modo navegador. Se precisar da URL
(por exemplo, numa extensão), o núcleo monta:
`BFocusEmbedURL.url(for: config, page: .tickets, mode: .browser)`.

## Segurança

- No app vão **só** a chave pública `bf_pk_…` e o `userHash`. **Nunca** `bf_whs_…` (segredo do
  widget), `bf_live_…` ou `bf_sk_…`. O `initialize` recusa essas chaves.
- O `userHash` é `hex(HMAC-SHA256(bf_whs_…, "v1:" + user.externalId + ":" + customer.externalId))`.
  Calcule no seu servidor com os SDKs do bFocus: `sign_widget_identity` (Python),
  `signWidgetIdentity` (Node/Java/.NET)… e entregue ao app pela sua API autenticada.
- Ligue **Exigir sessão verificada** (`require_verified_session`) no tenant. A origem `app://…` é
  só um rótulo, porque qualquer cliente fora do navegador pode mandá-la. A proteção real é o
  `userHash`.
- A ponte aceita mensagens só do **frame principal** da origem do embed (`frameInfo.securityOrigin`)
  e só os tipos conhecidos. A navegação fica presa nessa origem.
- `http://` só é aceito para `127.0.0.1`/`localhost`, em testes.

## Núcleo sem UI (`BFocusWidgetCore`)

Para quem quer montar a própria interface: `BFocusEngine` (consulta, badge, pílula, banner, push),
`BFocusEmbedURL`, `BFocusRequests`/`BFocusAPIClient` (transporte injetável), `BFocusHostMessage` e
`BFocusHostCommand` (ponte), `BFocusPush`. Importar `BFocusWidget` já traz o núcleo.

## Desenvolvimento

```bash
swift test                                   # macOS: conformidade + unidade + integração HTTP
xcodebuild -scheme BFocusWidget -destination 'generic/platform=iOS Simulator' build
scripts/test-simulator.sh                    # iOS Simulator: suíte inteira + ponte numa WKWebView real
SIM_SET=/tmp/sims SIM_UDID=<udid> scripts/test-simulator.sh   # idem, num conjunto de simuladores próprio
```

- Os casos vêm de `Tests/BFocusWidgetTests/Resources/scenarios.json`, uma cópia gerada por
  `node widgets-native/conformance/generate.mjs` no monorepo. **Não edite a cópia.**
- A integração sobe `widgets-native/conformance/mock-server.mjs` (precisa de `node`). Fora do
  monorepo, aponte `BFOCUS_CONFORMANCE_DIR` para essa pasta; sem ela, esses testes são pulados.
- App de exemplo: `Example/BFocusExample.xcodeproj` (SwiftUI). Com o servidor simulado rodando,
  defina `BFOCUS_MOCK_URL=http://127.0.0.1:8787` no scheme.

## Licença

MIT. Copyright (c) 2026 Berni Software.
