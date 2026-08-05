# Velum

> **Privacidade para o mercado, raio-X para o regulador.**
> Compliance kit + token confidencial para ativos regulados na Stellar — sigilo bancário on-chain.

Submissão para o **Stellar Summit SP 2026** (GrantFox), sub-lane **Enterprise, Compliance and RWA**
(patrocínio OpenZeppelin + Nethermind).

## O que é

Compliance de fundo regulado tem duas metades. A OpenZeppelin entregou os primitivos das duas,
mas ligou nenhuma:

| Metade | Pergunta regulatória | Estado upstream | Velum |
|---|---|---|---|
| **Qualitativa** | *Quem* pode deter? | Gating por **endereço** (allowlist/blocklist). Ligar ao registro de identidade do RWA é a issue **#766**, aberta em 06/07/2026, sem release | `velum-policy` — gating por **identidade**: claim de investidor qualificado, emitido por certificador aprovado |
| **Quantitativa** | *Quanto* pode deter? | Impossível na interface `Policy` (recebe endereço, não vê valor — saldo é commitment). A spec define o circuito `disclose_balance` (§9); **nunca foi implementado** | `circuits/disclose_balance_ge` + `velum-attest` — o titular prova *"minha posição ≥ limiar"* e um contrato verifica **sem que ninguém aprenda o valor** |

A verificação **on-chain** de disclosure é marcada como fora de escopo na spec deles (§§5.4, 14).
Hoje toda disclosure é verificada off-chain, no navegador.

## Estado

| Entregável | Estado |
|---|---|
| `contracts/velum-policy` — ponte identidade ↔ Confidential Token | ✅ compila (7.808 B) |
| `circuits/disclose_balance_ge` — spec §9, o circuito que faltava | ✅ **10/10 testes; prova gerada em 0,25s e verificada** |
| `contracts/velum-attest` — verificação on-chain da prova | ✅ compila (36.937 B) |
| `experiments/circuit-cap-poc` — teto por operação no circuito de transfer | ✅ 34/34 testes, +3% de custo |
| `experiments/clawback-poc` — premissa do clawback individual (whitepaper §11) | ✅ 5/5 testes — premissa verificada; seize parcial demonstrado |
| `circuits/seize` — clawback individual: o circuito de enforcement | ✅ **11/11 testes; 93 opcodes; prova 0,33s verificada** |
| Stack CT (verifier, auditor, token, allowlist, blocklist, factory) em testnet | ✅ deployada por nós; e2e verde em 1m4s |
| Stack RWA (claim topics, claim issuer, identidade, registro) em testnet | 🟡 4 de 5 no ar; registro de identidade travado num formato de país |
| Perfil `cvm175.json` · demo · README reproduzível · vídeo | ⬜ |

Todos os números acima foram medidos nesta máquina, não estimados — ver `docs/WHITEPAPER.md` §8.

## Por que importa

Posição exposta on-chain é a objeção nº 1 de instituições em blockchain pública. O CT resolve
confidencialidade **sem** anonimato: endereços visíveis, valores cifrados, auditor designado
enxerga tudo. Mas uma allowlist de endereços não atende CVM 175 — e nenhuma regra de valor é
verificável quando o valor é um commitment. É essa lacuna que o Velum fecha.

Caso de uso âncora: FIDC tokenizado sob CVM 175 (Plina Finance) — o kit serve qualquer emissor
regulado (FIDC, CRI/CRA, precatórios, LATAM em geral).

## Documentos

| Doc | O quê |
|---|---|
| **`docs/Velum-Deck.pdf`** | **Pitch deck (EN)** — 10 slides 16:9 para a apresentação no summit |
| **`docs/Velum-OnePage.pdf`** | **One page (EN)** — a tese, o que foi construído, os números medidos e a citação upstream, em uma folha |
| **`docs/WHITEPAPER.md`** | **Whitepaper técnico (EN)** — a tese "holder-attested compliance", arquitetura, avaliação medida, limitações, trabalho relacionado e o Apêndice A com evidência primária citada linha a linha |
| `docs/SPIKE-CT-2026-08-04.md` | De-risk do pipeline + o achado que corrigiu a premissa do brief |
| `circuits/README.md` | O circuito `disclose_balance_ge`: restrições, resultados, como reproduzir |
| `docs/VALIDACAO-2026-08-04.md` | Primeira validação dos primitivos — **ler junto do SPIKE**, que corrige parte dela |

## Verificação de ineditismo

`disclose_balance` / `_ge` / `_le` / `disclose_auditor` nunca foram implementados. Verificado em
04–05/08/2026 por seis caminhos: busca full-text nos três clones · todas as 16 branches e 10 tags
da OZ · histórico git completo (nunca existiu em commit algum) · mensagens de commit · issues e
PRs (total=0) · busca de código autenticada em todo o GitHub.

> Formulação segura para README e palco: *"não existe publicamente em nenhum repositório, branch,
> tag ou histórico"*. **Não** afirmar "ninguém no mundo fez" — código privado da OZ é possível.

## Achados para PR upstream

1. **`addr_f` não é legível por terceiros** — fica em instance storage e `address_to_field` é
   `pub(crate)`, então um verificador externo não consegue lê-lo nem recomputá-lo. Um getter
   público `address_as_field()` no `ConfidentialToken` resolveria.
2. **Comando documentado que não roda** — `examples/rwa/sign-claim` está no `exclude` do
   workspace mas declara `authors.workspace = true`; o `cargo run --manifest-path` do README
   falha com *"failed to find a workspace root"*.
3. **`--optimize=false`** no `deploy.ts` do demo é incompatível com stellar-cli ≥ 25.2, que
   trata `--optimize` como flag booleana.

## Referências (clones em `refs/`, gitignorados)

| Ref | O quê |
|---|---|
| `refs/oz-stellar-contracts-main` | OZ stellar-contracts `main` — módulos `confidential/` e `rwa/` |
| `refs/oz-stellar-contracts-ct-branch` | Branch `feat/confidential-verifier-ultrahonk`, **checkout no rev pinado `539968f`** |
| `refs/ct-demo` | `brozorec/stellar-confidential-token-demo` — SDK TS, app Next.js, indexer |

Leituras-chave: `confidential/docs/{DESIGN,COMPLIANCE,SELECTIVE_DISCLOSURE,SDK,INDEXER}.md`,
`rwa/mod.rs`, `examples/rwa/`.

- Blog (dev preview, 2026-06-29): <https://stellar.org/blog/developers/developer-preview-confidential-tokens-on-stellar>
- Docs de privacidade: <https://developers.stellar.org/docs/build/apps/privacy>
- Bounty: <https://bounties.grantfox.xyz/events/stellar-summit-sp-2026>

## Toolchain (versões que funcionam)

`nargo 1.0.0-beta.11` · `bb 0.87.0` · `stellar-cli ≥ 25.2` · Rust + `wasm32v1-none` ·
soroban-sdk `=26.1.0` · OZ rev `539968f158e0d779f584de2821090f715a3b25e1`.
Noir **rejeita não-ASCII**, inclusive em comentário.

## Regras do bounty (lembrete)

Máx. 2 sub-lanes por time · presença física de todo o time · **trabalho 100% original**
(por isso `refs/` fica fora do git — referências de estudo, não código submetido).
