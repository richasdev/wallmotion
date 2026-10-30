import SwiftUI

struct SettingsView: View {
    @State private var controller: LoginItemController

    init(controller: LoginItemController = LoginItemController()) {
        _controller = State(initialValue: controller)
    }

    var body: some View {
        Form {
            Section("Início da sessão") {
                Toggle("Abrir Wallmotion ao iniciar sessão", isOn: Binding(
                    get: { controller.status.isEnabled },
                    set: { controller.setEnabled($0) }
                ))
                LabeledContent("Estado", value: statusDescription)
                if controller.status == .requiresApproval {
                    Text("O macOS precisa de aprovação. Ative Wallmotion em Ajustes do Sistema > Geral > Itens de Início.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Abrir Ajustes do Sistema") { controller.openLoginItemsSettings() }
                }
                if let error = controller.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: controller.status == .requiresApproval ? 230 : 170)
        .onAppear { controller.refreshStatus() }
    }

    private var statusDescription: String {
        switch controller.status {
        case .enabled: "Ativo"
        case .requiresApproval: "Aguardando aprovação"
        case .notRegistered: "Desativado"
        case .unavailable: "Indisponível"
        }
    }
}
