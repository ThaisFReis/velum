# PoC — regra regulatória quantitativa sobre valor cifrado (2026-08-04)

Experimento de ~1h para responder: *"dá para fazer o circuito do Confidential Token provar um
limite regulatório sobre um valor que ninguém consegue ler?"*

**Resposta: dá, e é barato.**

## O que foi feito

Sobre `OpenZeppelin/stellar-contracts` @ `main`, circuito `circuit_transfer`, com
`nargo 1.0.0-beta.11` (a versão do `constraints.baseline`):

1. Dois novos **inputs públicos** — `cap_transfer` e `min_ticket` (viriam do contrato de perfil
   regulatório on-chain).
2. Duas restrições, no mesmo idioma do range-check T4 já existente:
   ```noir
   // V1 -- v_transfer <= cap_transfer (teto por operação)
   (cap_transfer - v_transfer).assert_max_bit_size::<127>();
   // V2 -- v_transfer >= min_ticket (ticket mínimo do investidor qualificado)
   (v_transfer - min_ticket).assert_max_bit_size::<127>();
   ```
3. Três testes novos: aceita dentro dos limites, **rejeita acima do teto**, **rejeita abaixo do
   ticket mínimo**.

## Resultado medido

| Métrica | Antes | Depois |
|---|---|---|
| ACIR opcodes (`main`) | 133 | **137 (+3%)** |
| Testes do circuito | 31 ✅ | **34 ✅** (28 originais + 3 Velum + 3 diagnósticos) |
| Tempo de `nargo test` | — | 0,5s |

O verificador nunca aprende `v_transfer`; aprende apenas que a prova **não satisfez** o limite.

## Aprendizados operacionais

- **Noir rejeita não-ASCII** — inclusive em comentários. Código e comentários dos nossos
  circuitos precisam ser em inglês/ASCII (docs continuam em PT-BR).
- `nargo`/`bb` instalam em minutos via `noirup --version 1.0.0-beta.11`; a compilação é
  instantânea (0,08s) — não é gargalo de evento.
- Cuidado: em `transfer/src/tests.nr` a ordem posicional de `run_main` **difere** da de `main`
  (`addr_f` vs `pvk_b_*`). Chamar `main` direto com a lista do fixture embaralha argumentos e
  produz falha silenciosa que parece erro de restrição. Custou 3 iterações.

## Limite estrutural encontrado (importante)

Este PoC limita o **valor da transferência** — que o remetente conhece e portanto pode provar.
Um teto sobre o **saldo do destinatário** não é provável pelo remetente: no modelo Pedersen ele
não conhece a abertura do saldo alheio. Cap de saldo exige prova do próprio titular (no `merge`
ou na transferência seguinte) — ou outro modelo criptográfico (FHE resolve; ZK não).

## Arquivos

- `transfer-main.patch` — as duas restrições e os dois inputs públicos
- `transfer-tests.patch` — os testes de aceitação e rejeição

Aplicar sobre `refs/oz-stellar-contracts-main/packages/tokens/src/confidential/circuits/`.
