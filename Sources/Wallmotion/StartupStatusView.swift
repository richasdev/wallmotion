import SwiftUI
import AppKit

struct StartupStatusView: View {
    let session: ApplicationSession
    let events: LaunchEventRouter
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(session.phase == .busy ? "Wallmotion já está aberto" : (session.phase == .failed ? "Biblioteca indisponível" : "Abrindo biblioteca"), systemImage: "display")
        } description: {
            Text(events.errorMessage ?? session.errorMessage ?? (session.phase == .busy
                ? "A biblioteca está em uso por outra instância. Os arquivos recebidos serão enviados para ela."
                : "Preparando sua biblioteca com acesso exclusivo."))
        } actions: {
            if events.isForwarding || session.phase == .preparing {
                ProgressView().controlSize(.small)
            } else {
                Button("Tentar novamente", action: onRetry)
                if events.waitingForInitialFiles {
                    Button("Exibir Wallmotion e encerrar esta instância") { events.activateAndClose() }
                }
            }
            Button("Encerrar esta instância") { NSApp.terminate(nil) }
        }
        .padding(24)
    }
}
