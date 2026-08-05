# Clawback PoC — Teste A da premissa da §11 (2026-08-05)

Verifica em código a premissa criptográfica da proposta de clawback individual do whitepaper
(§11 — escrow da viewing key ao auditor no registro), usando as **funções exatas da lib de
circuitos da OpenZeppelin** (`stellar_confidential_lib`), sem mock de nenhuma primitiva.

## Resultado: **9/9 testes verdes** (`nargo test`, ~0,5s)

| Teste | O que prova |
|---|---|
| `auditor_recovers_value_and_blinding` | Com **apenas** `vk` + `σ` (público, do evento) + `b̃` (público, do evento), o auditor reconstrói `(v_s, r_s)` e a abertura bate com o commitment on-chain |
| `holder_and_auditor_derive_identical_material` | O `vk` que o escrow entregaria (derivado de `sk` no registro, R2) é exatamente o que o auditor usa — o ciclo escrow→uso fecha |
| `wrong_vk_fails` | `vk` errado não abre nada (should_fail) |
| `wrong_sigma_fails` | `σ` errado não abre nada (should_fail) |
| `partial_seizure_rederivation` | **Apreensão parcial**: o auditor deriva o blinding pós-seize pela regra canônica (`derive_spend_r(vk, σ_novo)`) e o titular, por recuperação ordinária de wallet (só com `sk`), rederiva o **mesmo** blinding e abre o **mesmo** commitment — sem handoff out-of-band |

## Descoberta que simplifica o desenho da OZ

`encrypt_balance(v, vk, σ) = v + Poseidon2(ENCRYPTED_BALANCE, [vk, σ])` — o checkpoint do saldo
é decriptável com `vk` **sozinho**. Ou seja: com o escrow de `vk`, o auditor recupera o **valor
e o fator de ocultação** do lado gastável diretamente, sem depender do canal de auditoria
(ECDH por transferência) que a spec §5 da OZ usa nesse papel. O fluxo de seize fica mais
simples do que o esboço upstream.

## Armadilha de implementação encontrada (revisão arquitetural, 2026-08-05)

Pedersen é aditivamente homomórfico, mas os blindings são **escalares da Grumpkin** — e o campo
escalar da Grumpkin é o campo **base** do BN254 (Fq), módulo diferente do `Field` do Noir (Fr).
Somar blindings como `Field` só coincide com o grupo enquanto a soma não dá wrap. Dois valores
do tamanho de um Poseidon divergem — silenciosamente.

Dois testes fixam isso (`small_blindings_add_in_field` ✅ e
`poseidon_sized_blindings_do_not_add_in_field` should_fail ✅).

**Consequência para o seize:** a agregação das contribuições do lado receiving tem de ser feita
na aritmética escalar da curva — trivial off-chain (Rust/TS), cara em circuito (aritmética de
campo não-nativa). É exatamente por isso que `circuits/seize` recebe `(v_r, r_r)` **já agregados**
como testemunha privada e só verifica a abertura: a agregação pertence ao SDK do auditor. Um
`r1 + r2` ingênuo em `Field` falharia sem avisar.

## Estado pós-merge (caso adversarial)

`merge` é point-add puro, **sem prova e sem checkpoint novo** — então o commitment gastável vira
um agregado. Dois testes cobrem: `ecdh_symmetry_gives_auditor_the_transfer_blinding` (o auditor,
com `vk` e o `R_e` público do evento, deriva o mesmo segredo ECDH que o remetente usou) e
`auditor_reconstructs_merged_commitment_from_components` (reconstrói cada parcela e a soma dos
pontos bate com o commitment merged). Nada falta à visão do auditor.

## O que este teste NÃO prova (honestidade de escopo)

1. **Lado receiving — verificado por leitura, não por teste.** `C_receive` acumula
   transferências (aberturas recuperáveis pelo canal do auditor) e depósitos — e o código do
   contrato (`storage.rs::deposit`) soma depósitos como `amount * G`, **blinding zero**, já que
   o valor é público. Toda parcela do commitment receiving tem abertura produzível pelo
   auditor. Confirmado no código-fonte; não coberto por teste executável neste pacote.
2. **O circuito de seize em si** (Teste B — abertura + `α ≤ v_s + v_r` como input público):
   mesmo formato do `disclose_balance_ge`, não construído.
3. **Integração/migração**: escrow no circuito de registro (R6–R8), VK nova, re-registro de
   contas, fork do entry point — custo de engenharia mapeado na §11.6, sem incerteza
   criptográfica.

## Reproduzir

```bash
noirup --version 1.0.0-beta.11
cd experiments/clawback-poc && nargo test
```

Depende do checkout da OZ em `refs/oz-stellar-contracts-ct-branch` (mesmo path-dep dos demais
circuitos do repo).
