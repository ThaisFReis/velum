# Circuitos Velum

## `disclose_balance_ge` — prova de posição contra limiar regulatório

Implementação da **§9 do `SELECTIVE_DISCLOSURE.md`** da OpenZeppelin (circuito D-balance,
variante predicado). A spec define quatro circuitos de disclosure; o demo oficial entrega dois
(`disclose_recipient`, `disclose_sender`). Este é um dos que faltavam.

**O que ele prova:** *"minha posição confidencial é ≥ X"* — sem revelar quanto é. Não há
ciphertext para decriptar: **a validade da prova é a afirmação**.

**Por que importa para fundo regulado:** regra de montante não é expressável na interface
`Policy` do token (ela vê só o endereço, porque saldo é commitment), e o *remetente* de uma
transferência não consegue provar nada sobre o saldo do destinatário — não tem a abertura dele.
O titular tem. Então a metade quantitativa do compliance é provável exatamente onde a abertura
mora:

- `disclose_balance_ge` → **"posição ≥ mínimo de investidor qualificado"** (CVM 175)
- `disclose_balance_le` → **"posição ≤ limite de concentração"** (irmão, mesmo formato)

### Estado — validado ponta a ponta em 2026-08-04

| Etapa | Resultado |
|---|---|
| `nargo test` | ✅ **10/10** |
| `nargo execute` (witness) | ✅ 0,07s |
| `bb write_vk` | ✅ 0,21s — VK de 1.764 B |
| `bb prove` | ✅ **0,25s** — prova de 14.592 B, 6 inputs públicos (192 B) |
| `bb verify` | ✅ **"Proof verified successfully"** |
| Alegação falsa (posição 1M alegando ≥ 5M) | ✅ **"Failed assertion"** — a testemunha sequer é construível |

Cobertura dos testes: aceita acima do limiar, exatamente no limiar e com limiar zero; rejeita
abaixo do limiar, abertura de commitment falsa, chave secreta de outro titular, replay em outro
token (`addr_f` diferente), commitment obsoleto e limiar malformado perto do módulo do corpo.

### Restrições (spec §9)

| # | Restrição |
|---|---|
| D1 | `vk_A = Poseidon2(δ_vk, sk_A, addr_f)` — viewing key ligada ao contrato |
| D2 | `PVK_A = vk_A · H` — liga a prova ao registro on-chain da conta |
| DB3 | `C_spend = v_s·G + r_s·H` — abertura do saldo corrente (binding de Pedersen ⇒ `v_s` **é** o saldo) |
| D5 | `v_s ∈ [0, 2^127)` — impede negativo enrolado satisfazer o predicado |
| DB4 | `v_s ≥ v_threshold`, como diferença não-negativa |
| DB4b | `v_threshold ∈ [0, 2^127)` — **defensivo, além da spec**: limiar malformado tornaria DB4 vazio |

### Verificação on-chain (§§5.4 e 14 — "out of scope" upstream)

Upstream verifica disclosure **off-chain** e marca o verificador on-chain como fora de escopo.
A variante predicado não tem U-block (nada a decriptar), então é exatamente a forma que um
verificador on-chain consome. A fronteira de confiança da §5.2 dita o trabalho do contrato —
**todo input público vem de outro lugar que não o provador**:

```
addr_f, PVK_A, C_spend  ← lidos do contrato do token confidencial
v_threshold             ← lido do contrato de perfil regulatório
prova                   ← única coisa que o provador fornece
```

Frescor: `C_spend` é lido do estado vivo, então a prova para de verificar no instante em que o
saldo se move. Uma prova antiga só pode ser reapresentada contra o estado para o qual foi feita
— onde continua verdadeira.

### Reproduzir

```bash
noirup --version 1.0.0-beta.11
bbup -v 0.87.0
cd circuits/disclose_balance_ge
nargo test
nargo execute witness
bb write_vk --scheme ultra_honk -b target/disclose_balance_ge.json -o target/
bb prove    --scheme ultra_honk -b target/disclose_balance_ge.json -w target/witness.gz -o target/
bb verify   --scheme ultra_honk -k target/vk -p target/proof -i target/public_inputs
```

Depende de um checkout da OZ em `refs/oz-stellar-contracts-ct-branch` (mesma convenção do demo
upstream, que também usa path-dependency para o `stellar_confidential_lib`).

> ⚠️ **Não é production ready.** Construído sobre o developer preview do Confidential Token,
> cujo verificador UltraHonk e circuitos são não auditados. Testnet apenas.

---

## `seize` — clawback individual sob confidencialidade (Teste B, 2026-08-05)

O circuito de enforcement da §11 do whitepaper: o **auditor** (não o titular) prova que conhece
as aberturas dos commitments do alvo, que `α ≤ v_s + v_r`, e que o estado pós-apreensão foi
escrito pelas derivações canônicas do protocolo — de modo que a wallet do titular continua
funcionando depois, sem handoff. As testemunhas são exatamente o que o Teste A
(`experiments/clawback-poc`) provou serem recuperáveis via escrow de `vk`.

### Estado — validado ponta a ponta

| Etapa | Resultado |
|---|---|
| `nargo test` | ✅ **11/11** (3 aceitações · 7 fraudes rejeitadas · round-trip do titular) |
| Custo | **93 ACIR opcodes** — mais barato que o transfer (133) |
| `bb prove` | ✅ **0,33s** |
| `bb verify` | ✅ "Proof verified successfully" |
| Fraude (α acima do total) | ✅ testemunha inconstruível ("Failed assertion") |

### Restrições (Z1–Z7)

| # | Restrição | Papel |
|---|---|---|
| Z1 | `PVK_A = vk·H` | liga o `vk` do escrow à conta-alvo; prova de uma conta não se aplica a outra |
| Z2 | `C_spend = v_s·G + r_s·H` | abertura do saldo gastável |
| Z3 | `C_receive = v_r·G + r_r·H` | abertura do receiving (transfers via canal do auditor; depósitos têm blinding zero) |
| Z4 | ranges 127-bit + `remaining = v_s+v_r−α` em range | **o teto: α ≤ v_s + v_r** |
| Z5 | `r_new = derive_spend_r(vk, σ_novo)` | blinding pós-seize pela regra canônica |
| Z6 | `C_spend_new = remaining·G + r_new·H` | novo commitment — a autoridade não pode creditar menos do que a prova implica |
| Z7 | `b̃_new = encrypt_balance(remaining, vk, σ_novo)` | checkpoint decriptável pelo titular |

Inputs públicos (11): `PVK_A`, `C_spend`, `C_receive` (do registro da conta congelada),
**`α` (o ponto: é público)**, `σ_novo`, `C_spend_new`, `b̃_new`. Testemunhas privadas (5):
`vk, v_s, r_s, v_r, r_r`.

### Fluxo de contrato pretendido (design, não implementado)

freeze do alvo → auditor monta a prova off-chain → contrato verifica com inputs lidos do
registro congelado → grava `C_spend_new`, zera `C_receive`, transfere `α` do SEP-41 ao emissor,
emite `(b̃_new, σ_novo)`. O freeze pina o estado entre construção e submissão (o próprio
argumento anti-replay upstream).

### Reproduzir

```bash
cd circuits/seize && nargo test
nargo execute witness
bb write_vk --scheme ultra_honk -b target/seize.json -o target/
bb prove    --scheme ultra_honk -b target/seize.json -w target/witness.gz -o target/
bb verify   --scheme ultra_honk -k target/vk -p target/proof -i target/public_inputs
```
