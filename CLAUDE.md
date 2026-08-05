# Velum — regras para agentes

Compliance kit + token confidencial (Stellar/Soroban) para o Stellar Summit SP 2026.
**Leia antes de codar:** `README.md` → `docs/WHITEPAPER.md` → `docs/SPIKE-CT-2026-08-04.md`.
Contexto interno do time (estratégia, briefs, material Plina) fica em `internal/` — fora do git.

## Recursos de IA (usar, nesta ordem)

1. **Raven MCP** (`stellar-raven`, já em `.mcp.json` — primeiro uso abre OAuth no browser):
   `search` para docs/ecossistema, `execute` para dados vivos. É a fonte preferida para
   qualquer dúvida de Stellar/Soroban — não responder de memória.
2. **Stellar Skills** (instaladas em `~/.claude/skills`, valem nesta pasta): `soroban` para
   contratos Rust, `dapp` para frontend/SDK JS, `assets` para SAC/trustlines/flags,
   `zk-proofs`, `standards` para SEPs/CAPs. Invocar a skill relevante antes de escrever código
   da respectiva área.
3. **Fallback estático:** <https://developers.stellar.org/llms.txt>.

## Referências locais (`refs/`, gitignoradas — estudo, nunca código submetido)

| Pasta | Uso |
|---|---|
| `refs/oz-stellar-contracts-ct-branch` | **Fonte de verdade do CT** — branch `feat/confidential-verifier-ultrahonk`, pinada pelo demo. Specs em `packages/tokens/src/confidential/docs/` |
| `refs/oz-stellar-contracts-main` | Módulo RWA/T-REX (`packages/tokens/src/rwa/`, `examples/rwa/`) |
| `refs/ct-demo` | Demo oficial (SDK TS, app Next.js, indexer) — base do pipeline de provas |

## Regra permanente: manter o registro de implementação

**Todo passo de implementação, correção de bug ou mudança relevante entra em
`docs/IMPLEMENTATION.md` no mesmo commit da mudança** — não depois, não no fim do dia.

O que registrar:
- endereço de contrato deployado, hash de transação, saída de console real (colada, não parafraseada);
- custo medido (tamanho de prova, opcodes, tempo) — sempre medido, nunca estimado;
- **bugs e becos sem saída**, com a causa-raiz e como foi diagnosticada. Esta seção vale tanto
  quanto a dos sucessos: é o que ninguém documenta e o que economiza horas de quem vier depois;
- o que deixou de funcionar ou ainda não foi feito, na seção final.

Se a mudança não produz evidência nova (refactor puro, ajuste de texto), não precisa entrar.

## Restrições validadas (não violar)

- **Clawback confidencial não existe upstream** (COMPLIANCE.md §5 é spec com lacuna aberta).
  Nós entregamos premissa + circuito verificados (`experiments/clawback-poc`, `circuits/seize`),
  mas **não** a migração — nunca prometer clawback pronto para produção.
- **Testnet only** — verifier UltraHonk não auditado; nada de mainnet.
- Para o pipeline de provas, usar a **branch pinada pelo demo**, não o `main` da OZ.
- Depósito/saque são públicos por design — narrar como transparência de subscrição/resgate.

## Regras do bounty

Trabalho **100% original** (por isso `refs/` e `internal/` ficam fora do git) · máx. 2 sub-lanes por time ·
submissão editável única por sub-lane.

## Convenções

Docs, commits e comunicação em **PT-BR**; código e identificadores em inglês. Contratos Rust
seguem o estilo da OZ stellar-contracts (é a lib que estendemos).
