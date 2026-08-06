# Roteiro de vídeo — 3 minutos

Instruções em PT-BR (para quem grava). **Narração em inglês** — o júri é OpenZeppelin e
Nethermind. Se preferirem narrar em PT-BR, o roteiro funciona igual; só troquem as falas.

---

## Antes de gravar

**O tempo real das demos não cabe no vídeo.** Medido nesta máquina:

| Demo | Duração real | Onde o tempo vai |
|---|---|---|
| `demo-attest.ts` | **3m39s** | confirmação de transação em testnet (register, deposit, merge, attest) |
| `demo-gate.ts` | **1m55s** | idem |
| `demo-seize.ts` | ~3m | idem (opcional — só se sobrar tempo na cena 5) |
| *a prova em si* | **2,06s** | é a parte rápida |

Ou seja: **grave cada demo separadamente e acelere a espera na edição** (3–4× nos trechos de
confirmação, tempo real nos momentos de revelação). O que não pode é o vídeo virar tela de
espera — e também não pode ser recortado a ponto de parecer encenado. A saída honesta é acelerar
visivelmente, com o relógio correndo na tela.

**Checklist:**

- [ ] Terminal com fonte grande (18–20pt), tema escuro, janela limpa — sem abas nem notificações
- [ ] `export PATH="$HOME/.nargo/bin:$PATH"` no shell
- [ ] `cd refs/ct-demo/packages/sdk` (é de onde as demos rodam)
- [ ] Navegador com duas abas prontas: o repositório no GitHub e o stellar.expert
- [ ] Gravar em 1080p; áudio com fone, não microfone de notebook

---

## Cena 1 — O paradoxo (0:00 – 0:25)

**Tela:** slide 2 do deck (`docs/Velum-Deck.pdf`), ou só você falando.

> "Tokenizing a regulated fund on a public ledger makes it *less* private than the paperwork it
> replaces. In a filing cabinet, the register of holders sits with the administrator. On-chain,
> anyone reads who subscribed, how much, and when they left.
>
> Confidential Tokens fix the balances. They do not fix compliance."

---

## Cena 2 — As duas metades (0:25 – 0:50)

**Tela:** slide 3 do deck.

> "Compliance asks two questions. *Who may hold* — upstream answers with a flat address allowlist.
> And *how much may they hold* — which is structurally impossible at that interface: it receives an
> address and never a value, because balances are commitments.
>
> Velum answers both. Here is the first."

---

## Cena 3 — Gating por identidade, ao vivo (0:50 – 1:25)

**Comando** (acelerar a espera na edição):

```bash
VELUM_TOKEN=CBDT4EKUF66MS7HHDHMLDPDI7TOPZCV7AYYLC53ES7TEB67KAT3BFWV5 \
  pnpm exec tsx ../../../../scripts/demo-gate.ts
```

**Tela:** terminal. Deixe a saída completa aparecer:

```
[velum-alice] KYC claim from an approved issuer
  ✅ accepted — already registered; a policy-gated deposit went through

[velum-bob] no identity registered
  ⛔ refused — #3602 NotAuthorizedByPolicy
```

> "Two wallets, same operation, same token. Alice carries a KYC claim signed by an approved
> issuer — accepted. Bob carries no identity — refused.
>
> And notice what that refusal is *not*. Bob produced a perfectly valid zero-knowledge proof for
> the register circuit. It never mattered. Identity is checked before the proof is considered, so
> cryptographic correctness cannot buy entry to a regulated asset."

---

## Cena 4 — Prova de posição, verificada on-chain (1:25 – 2:20)

**Comando:**

```bash
VELUM_ATTEST=CBCBSILY5B562Q263W4EDYU7IHBV3SSM3IFWA333MII3OK3QRGNCDXKY \
  pnpm exec tsx ../../../../scripts/demo-attest.ts
```

**Momento-chave 1** — pausar em tempo real quando aparecer o commitment:

```
position established. On the explorer this balance is a commitment:
  C_spend.x = 0x1c37cfd2395d01244935ca8eef123da331b2a55b4b86f600b43262373b50e429
```

> "This holder has a real position. On the explorer it is a commitment — a point on a curve.
> Nobody can read the amount."

**Momento-chave 2** — quando a atestação passar, **corte para o stellar.expert** com a transação
aberta:

```
proof: 14592 B in 2.68s
✅ attested on-chain — tx …
is_attested(max_age=1000) = true
```

> "The holder proves the position clears five hundred thousand. A Soroban contract reads the
> commitment and the viewing key from the token, the threshold from its own regulatory profile,
> verifies the proof — and records the fact.
>
> The contract learned one thing: the threshold is cleared. Not the amount. Nobody learned the
> amount, the verifier included."

**Momento-chave 3** — a tentativa falsa:

```
[4/4] the same holder claiming a threshold above their position
  ✅ refused: the witness cannot be built, so no proof exists to submit.
```

> "And a false claim? It cannot even be constructed. The failure happens before a proof exists —
> not at verification, but before it."

---

## Cena 5 — Por que acreditar no problema (2:20 – 2:45)

**Tela:** slide 8 do deck, ou o trecho do `COMPLIANCE.md` upstream aberto no GitHub.

> "Why believe any of this is a real gap? Because they wrote it down. This is OpenZeppelin's own
> compliance spec, on why individual clawback is unsolved: *'because the clawback circuit does not
> have access to vk_A… the follow-up revision will pin down whether it is supplied as a private
> witness or derived from a separately escrowed value.'*
>
> They name the obstacle and list the remedy. We took the second option, said what to escrow, and
> verified it in code — premise, circuit, and the circuit running on-chain: an authority proving a
> partial seizure fits inside a position it cannot read.
>
> Along the way we found seven defects in their material. The sharpest is in the specification
> itself: its disclosure flow reads only the spendable commitment, which is harmless for a floor
> and evadable for the ceiling variant it names in the same sentence — park value on the receiving
> side and you are under any cap. We bind both. A second one matters too: a claim topic with no
> trusted issuer is skipped in silence, so an operator who tightens the rules and forgets the
> issuer gets no enforcement at all. Our adapter fails closed on that."

---

## Cena 6 — Fecho honesto (2:45 – 3:00)

**Tela:** slide 9 (limites), depois o repositório.

> "What we are not claiming. This is developer-preview cryptography — the verifier is unaudited,
> testnet only. The seizure verifies, but no value moves — that needs an entry point inside the
> token — and the key escrow behind it is designed and priced, not built. And predicates over
> encrypted aggregates across accounts remain open, as far as we can tell, on any chain.
>
> Everything is MIT, on GitHub, with every address and hash in the implementation record.
> 'Regulated' and 'public' stop being opposites."

---

## Se algo falhar na gravação

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| `#3500 AccountAlreadyRegistered` | conta já registrada de um teste anterior | é esperado; a demo cai para depósito automaticamente |
| `#3602` para a Alice | o registro de claims foi alterado | conferir `is_authorized` direto na policy antes de gravar |
| Erro de VK / prova rejeitada | prova gerada por caminho diferente do da VK | usar sempre o `CircuitProver` do SDK, nunca o `bb` CLI |
| Demora acima do medido | congestão da testnet | gravar de novo; não editar para parecer mais rápido do que foi |

**Ensaiar uma vez antes de gravar.** As duas demos juntas levam ~5m30s de relógio real.
