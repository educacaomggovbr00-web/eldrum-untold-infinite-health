# Eldrum: Untold — Infinite Health research

Projeto de análise técnica local de uma cópia do APK de Eldrum: Untold, com objetivo de estudar o sistema de vida em uma campanha single-player/offline.

## Estado atual

- APK de origem: release Aaasa, asset com.gotterdammerung.untold.apk.
- SHA-256 conhecido: d57863ea0b01ba1b3162584eea5f839fed22bdd7185a253045af9f7ededd9700.
- O fluxo abaixo faz inventário, descompilação e busca de referências relacionadas a vida/dano.
- **Ainda não existe patch de vida infinita nem APK modificado.** O patch só deve ser criado depois de identificar a função correta e validar o formato do bytecode.

Não coloque APKs proprietários, arquivos DEX, bundles Hermes descompilados ou cópias do código do jogo no repositório público. O fluxo baixa o APK da release e mantém os arquivos temporários no runner; somente relatórios resumidos são publicados como artifact do workflow.

## Ferramentas instaladas pelo workflow

| Ferramenta | Versão | Uso |
|---|---:|---|
| OpenJDK | 17 | Runtime das ferramentas Java |
| Apktool | 3.0.3 | Manifest, recursos e Smali; decode/rebuild |
| JADX | 1.5.6 | DEX para código Java legível |
| hermes-decomp | 0.2.4 | Inspecionar e descompilar bundle React Native/Hermes; suporte a HBC 98 |
| Android SDK Build Tools | 36.0.0 | aapt2, apksigner e zipalign |
| Android SDK Command-line Tools | fornecido pelo setup-android | apkanalyzer / sdkmanager |

As versões dos três binários externos são fixadas e seus SHA-256 são verificados antes do uso. O APK também é verificado contra o hash da release.

## Executar

1. Abra a aba **Actions** deste repositório.
2. Escolha **Eldrum APK analysis**.
3. Selecione **Run workflow**.
4. Use a tag Aaasa e o nome do asset padrão, a menos que publique outra release.
5. Aguarde o job terminar e baixe o artifact **eldrum-analysis-report**.

O workflow também roda quando os arquivos de análise ou o próprio workflow são alterados na branch main.

## O que o relatório contém

- SHA-256, tamanho, application ID e versão do APK.
- Resultado da verificação de assinatura e certificado.
- Resultado do decode Apktool e JADX (logs resumidos).
- Versão/layout do bundle Hermes encontrado.
- Trechos pequenos de contexto em torno de nomes como UntoldCharacterMaxHealth, UntoldNpcMaxHealth, Resilience, health, HP e damage.

O artifact **não** inclui o APK, o bundle completo, DEX nem o código-fonte descompilado.

## Plano de modificação

1. Confirmar qual bundle Hermes contém a lógica do jogo.
2. Identificar a rotina que atualiza a vida do personagem e separar dano do jogador de dano dos NPCs.
3. Inspecionar a função e as instruções antes de qualquer alteração.
4. Criar um patch mínimo e reversível, preservando o APK original.
5. Reconstruir/alinhar/assinar uma cópia de teste e verificar assinatura, instalação e comportamento no Moto G35.

A documentação do hermes-decomp informa que ele modifica bytecode/HASM diretamente, não recompila JavaScript descompilado. Em formatos Hermes modernos (HBC 97+), há limitações de alterações que mudem o tamanho de funções/strings. Portanto, não será aplicado um patch genérico nem uma substituição de texto sem confirmar que é semanticamente correta.

## Links das ferramentas

- Apktool: https://github.com/iBotPeaches/Apktool
- JADX: https://github.com/skylot/jadx
- hermes-decomp: https://github.com/SymbioticSec/hermes-decomp
- Android SDK Build Tools: https://developer.android.com/tools/releases/build-tools
