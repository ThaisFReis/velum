# Validação técnica — 2026-08-04

Fontes: código clonado em `refs/` (lido, não especulado), blog SDF do developer preview
(2026-06-29), docs oficiais de privacidade (developers.stellar.org, 2026-08-03), pesquisa de
ecossistema via LumenLoop/Scout.

## Veredito

**Viável.** Os primitivos foram desenhados exatamente para a tese do Velum — pelos próprios
patrocinadores do lane (OZ + Nethermind). O whitespace está na *integração* CT↔RWA e no produto,
não nos primitivos.

## O que já existe (verificado no código)

| Primitivo | Estado |
|---|---|
| CT core | Merged no `main` de `OpenZeppelin/stellar-contracts` (`packages/tokens/src/confidential/`). Pedersen/Grumpkin + UltraHonk (Noir). Deploy = 3 contratos: token + auditor registry + verifier registry. **Testnet only** — verifier `NethermindEth/rs-soroban-ultrahonk` em desenvolvimento, não auditado |
| ComplianceHooks | Turnkey: `freeze/unfreeze/is_frozen`; `sac_passthrough` (freeze do issuer via `set_authorized` do SAC cascateia — "transitive compliance", CAP-0046-06); trait `Policy::is_authorized(account, token)` externa e rotacionável |
| Hooks customizáveis | `on_deposit` (gating de depositante), `on_register` (restringir auditores aprovados — `ApprovedAuditorHooks`) |
| `set_spender` / `confidential_transfer_from` | Implementados (circuito Noir próprio). Policy gate no grant E no spend. Sealed-bid é viável |
| Selective disclosure | Camada off-chain especificada (`SELECTIVE_DISCLOSURE.md`) + circuitos com VKs pinadas no demo (`@ctd/disclosure`) |
| Módulo RWA | T-REX/ERC-3643 completo: `identity_verification/` (registry, claim issuers, claim topics), `compliance/` modular, freeze parcial por endereço, recovery, pause, RBAC, `TransferKind` (forced/recovery isentáveis de policy). `examples/rwa/` tem suite completa com 7 módulos de compliance prontos |
| Demo oficial | `brozorec/stellar-confidential-token-demo`: contratos + `@ctd/sdk` (cripto TS), `@ctd/app` (Next.js + Freighter, prova ~1s no browser), `@ctd/indexer` (Goldsky), roles holder/auditor/verifier. Pina o branch `feat/confidential-verifier-ultrahonk`. **Sem nenhum compliance** |

## O que NÃO existe (= whitespace do Velum)

1. **Ponte Policy↔RWA**: a spec do CT sugere "policy delegates to an identity registry", mas não
   há implementação. `velum-policy` = trait `Policy` chamando `IdentityVerifier` do módulo RWA.
2. **Multi-classe**: dois CTs (sênior/subordinada) compartilhando auditor registry + policy —
   suportado pela spec, nunca montado.
3. **Console de auditor/emissor** de verdade (o demo tem páginas cruas).
4. **Perfis regulatórios como config** (`cvm175.json` → claim topics + módulos + flags).
5. **Clawback confidencial**: `COMPLIANCE.md` §5 é *outline only* — fluxo admin+auditor com
   circuito novo, "deferred to a follow-up revision". **Não implementado na lib.**

## Restrições que moldam a narrativa

- **Clawback**: não prometer. Demo usa o que é real — freeze imediato (contrato + cascata SAC)
  como "isolamento"; seize citado como roadmap da spec §5. Compatível com as 4 hipóteses de
  clawback da Plina (todas começam com congelamento + processo formal).
- **Depósito/saque são públicos** (só saldos e transfers internos são cifrados). Vender como
  feature: subscrição/resgate transparentes (como fundo), mapa de cotistas sigiloso.
- **Mainnet**: CT não aprovado para mainnet — demo em testnet, alinhado com o estágio da Plina.
- **Version skew**: usar a stack pinada pelo demo (branch `feat/confidential-verifier-ultrahonk`),
  não o `main`, para o pipeline de provas.

## Encaixe Plina

- PLINARF/PLINARFB são classic assets com `AUTH_REQUIRED/AUTH_REVOCABLE/AUTH_CLAWBACK_ENABLED` →
  entram no wrapper via SAC **sem reemissão**; `sac_passthrough: true` faz o freeze do issuer
  valer dentro do wrapper.
- Velum = primeiro degrau do M7 (Soroban) do roadmap.
- Console reflete o modelo operacional real: dupla aprovação (jurídico + CTO), 4 hipóteses,
  trilha de auditoria.

## Concorrência

Só `trustless-work/privacy-poc` (2026-08-01, embrionário, sem descrição). Whitespace aberto.
OZ publicou "Privacy in Onchain Finance" (2026-07-29) defendendo exatamente esta tese — os
juízes estão evangelizando o caso de uso que o Velum demonstra.

## Roteiro da demo (90s, esboço)

Tela dividida:
1. Explorer (esquerda): endereços visíveis, valores cifrados — nada legível.
2. Console do auditor (direita): posições decriptadas por classe.
3. Wallet sem KYC tenta receber → rejeitada pela policy (registro compartilhado com o RWA).
4. Emissor congela conta via SAC (`set_authorized`) → freeze cascateia no wrapper sem admin
   espelhar estado.
5. Investidor prova um pagamento específico a um terceiro via selective disclosure — sem expor
   o histórico.
