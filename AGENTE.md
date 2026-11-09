# AGENTE.md --- Diretrizes de Engenharia do Projeto Kyn

> **Projeto:** Kyn\
> **Organização:** Hardion Labs\
> **Repositório:** https://github.com/Hardion-Labs/Kyn\
> **Diretório local esperado:**
> `/home/matheus/Documentos/Hardion-Labs/Kyn/`\
> **Filosofia:** **Explicit Control. Verifiable Safety. Predictable
> Performance.**

Este documento define as responsabilidades, restrições e procedimentos
para qualquer agente de IA ou desenvolvedor automatizado que trabalhe no
projeto Kyn. Estas regras devem ser lidas antes de modificar código,
documentação, configuração ou histórico Git.

------------------------------------------------------------------------

## 1. Missão

Projetar, implementar, testar, documentar e evoluir a **Kyn**, uma
linguagem de programação de sistemas independente, com:

-   controle explícito de memória e recursos;
-   ponteiros e operações de baixo nível explícitos;
-   tipagem estática e rigorosa;
-   verificações de segurança configuráveis;
-   comportamento previsível e ausência de overhead oculto por padrão;
-   runtime opcional;
-   interoperabilidade com C e Zig;
-   geração de código nativo;
-   suporte futuro a sistemas operacionais, kernels, drivers, sistemas
    embarcados e aplicações de alto desempenho.

A Kyn deve possuir identidade, gramática e semântica próprias. C e Zig
são referências técnicas, não modelos a serem copiados.

**Não confunda funcionalidades planejadas com funcionalidades
implementadas.** Toda capacidade anunciada deve estar respaldada por
implementação e testes.

## 2. Decisões tecnológicas

As responsabilidades tecnológicas do projeto são:

  -----------------------------------------------------------------------
  Tecnologia                          Responsabilidade
  ----------------------------------- -----------------------------------
  **Zig**                             Linguagem principal de
                                      implementação do compilador Kyn e,
                                      inicialmente, do `kyn-build`.

  **C**                               Interoperabilidade, C ABI,
                                      integração com bibliotecas e
                                      sistemas existentes, interfaces de
                                      baixo nível e exemplos de
                                      integração.

  **LLVM**                            Backend inicial candidato para
                                      geração e otimização de código
                                      nativo.

  **C ABI**                           Contrato principal de
                                      interoperabilidade entre Kyn, C e
                                      componentes Zig compilados.
  -----------------------------------------------------------------------

### 2.1 Regras para Zig

-   Implemente o frontend e a infraestrutura do compilador em Zig.
-   Utilize allocators explícitos e documente a estratégia de alocação
    de cada subsistema relevante.
-   Defina claramente a propriedade e o ciclo de vida dos dados.
-   Evite alocações desnecessárias, cópias de buffers e conversões
    redundantes.
-   Prefira estruturas de dados adequadas ao padrão de acesso e ao ciclo
    de vida dos dados.
-   Não introduza abstrações complexas sem benefício mensurável ou
    justificativa técnica.
-   Verifique a versão instalada do Zig e consulte a documentação
    correspondente; não presuma que APIs de versões diferentes sejam
    compatíveis.

### 2.2 Regras para C

-   Utilize C quando houver uma necessidade concreta de ABI, integração,
    portabilidade ou compatibilidade com interfaces existentes.
-   Não duplique em C módulos do compilador que já pertencem à
    implementação Zig.
-   Mantenha headers, tipos, convenções de chamada e layouts de
    estruturas coerentes com a especificação ABI da Kyn.
-   Não dependa de comportamento indefinido de C.
-   Compile código C com avisos rigorosos e trate os avisos relevantes
    como erros quando viável.
-   Teste a interoperabilidade com programas reais, não apenas com
    declarações ou stubs.

### 2.3 Regras para LLVM

-   Avalie e documente a versão e o método de integração escolhidos.
-   Isole LLVM atrás de uma interface de backend.
-   A AST, a análise semântica, o sistema de tipos e a IR semântica da
    Kyn não podem depender dos tipos internos de LLVM.
-   Não exponha conceitos específicos de LLVM na especificação da
    linguagem.
-   Preserve a possibilidade de adicionar outro backend no futuro.
-   Não implemente um backend próprio prematuramente sem uma
    justificativa técnica clara.

### 2.4 Build híbrido

O `kyn-build` deverá orquestrar ferramentas existentes para compilar e
linkar componentes Kyn, C e Zig. Não reimplemente compiladores C ou Zig.
A integração com Zig deve ocorrer principalmente por objetos compilados
e C ABI; não implemente um parser da linguagem Zig.

## 3. Princípios inegociáveis da linguagem

A Kyn deve seguir estes princípios:

1.  **Controle explícito:** alocação, desalocação, ponteiros, conversões
    e operações perigosas devem ser claros no código.
2.  **Segurança verificável:** o compilador deve verificar tudo que
    puder provar, sem prometer garantias impossíveis para ponteiros
    crus.
3.  **Previsibilidade:** nenhuma alocação, sincronização, exceção, cópia
    ou chamada de runtime deve surgir silenciosamente sem estar definida
    pela linguagem.
4.  **Tipagem estática:** incompatibilidades devem ser diagnosticadas
    antes da geração de código sempre que possível.
5.  **Sem GC obrigatório:** não introduzir garbage collector como
    requisito do modelo de execução.
6.  **Sem ownership obrigatório:** não impor ownership ou borrow checker
    como condição para escrever programas.
7.  **Runtime opcional:** programas freestanding devem ser possíveis
    conforme a maturidade da toolchain.
8.  **Interoperabilidade explícita:** C ABI deve ser especificada,
    testada e estável dentro das versões compatíveis.
9.  **Semântica independente do backend:** trocar LLVM não pode exigir
    redefinir a linguagem.
10. **Complexidade justificada:** cada recurso novo deve demonstrar
    valor suficiente para justificar custo de implementação, manutenção
    e aprendizado.

## 4. Processo obrigatório antes de modificar o projeto

Antes de qualquer alteração:

1.  Confirme o diretório de trabalho.
2.  Inspecione a estrutura de arquivos.
3.  Verifique `git status`.
4.  Identifique a branch atual e as branches locais.
5.  Verifique os remotes e a URL do remoto oficial.
6.  Consulte o último commit local e o estado do remoto.
7.  Identifique alterações não commitadas e arquivos não rastreados.
8.  Leia a documentação existente relacionada à tarefa.
9.  Verifique versões e disponibilidade das ferramentas necessárias.
10. Apresente um diagnóstico breve e um plano proporcional ao escopo.

Não assuma que o repositório está vazio ou que o estado remoto
corresponde ao estado local. Preserve alterações do usuário.

### Operações proibidas sem autorização explícita

-   `git reset --hard`;
-   `git clean -fd` ou variantes destrutivas;
-   force push;
-   apagar branches ou tags;
-   sobrescrever histórico remoto;
-   apagar arquivos do usuário sem necessidade comprovada;
-   substituir arquivos de configuração sem revisar seu conteúdo;
-   publicar credenciais, tokens, chaves privadas ou dados pessoais.

Se houver conflito, investigue a origem e resolva preservando as
alterações válidas. Se a autenticação remota não estiver disponível,
continue localmente e informe precisamente o bloqueio. Nunca solicite
que o usuário cole tokens ou grave segredos no repositório.

## 5. Arquitetura do compilador

A arquitetura de referência é:

``` text
Source Manager
    ↓
Lexer
    ↓
Parser
    ↓
AST
    ↓
Name Resolution
    ↓
Type Checker
    ↓
Semantic Analysis
    ↓
Static Analysis
    ↓
Semantic IR
    ↓
Optimization
    ↓
Backend Interface
    ↓
LLVM Backend
    ↓
Object Generation
    ↓
Linker
    ↓
Native Executable
```

Cada subsistema deve possuir responsabilidade, interface e testes
definidos. Evite dependências circulares e acoplamento entre frontend e
backend.

### 5.1 Source Manager

Deve centralizar a gestão de fontes, arquivos, buffers, spans e
localização de diagnósticos. Evite cópias integrais desnecessárias de
fontes e tokens.

### 5.2 Lexer

Deve reconhecer tokens, identificadores, palavras reservadas, literais,
operadores, delimitadores e comentários. Cada token relevante deve
manter localização suficiente para diagnósticos precisos.

### 5.3 Parser e AST

-   Defina uma gramática formal e versionada.
-   Documente precedência e associatividade dos operadores.
-   Diferencie erros sintáticos de erros semânticos.
-   Implemente recuperação de erros sem entrar em loops ou produzir
    cascatas excessivas.
-   Evite estruturas de AST ambíguas ou dependentes do backend.

### 5.4 Semântica e tipos

Planeje e especifique antes de implementar:

-   escopos e resolução de nomes;
-   tipos primitivos e compostos;
-   funções e assinaturas;
-   estruturas e enums;
-   arrays e slices;
-   ponteiros e ponteiros anuláveis;
-   conversões explícitas;
-   compatibilidade de tipos;
-   inicialização;
-   fluxo de controle;
-   regras de retorno;
-   símbolos externos e ABI.

Tipos primitivos inicialmente considerados:

`bool`, `i8`, `i16`, `i32`, `i64`, `i128`, `u8`, `u16`, `u32`, `u64`,
`u128`, `f32`, `f64`, `usize`, `isize`, `char` e `void`.

Esta lista é uma proposta de projeto, não uma declaração de suporte
implementado.

### 5.5 Análise estática

Implemente verificações que possam ser justificadas pela semântica, como
uso de símbolos inválidos, variáveis não inicializadas detectáveis,
fluxo de controle inválido, conversões perigosas e operações
comprovadamente inválidas.

Não afirme detectar todos os erros possíveis. Diferencie claramente
diagnóstico estático, verificação em runtime e comportamento não
definido.

## 6. Modelo de memória e segurança

O modelo de memória deve especificar rigorosamente:

-   representação e nulidade de ponteiros;
-   validade e alinhamento de endereços;
-   aritmética de ponteiros;
-   aliasing;
-   inicialização;
-   arrays, slices e limites;
-   alocação e desalocação;
-   layout e alinhamento de estruturas;
-   overflow de inteiros;
-   operações atômicas e acesso concorrente;
-   comportamento definido, não especificado e indefinido.

Verificações candidatas a configuração:

-   bounds checking;
-   overflow de inteiros;
-   divisão por zero;
-   alinhamento;
-   conversões perigosas;
-   assertions e invariantes.

Perfis candidatos: `Debug`, `Safe`, `Release` e `Fast`.

Cada perfil deve ter regras documentadas e testadas. Desabilitar uma
verificação não pode alterar silenciosamente a semântica: o efeito deve
estar especificado. Nunca prometa segurança absoluta quando o programa
pode realizar operações arbitrárias por meio de ponteiros crus.

## 7. Hardware e targets

Planeje suporte incremental para:

-   x86-64 e, posteriormente, AArch64;
-   Linux inicialmente;
-   targets freestanding e bare-metal conforme a maturidade;
-   inteiros de largura fixa;
-   operações bitwise;
-   alinhamento explícito;
-   atomics;
-   tipos ou operações voláteis, se sua semântica for definida;
-   intrinsics e assembly específico de arquitetura;
-   calling conventions e acesso a recursos de hardware.

Separe funcionalidades portáveis das específicas de cada target. Não
prometa suporte a um target sem build e testes reais.

## 8. C ABI e interoperabilidade

A especificação ABI deve cobrir:

-   convenções de chamada;
-   nomes e visibilidade de símbolos;
-   tipos compatíveis;
-   layout e alinhamento de estruturas;
-   passagem e retorno de valores;
-   ponteiros e buffers;
-   importação e exportação de funções;
-   bibliotecas estáticas e dinâmicas;
-   headers C gerados ou mantidos;
-   regras de compatibilidade entre versões.

Crie testes executáveis em ambas as direções: Kyn chamando C e C
chamando Kyn. Inclua também um componente Zig compilado e consumido por
meio de C ABI. Não confunda compatibilidade de build com compatibilidade
ABI.

## 9. Sistema de build `kyn-build`

O `kyn-build` deverá coordenar:

-   compilador Kyn;
-   compilador C, como Clang;
-   compilador Zig;
-   assembler e linker quando necessários;
-   bibliotecas e dependências;
-   arquitetura, sistema operacional e ABI;
-   perfis e opções de otimização;
-   build incremental e cache, quando implementados.

Não implemente cache ou build incremental apenas como aparência: defina
invalidação, dependências e integridade dos artefatos. Registre comandos
e versões das ferramentas relevantes para tornar builds reproduzíveis.

## 10. Organização do repositório

Use uma estrutura modular, ajustando-a quando houver justificativa
técnica:

``` text
Kyn/
├── compiler/
│   ├── source/
│   ├── lexer/
│   ├── parser/
│   ├── ast/
│   ├── semantic/
│   ├── types/
│   ├── analyzer/
│   ├── ir/
│   ├── optimizer/
│   ├── backend/
│   └── diagnostics/
├── build-system/
│   ├── project/
│   ├── dependency/
│   ├── cache/
│   ├── toolchain/
│   └── linker/
├── runtime/
├── std/
├── examples/
├── tests/
│   ├── lexer/
│   ├── parser/
│   ├── semantic/
│   ├── memory/
│   ├── backend/
│   └── interoperability/
├── docs/
├── scripts/
├── .github/
│   └── workflows/
├── README.md
├── LICENSE
└── .gitignore
```

Não crie diretórios vazios sem finalidade. Não force esta estrutura se a
organização real do código justificar outra solução mais simples.

## 11. Qualidade de implementação

-   Código modular, legível e consistente com o formatador oficial.
-   Interfaces internas explícitas.
-   Tipos e invariantes documentados.
-   Tratamento de erros consistente.
-   Diagnósticos úteis, com localização e contexto.
-   Ciclo de vida de memória claro.
-   Ausência de comportamento indefinido acidental no próprio
    compilador.
-   Dependências externas mínimas e justificadas.
-   Sem placeholders apresentados como funcionalidades concluídas.
-   Sem alocações ou cópias ocultas sem justificativa.
-   Sem otimizações prematuras que prejudiquem a correção.

Quando uma decisão envolver trade-offs, registre alternativas, custos,
riscos e justificativa da escolha.

## 12. Testes e validação

Toda funcionalidade deve possuir testes proporcionais ao risco.

Inclua, conforme aplicável:

-   testes unitários por módulo;
-   testes de integração;
-   testes negativos para programas inválidos;
-   testes de regressão;
-   golden tests de diagnósticos e saída;
-   testes de geração e execução de código;
-   testes de ABI e linkedição;
-   fuzzing de lexer e parser quando viável;
-   testes de memória e sanitizadores nas ferramentas compatíveis;
-   benchmarks reproduzíveis para mudanças de desempenho.

Para cada exemplo executável:

1.  compile;
2.  linke;
3.  execute;
4.  verifique o resultado;
5.  teste falhas e casos-limite relevantes.

Nunca declare testes aprovados sem executá-los. Informe comandos,
resultados e limitações reais.

## 13. Documentação

Mantenha a documentação alinhada à implementação. Documentos fundadores
recomendados:

-   `language-design.md`;
-   `language-reference.md`;
-   `grammar.md`;
-   `type-system.md`;
-   `memory-model.md`;
-   `safety-model.md`;
-   `abi.md`;
-   `compiler-architecture.md`;
-   `build-system.md`;
-   `roadmap.md`.

Especifique primeiro as decisões fundamentais de linguagem. Marque
explicitamente recursos como **propostos**, **especificados**, **em
implementação**, **experimentais** ou **estáveis**. Não documente
recursos inexistentes como disponíveis.

## 14. Git, GitHub e publicação

O remoto oficial é `https://github.com/Hardion-Labs/Kyn`. Trabalhe no
diretório local indicado quando esse ambiente estiver disponível.

-   Preserve a branch e as alterações existentes.
-   Faça commits pequenos, atômicos e descritivos.
-   Revise `git diff` e `git status` antes de cada commit.
-   Execute os testes relevantes antes de publicar.
-   Sincronize com o remoto sem sobrescrever histórico.
-   Respeite proteções de branch; use branch de trabalho e Pull Request
    quando necessário.
-   Nunca publique segredos, arquivos pessoais, caches ou artefatos
    locais desnecessários.
-   Não afirme que publicou algo se o push não foi confirmado.

Exemplos de mensagens:

``` text
docs: define initial Kyn language principles
chore: establish Zig compiler workspace
feat(lexer): tokenize integer literals
feat(parser): parse function declarations
feat(semantic): validate function signatures
test(abi): cover C and Zig interoperability
```

Se o ambiente não tiver acesso ao diretório local ou à autenticação
GitHub, não simule acesso. Continue apenas nas tarefas possíveis e
informe o que depende do usuário.

## 15. CI

Configure GitHub Actions para executar, conforme a maturidade do
projeto:

-   verificação de formatação;
-   build do compilador Zig;
-   build dos componentes C;
-   testes unitários e de integração;
-   testes de regressão;
-   validação de exemplos;
-   verificação documental;
-   builds por target suportado.

Não declare um workflow funcional antes de observar uma execução
bem-sucedida.

## 16. Execução incremental

Trabalhe em etapas pequenas, verificáveis e integradas:

1.  **Auditoria:** estado do repositório, ferramentas, dependências e
    riscos.
2.  **Fundação:** decisões de linguagem, gramática, tipos, memória,
    segurança e ABI.
3.  **Infraestrutura:** workspace Zig, sistema de testes, diagnósticos e
    CI.
4.  **Frontend:** Source Manager, lexer, parser e AST.
5.  **Semântica:** símbolos, escopos, tipos e análise estática.
6.  **IR e backend:** IR semântica, interface de backend e integração
    LLVM.
7.  **Memória e segurança:** ponteiros, arrays, slices, layout e
    verificações.
8.  **Interoperabilidade:** C ABI, componentes C e Zig, bibliotecas e
    linker.
9.  **Build:** `kyn-build`, targets, perfis, dependências e cache.
10. **Estabilização:** regressões, fuzzing, benchmarks, documentação e
    compatibilidade.

Cada etapa deve produzir entregáveis reais, testes e documentação. Não
avance para recursos complexos enquanto as invariantes da etapa anterior
estiverem instáveis.

## 17. Conduta do agente

O agente deve:

-   agir como engenheiro responsável pela qualidade técnica;
-   inspecionar antes de alterar;
-   implementar, compilar, testar e corrigir, em vez de apenas criar
    planos;
-   explicar decisões arquiteturais relevantes;
-   dividir tarefas grandes em entregas pequenas;
-   reconhecer limitações e incertezas;
-   manter documentação e testes atualizados;
-   preservar dados, histórico e alterações do usuário;
-   relatar com precisão o que foi alterado e o que foi validado.

O agente não deve:

-   inventar resultados de comandos ou testes;
-   declarar funcionalidades concluídas com base em stubs;
-   adicionar dependências sem avaliar custo e necessidade;
-   misturar semântica da linguagem com detalhes de LLVM;
-   implementar parser Zig ou compilador C próprio;
-   fazer mudanças destrutivas ou publicar alterações não revisadas;
-   sacrificar correção por benchmarks ou aparência de progresso.

## 18. Formato de relatório ao concluir uma tarefa

Ao terminar cada unidade de trabalho, informe:

1.  **Objetivo:** o que foi solicitado.
2.  **Alterações:** arquivos e módulos modificados.
3.  **Decisões:** escolhas técnicas e justificativas.
4.  **Validação:** comandos executados e resultados observados.
5.  **Limitações:** o que ainda não foi implementado ou validado.
6.  **Git:** branch, commit e estado de publicação, quando aplicável.
7.  **Próximo passo:** a menor próxima entrega lógica.

------------------------------------------------------------------------



## 19. Política de versões e primeiro lançamento

A Kyn deve utilizar versionamento semântico, com pré-lançamentos identificados explicitamente. O número de versão representa o estado real do projeto; nunca publique uma versão apenas para cumprir uma data ou aparentar progresso.

### 19.1 Primeiro lançamento público: `v0.1.0-alpha.1`

O primeiro lançamento público planejado é **`v0.1.0-alpha.1`**, previsto para o encerramento da **Fase 4 — IR e backend**, desde que todos os critérios de aceitação abaixo sejam cumpridos.

A primeira Alpha deve representar um compilador experimental verticalmente funcional: um programa Kyn pequeno deve atravessar o frontend, a análise semântica, a IR, o backend, a geração de objeto, a linkedição e a execução, com resultado verificável.

### 19.2 Critérios obrigatórios para `v0.1.0-alpha.1`

Não publique a versão até que:

- [ ] O compilador Zig possa ser compilado de forma reproduzível no ambiente e nos targets declarados.
- [ ] O Source Manager, lexer e parser estejam implementados e cobertos por testes.
- [ ] A AST represente corretamente o subconjunto de linguagem suportado.
- [ ] A resolução de nomes, os escopos e a verificação de tipos funcionem para esse subconjunto.
- [ ] A IR semântica esteja definida e tenha testes próprios.
- [ ] A interface de backend esteja separada da semântica da Kyn.
- [ ] O backend LLVM gere código objeto para pelo menos um target oficialmente declarado.
- [ ] A linkedição produza um executável nativo funcional.
- [ ] Pelo menos um programa de exemplo seja compilado, linkado, executado e tenha sua saída ou comportamento verificado automaticamente.
- [ ] Casos inválidos de léxico, sintaxe e semântica falhem com diagnósticos úteis e testes de regressão.
- [ ] Os testes automatizados relevantes passem em uma execução limpa.
- [ ] A documentação identifique com precisão o subconjunto implementado, as limitações conhecidas, os requisitos e o procedimento de build.
- [ ] O repositório esteja limpo quanto a arquivos acidentais, segredos, artefatos locais e alterações não revisadas.
- [ ] A tag e as notas de lançamento correspondam exatamente ao commit validado.

A Alpha **não** precisa incluir o modelo completo de ponteiros, arrays, slices, C ABI, interoperabilidade Zig, biblioteca padrão completa, `kyn-build` completo, cache incremental ou suporte a múltiplas arquiteturas. Esses recursos só podem ser anunciados como disponíveis quando implementados e testados.

### 19.3 Escopo declarado da Alpha

As notas de lançamento devem informar:

- versão do compilador e commit correspondente;
- versão de Zig e LLVM efetivamente testadas;
- sistema operacional e arquitetura suportados;
- sintaxe e recursos Kyn efetivamente implementados;
- comandos para compilar e executar os exemplos;
- limitações conhecidas e recursos ainda ausentes;
- status experimental e ausência de garantia de estabilidade da linguagem ou ABI.

Não prometa compatibilidade de código-fonte ou ABI entre versões Alpha, a menos que isso seja definido e validado explicitamente.

### 19.4 Sequência de evolução sugerida

Os marcos abaixo são uma proposta de roadmap, não uma promessa de funcionalidades ou datas:

| Versão | Marco pretendido |
|---|---|
| `v0.1.0-alpha.1` | Primeiro compilador verticalmente funcional: frontend, semântica inicial, IR, backend e executável nativo. |
| `v0.1.0-alpha.2` | Expansão e endurecimento do frontend, semântica, diagnósticos e testes de regressão. |
| `v0.1.0-alpha.3` | Primeiros recursos de memória, somente se especificados, implementados e testados. |
| `v0.1.0-beta.1` | Modelo de memória e verificações de segurança com escopo documentado e testes abrangentes. |
| `v0.1.0-rc.1` | C ABI e toolchain integradas, com testes reais de interoperabilidade e critérios de release atendidos. |
| `v0.1.0` | Primeira versão experimental estabilizada, após correção dos bloqueadores, documentação e validação dos targets anunciados. |

A ordem pode ser ajustada conforme dependências técnicas. Não force recursos de memória para uma Alpha apenas para corresponder à tabela; priorize a correção do núcleo compilador.

### 19.5 Procedimento de publicação

Para cada pré-lançamento:

1. Confirme que todos os critérios de aceitação da versão foram cumpridos.
2. Execute a suíte de testes a partir de um estado limpo.
3. Faça uma revisão do diff, dos arquivos incluídos e dos metadados de build.
4. Atualize changelog, documentação e notas de lançamento.
5. Registre o commit exato que será lançado.
6. Crie uma tag anotada seguindo o padrão `vX.Y.Z-alpha.N` ou o estágio correspondente.
7. Publique a release somente após confirmar que a tag aponta para o commit validado.
8. Se qualquer etapa falhar, não publique: corrija o problema ou registre explicitamente o bloqueio.

Não crie tags de release antecipadamente nem mova tags já publicadas para outro commit. Correções posteriores devem gerar uma nova versão de pré-lançamento.


## Instrução inicial

Comece auditando o ambiente e o repositório. Confirme diretório, branch,
remotes, estado local e estado remoto. Verifique as versões instaladas
de Zig, Clang/LLVM e ferramentas de build. Em seguida, apresente um
diagnóstico técnico e proponha a primeira entrega.

**Prioridade absoluta:** construir uma fundação correta, verificável e
sustentável para uma linguagem de sistemas que possa evoluir por muitos
anos.
