import SwiftUI
import BFocusWidget

struct ContentView: View {
    @ObservedObject private var bfocus = BFocus.shared

    var body: some View {
        NavigationView {
            List {
                Section("Widget") {
                    Button("Abrir chamados") { bfocus.open() }
                    Button("Novo chamado") { bfocus.open(.new) }
                    Button("Chat") { bfocus.open(.chat) }
                    Button("Histórico de versões") { bfocus.openReleaseNotesHistory() }
                    Button("Consultar agora") { bfocus.refresh() }
                    Button("Sair (logout)", role: .destructive) { bfocus.logout() }
                }
                Section("Estado") {
                    row("Iniciado", bfocus.isInitialized ? "sim" : "não")
                    row("Badge", bfocus.badgeLabel.isEmpty ? "(vazio)" : bfocus.badgeLabel)
                    row("Versão", bfocus.releaseNotes.label)
                    row("Cor", bfocus.primaryColor ?? "(padrão bFocus)")
                    row("Aberto", bfocus.isOpen ? "sim" : "não")
                }
            }
            .navigationTitle("bFocus")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    BFocusReleaseBadge()
                }
            }
        }
        .navigationViewStyle(.stack)
        .overlay(alignment: .bottomTrailing) {
            BFocusLauncher()
                .padding(20)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }
}
