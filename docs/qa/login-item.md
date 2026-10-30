# QA do início automático

## Validação manual

- [ ] Em Ajustes > Início da sessão, habilitar o início automático e confirmar o estado no macOS.
- [ ] Se o macOS solicitar aprovação, aprovar Wallmotion em Ajustes do Sistema > Geral > Itens de Início; voltar ao app e confirmar que o estado atualizou.
- [ ] Desabilitar o serviço em Ajustes do Sistema enquanto Settings permanece aberta; voltar ao app e confirmar que toggle e estado atualizaram.
- [ ] Desabilitar o início automático pelo próprio painel Settings e confirmar sua remoção.

## Limitações e validação do bundle

O login item usa `SMAppService.mainApp` (macOS 13+, com deployment target macOS 14). O app não registra o serviço no lançamento: o cadastro ocorre apenas quando a pessoa ativa a opção em Ajustes. A interface reflete o status reportado pelo serviço e oferece um atalho para Ajustes do Sistema quando o macOS exige aprovação.

Builds ad-hoc podem não ser aceitos ou persistidos pelo macOS como login item. Valide aprovação e persistência em bundle assinado para distribuição. Os testes automatizados usam um serviço fake e não registram login item real nem alteram preferências do usuário.
