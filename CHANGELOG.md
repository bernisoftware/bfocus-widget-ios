# Changelog

Formato: [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/). Versões: [SemVer](https://semver.org/lang/pt-BR/).

## [0.1.0] - 2026-09-15

Primeira versão (Host Protocol v1).

### Adicionado

- `BFocus.shared`: `initialize(config:)`, `open(_:)`, `close()`, `openReleaseNotesHistory()`,
  `refresh()`, `logout()`, `registerPushToken(_:platform:)`, `handlePush(_:)` e `prewarm()`.
- Estado por Combine/SwiftUI (`@Published badgeLabel`, `releaseNotes`, `primaryColor`, `isOpen`;
  `errors`) e por closures (`onBadgeChanged`, `onReleaseNotesChanged`, `onError`, `onOpen`, `onClose`).
- `BFocusViewController`: embed em tela cheia numa `WKWebView` mantida viva entre aberturas, ponte
  `webkit.messageHandlers.bfocus` restrita ao frame principal da origem do embed, navegação travada,
  downloads (compartilhar ou "salvar como"), `alert/confirm/prompt` do JS, "carregando" até o
  `bfocus:ready` e tela "sem conexão" com nova tentativa (inclusive automática quando a rede volta).
- Banner de ciência das release notes em tela cheia, sem fechar por gesto.
- `BFocusLauncherButton` (UIKit), `BFocusLauncher` e `BFocusReleaseBadge` (SwiftUI).
- `BFocusWidgetCore` (Swift puro + Foundation, também no macOS): payload/base64 do usuário, URL do
  embed (RFC 3986, parâmetros no fragmento), cliente do `launcher-state` com `URLSession` injetável,
  badge com `last_seen` persistente, pílula de versão, push e mensagens da ponte.
- Suíte de conformidade sobre `scenarios.json`, integração HTTP com o servidor simulado e integração
  da ponte numa `WKWebView` real no iOS Simulator.
