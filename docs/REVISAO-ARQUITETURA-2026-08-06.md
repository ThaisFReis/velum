# Revisão de arquitetura — 2026-08-06

Revisão do Velum **como implementado e no ar**, depois da entrada do `velum-seize`. Três frentes:
a arquitetura em si, a suíte completa de testes, e uma bateria adversarial nova contra os
verificadores em testnet.

O resumo honesto: **a fronteira de confiança se sustentou em todos os nove ataques**, e a revisão
achou um problema real — que não é um bug no que existe, é uma armadilha montada para o próximo
item do roadmap.

> **Atualização, mesmo dia — os dois achados do §3 foram corrigidos.** Ao investigar o §3.1
> descobri que o escopo gastável não era descuido nosso: é o que a `SELECTIVE_DISCLOSURE.md` §9
> da OpenZeppelin manda resolver. Isso promove o achado de "limitação nossa" para **achado
> upstream nº 7** — e o mais sério do conjunto, porque é soundness em especificação, não erro de
> documentação. Correções aplicadas: DB3b no circuito, `C_receive` nos inputs públicos do
> contrato, e `is_attested` agora exige uma janela de frescor. Detalhes no §6.

---

## 1. Baseline: o que roda hoje

| Pacote | Testes | Como foi verificado |
|---|---|---|
| `circuits/disclose_balance_ge` | **14** ✅ | `nargo test` (era 11; +3 nesta revisão, ver §3.1 e §6) |
| `circuits/seize` | 12 ✅ | `nargo test` |
| `experiments/clawback-poc` | 9 ✅ | `nargo test` |
| `experiments/circuit-cap-poc` | 34 ✅ | patch reaplicado sobre o `circuit_transfer` upstream |
| `contracts/` | 3 wasm | `stellar contract build` |

**69 testes.** O número que eu mais desconfiava era o do `circuit-cap-poc`, porque ele não é um
pacote — são dois patches contra o circuito de transferência da OpenZeppelin, e o README manda
rodar só três `nargo test`. Reapliquei os patches sobre `refs/oz-stellar-contracts-main` e rodei:
**34 testes passam e o `nargo info` marca 137 opcodes ACIR**, exatamente os números publicados
(133 → 137, +3 %). A alegação está de pé; o que falta é a instrução de reprodução no README, já
que hoje um jurado não consegue rodar esses 34 pelos comandos publicados.

---

## 2. Bateria adversarial (`scripts/stress.ts`) — 9/9

Os demos mostram o caminho feliz. Esta bateria mostra o sistema **recusando**. Cada probe declara o
que um atacante ganharia se passasse, porque uma recusa só é interessante quando a alternativa era
danosa. Tudo contra os contratos no ar, com duas posições confidenciais reais (1 000 000 e 600 000).

| # | Ataque | O que ele daria ao atacante | Resultado |
|---|---|---|---|
| S1 | prova de H1 para H1 | (linha de base) | ✅ aceito |
| S2 | **prova de H1 submetida para a conta de H2** | certificar um terceiro qualquer | ✅ recusado `#2` |
| S3 | **replay da prova depois do saldo mudar** | manter uma alegação vencida como corrente | ✅ recusado `#2` |
| S4 | prova truncada em 32 bytes | provar que o verificador não lê a prova | ✅ recusado `#2` |
| S5 | **estranho submetendo uma apreensão VÁLIDA** | tornar qualquer um autoridade | ✅ recusado |
| S6 | **a mesma prova válida sob `amount = 1`** | desacoplar o `alpha` da prova | ✅ recusado `#1` |
| S7 | `b_tilde_new = 0xff…ff`, fora do corpo | inputs não checados | ✅ recusado `#2` |
| S8 | valor de apreensão negativo | — | ✅ recusado `#4` |
| S9 | apreensão da posição inteira (`remaining = 0`) | (fronteira) | ✅ aceito |

Os três em negrito são os que importam.

**S2 é o mais crítico**, porque o `attest_position` é *sem autorização* de propósito: qualquer um
pode retransmitir a prova de qualquer um. Isso só é seguro porque as restrições D1/D2 amarram a
prova à viewing key da própria conta, e o contrato lê `PVK_A` e `C_spend` do token, ao vivo. A
recusa confirma o argumento na prática, e não só no papel.

**S3 fecha a pergunta de frescor.** Depositei 1 unidade e refiz o merge — o que muda `C_spend` — e
resubmeti a prova anterior. Recusada. Como o contrato lê o commitment corrente, uma prova vale
apenas contra o estado contra o qual foi feita. Frescor não é uma política que alguém precisa
lembrar de aplicar: é consequência de onde os inputs vêm.

**S5 precisou de um teste separado para ser conclusivo.** Ele falhou on-chain, mas eu não
conseguia distinguir "barrado pelo portão de dono" de "falhou por outro motivo". A checagem
direta via CLI foi mascarada pelo `#3501` (conta não registrada no token), que trava antes do
portão. Resolvi pelo mesmo macro num ponto onde ele não é mascarado — `set_threshold`, que não lê
o token: o não-dono foi recusado com *"Missing signing key for account GAEZBHTK…KZQY"*, que é o
endereço do `admin`. O `#[only_owner]` exige a assinatura do dono. Portão provado.

**S6 é o que garante que a apreensão significa alguma coisa.** Uma prova válida de 250 000,
resubmetida declarando `amount = 1`, é rejeitada — o `alpha` é input público do circuito, então
mudá-lo invalida a prova. A autoridade não escolhe o número depois de provar.

---

## 3. Achados

### 3.1 O `disclose_balance_ge` prova sobre o saldo **gastável**, não sobre a posição

O circuito tem cinco inputs públicos: `addr_f`, `PVK_A`, `C_spend` e o limiar. **Não existe
`C_receive`.** O que ele prova é *"meu saldo gastável ≥ T"*.

Para um **piso**, isso é sólido e apenas conservador: gastável ≤ posição, então provar
gastável ≥ T implica posição ≥ T. Nunca super-declara. O custo é um falso negativo — quem tem
400 000 gastáveis e 200 000 recebidos e ainda não incorporados detém 600 000 e **não consegue**
atestar que passa de 500 000. Em produção isso vira chamado de suporte, não incidente.

Para um **teto**, a mesma omissão inverte de conservadora para insegura. E o teto é exatamente o
item 11 do roadmap, descrito lá como *"`disclose_balance_le` — cópia do `_ge` com DB4 invertida"*.
Se for feito assim, um titular estaciona valor em `C_receive` e prova estar abaixo do teto de
concentração enquanto detém mais que ele. A armadilha já está escrita no plano.

**Remédio, e ele é barato:** o `_le` deve ser modelado no `circuits/seize`, não no `_ge`. O seize
já abre os *dois* commitments (Z2, Z3) e limita a soma (Z4) — o padrão certo já existe no repo.

**Corrigido — ver §6.** E ao investigar, o achado virou do avesso: a omissão não é nossa. É o que
a `SELECTIVE_DISCLOSURE.md` §9 manda o verificador resolver — só `PVK_A` e `C_spend`. Virou o
achado upstream nº 7.

### 3.2 A atestação não expira

O `is_attested(account)` devolve `true` para sempre. A S3 provou que a *prova* não pode ser
replayada depois que o saldo se move — essa é a metade forte. A metade fraca é o registro: a
atestação da S1 continua gravada mesmo depois do saldo mudar, e nada obriga quem lê a olhar o
`attested_at_ledger`.

É a mesma família do achado #6 que reportamos upstream: o caminho mais fácil de ler dá a resposta
menos segura. Duas saídas, com o trade-off explícito:

- **Tirar o `is_attested`** e obrigar o consumidor a ler `attestation()` e aplicar a própria
  janela de validade. Menor mudança, maior ganho — mas empurra política para quem consome.
- **Janela de validade no construtor**, com o `is_attested` respeitando-a. Mais amigável, porém
  coloca política jurisdicional dentro do verificador, que é justamente o que o
  `profiles/cvm175.json` existe para manter fora.

**Corrigido — ver §6**, por um meio-termo entre as duas: a janela existe, mas é *parâmetro* e não
estado do contrato, então a ergonomia fica e a política continua fora do verificador.

### 3.3 Os contratos não têm testes unitários

Três contratos, zero `#[test]`. Toda a verificação é integração on-chain.

Isso não é tão ruim quanto parece: integração em testnet é evidência **mais forte** que teste
unitário, porque exercita o verificador UltraHonk real e as leituras cross-contract de verdade. E
os nove probes acima agora cobrem empiricamente os caminhos de erro (`#1`, `#2`, `#4`, portão de
dono). O que o unitário pegaria barato e o on-chain não pega é o comportamento de funções puras nas
bordas — `encode_amount` em `i128::MAX`, `append_field` no módulo do corpo — sem gastar 40 s de
confirmação por caso.

Trade-off aceito conscientemente para o prazo. Recomendação: manter assim para a submissão, e não
reusar o kit em outro projeto sem um módulo de teste unitário nas funções puras.

### 3.4 Um registro de VK de uma entrada por contrato

`velum-attest` e `velum-seize` mantêm cada um seu registro de VK de entrada única, porque o
`CircuitType` upstream é um enum fechado. Funciona e está documentado. A consequência para um
*kit*, que é a ambição do projeto, é que **cada novo predicado vira um contrato novo** — N
predicados por jurisdição, N deploys. Não é defeito; é um limite de escala que aparece na segunda
jurisdição, não na primeira. A alternativa (um verificador com registro `Map<Symbol, VK>`) custa
abrir mão do helper `verifier::storage` da OpenZeppelin.

---

## 4. O que a revisão confirmou

- **A fronteira de confiança está no lugar certo.** Em S2, S3 e S6, o provador não contribui com
  nada que importe: os três inputs de estado vêm do token, ao vivo. A autoridade escolhe apenas
  `alpha` e `sigma_new` — e a S6 mostra que nem esses ela consegue trocar depois de provar.
- **A assimetria de autorização está justificada.** `attest_position` sem portão (a prova se
  autentica sozinha, S2 confirma), `verify_seizure` com portão (uma apreensão é uma afirmação
  *sobre* alguém, S5 confirma). São escolhas diferentes pela razão certa, não por descuido.
- **As checagens de canonicidade estão vivas** (S7), e não apenas escritas.
- **As fronteiras numéricas estão corretas**: apreensão total com `remaining = 0` (S9), apreensão
  zero, limiar exatamente igual ao saldo — todas já cobertas nos circuitos.

---

## 5. Pendências, em ordem de custo

1. Documentar no README como reproduzir os 34 testes do `circuit-cap-poc` (aplicar os dois
   patches em `refs/`) — hoje o número é publicado sem o comando. **Minutos.**
2. Decidir o §3.2 (expiração da atestação) antes de qualquer reuso. **Uma decisão, não código.**
3. Se o `disclose_balance_le` for construído, modelá-lo no `seize`. O teste do §3.1 já está lá
   para lembrar. **Só quando chegar a vez.**

---

## 6. Correções aplicadas

Ambos os achados do §3 foram fechados no mesmo dia, com `velum-attest` redeployado e a bateria
inteira re-executada contra o contrato novo: **9/9**.

### 6.1 DB3b — o predicado passa a ser sobre a posição

O circuito agora abre os **dois** commitments e limita a soma:

```noir
// DB3b -- o commitment de recebimento abre para v_r
let c_receive_derived = commit(v_r, r_r);
assert(c_receive_derived.x == c_receive_x);
assert(c_receive_derived.y == c_receive_y);
...
// DB4 -- v_s + v_r >= v_threshold
(v_s + v_r - v_threshold).assert_max_bit_size::<127>();
```

O `velum-attest` monta `C_receive` nos inputs públicos junto com o resto do registro que já lia do
token — 6 → 8 elementos de corpo, 192 → 256 bytes. Custo: **43 → 67 opcodes ACIR** e prova de
2,06 s → 2,68 s. Ainda mais barato que o `seize` (93).

Três testes novos no lugar do que documentava a limitação:
`accepts_a_position_split_across_spendable_and_receiving` (400 000 + 200 000 agora atesta contra
500 000), `rejects_a_position_still_short_once_both_sides_are_counted`, e
`rejects_an_unopenable_receiving_balance` — porque DB3b é uma abertura de verdade, não uma
declaração: ninguém infla a posição alegando um `v_r` cujo commitment não consegue produzir.

### 6.2 `is_attested` com janela de frescor

```rust
pub fn is_attested(e: &Env, account: Address, max_age_ledgers: u32) -> bool
```

Sem forma sem argumento. A janela é parâmetro e não estado do contrato porque *quanto tempo uma
atestação continua significando alguma coisa* é pergunta jurisdicional, e é isso que o
`profiles/*.json` guarda. Quem quiser "atestou alguma vez" passa `u32::MAX` — e passa a dizer isso
em voz alta.

Demonstrado no mesmo registro, depois do saldo mudar:

```
is_attested(max_age=1000) = true   is_attested(max_age=0) = false
```

Antes, as duas perguntas devolviam `true`.

### 6.3 O que isso custou em endereço

`velum-attest` mudou de VK, então mudou de endereço:
`CBCBSILY5B562Q263W4EDYU7IHBV3SSM3IFWA333MII3OK3QRGNCDXKY`. O v1
(`CDEDFUYU…7LPK`) segue no ar como controle. README, roteiro de vídeo, perfil regulatório e
registro de implementação foram atualizados.
