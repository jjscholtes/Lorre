# Verbeterplan Lorre: FluidAudio 0.15.0 → 0.17.7

Datum: 22 oktober 2026 · Codebasis: `2fb4b87` · Lorre 0.3 (build 8) · Bouwt voort op [ANALYSE.md](ANALYSE.md) van 15 september

## Kern

Lorre draait op FluidAudio **0.15.0** (4 juni). De nieuwste release is **0.17.7** (8 oktober): achttien releases verder, 308 gewijzigde bronbestanden. Toen ANALYSE.md werd geschreven was 0.15.7 nog de nieuwste; die analyse is dus op het SDK-punt achterhaald, maar haar bevindingen over Lorre's eigen code staan nog.

Drie dingen maken de upgrade nu de moeite waard:

1. **Parakeet Ultra** (`AsrModelVersion.ultra`, 0.17.3): drop-in voor v3, zelfde 25 talen en API, macOS 14+. Gemiddelde FLEURS-WER over 24 talen daalt van 14,81 % naar 11,67 %, bij gelijke snelheid. Dit is de grootste kwaliteitswinst voor Nederlandse transcripties die zonder herontwerp te halen is.
2. **Betere long-form-transcriptie**: een reeks fixes aan venstergrenzen, lege vensters en interpunctie (0.15.6–0.15.8). Die raken precies Lorre's batchroute voor lange gesprekken.
3. **Nemotron 3-diarization** (0.17.0–0.17.4): streaming Sortformer voor maximaal 8 sprekers. Sinds 0.17.4 draait hij ook op M3 op de Neural Engine.

**De migratie is klein.** Statisch vergeleken (zie §3) breekt alleen `DownloadUtils`, op drie plekken. Alle andere FluidAudio-types die Lorre gebruikt bestaan nog in 0.17.7.

## 1. Relevante SDK-wijzigingen sinds 0.15.0

TTS-, iOS- en CLI-wijzigingen zijn weggelaten.

| Versie | Wijziging | Belang voor Lorre |
| --- | --- | --- |
| 0.15.3 | Long-form chunk-merges splitsen op woordgrenzen; `SlidingWindowAsrConfig.default` past weer op 240k samples | Minder kapotte woorden op chunkgrenzen in de batchroute |
| 0.15.5–0.15.6 | Hervatbare, gevalideerde downloads; cache blijft behouden bij netwerkfouten; stall-watchdog; `ModelRegistry.repoOverrides` | Minder mislukte "Prepare Models"; past bij Lorre's eigen registry-instelling |
| 0.15.6 | Reparatie van seam-gaten; `OfflineDiarizerManager.prepare()` / `cluster()` los van elkaar; pyannote-pariteit in VBx-clustering; Sortformer-tijdsdrift opgelost | Betere sprekerlabels. Sprekers opnieuw clusteren wordt mogelijk zonder alles opnieuw te berekenen |
| 0.15.7 | v3 long-form standaard via de no-mel-route (zachte spraak rond stiltes valt niet meer weg); NeMo-ITN direct gelinkt in plaats van via `dlopen`; annulering bereikt de diarizer-workers; waarschuwing voor een BNNS-crash op macOS 14 | Rechtstreeks relevant: Lorre's ITN-loader wordt overbodig. De macOS 14-crash blijft een risico |
| 0.15.7 | **`DownloadUtils` verwijderd** → `ModelHub.download`, losse `DownloadProgress` / `ProgressHandler` | **Breekt de build** (§3) |
| 0.15.8 | Herstel van lege vensters ("length-perturbation ladder"); interpunctie aan zinseinde uit de vocabulary; diarization-artefacten vastgepind op een revisie | Minder ontbrekende zinnen; reproduceerbare modellen |
| 0.17.0–0.17.4 | `Nemotron3Diarizer` (8 sprekers); fp32-backing-crash op macOS 27/M5 opgelost (0.17.2); ANE-compile op M3 opgelost (0.17.4, eenmalige nieuwe download) | Kandidaat voor een vierde diarization-engine |
| 0.17.3 | **Parakeet Ultra** (macOS 14+, ~630 MB) en Parakeet Redux (macOS 15+, ~220 MB) | Ultra is de kandidaat voor de nieuwe standaard |
| 0.17.4 | `AppLogger.minimumLevel` en `mirrorsToConsole` | Herkende woorden blijven uit de console. Past bij Lorre's privacybelofte |
| 0.17.5 | **Phonon-2**: Engels, macOS 15+, sneller dan v3. Iteratieve word-aligner voor custom vocabulary. LocalVQE echo-cancellation (bèta) | Engelse opvolger van de v2-modus. AEC is interessant voor mic + systeemaudio |

**Alleen op `main`, nog niet uitgebracht** (na 0.17.7, stand 21 oktober). Niet op bouwen, wel volgen:
- `OfflineDiarizerManager.embedSpans` en "clean per-speaker embeddings for enrollment" (#1015, #1018). Dat zou Lorre's bekende-sprekerfunctie verbeteren.
- Cohere standaard op de ANE met een 256-slot-decoder (#1046, #1024). Dat versnelt de Cohere-pass.
- Opt-out-traits voor TTS en Diarizer (#1001). Daarmee kan de binary kleiner, door TTS weg te laten.

## 2. Wat de upgrade níet oplost

- **Nederlands live**: Nemotron Multilingual streaming kent en/es/fr/it/pt/de/zh/ja, **geen Nederlands**. Parakeet Unified streaming is alleen Engels. Live-preview in het Nederlands vraagt dus om een eigen oplossing (fase 4).
- **Lorre's eigen fouten**: opnameverlies bij Stop, sessies die na een herstart in `.processing` blijven hangen, vocabulary-correcties die bij de segmentopbouw verdwijnen, en races tussen sessies. Zie ANALYSE.md §3–4.
- **macOS 14**: de SDK waarschuwt alleen voor de BNNS-crash in de offline diarizer. Het OS-probleem zelf is niet opgelost.

## 3. Migratie-impact (statisch geverifieerd)

Ik heb Lorre tegen 0.17.7 opgelost in een kopie in de scratchpad; je eigen checkout is niet aangeraakt. **Een echte build is niet gelukt**:
- De Xcode-toolchain weigert omdat de Xcode-licentie niet is geaccepteerd (`sudo xcodebuild -license`).
- De Command Line Tools passen niet bij de macOS 28-SDK (`unknown argument '-target-arch-variant'`, `no such module 'CryptoKit'`).

De onderstaande lijst komt daarom uit een vergelijking van de publieke API van 0.15.0 en 0.17.7, niet uit de compiler.

| Plek | Nu | Wordt |
| --- | --- | --- |
| [FluidAudioAdapters.swift:394](Sources/Lorre/Core/Processing/FluidAudioAdapters.swift:394) | `DownloadUtils.downloadRepo(.cohereTranscribeCoreml, to:)` | `ModelHub.download(.cohereTranscribeCoreml, to:)` |
| [FluidAudioProgressSupport.swift:13](Sources/Lorre/Core/Processing/FluidAudioProgressSupport.swift:13) | `DownloadUtils.DownloadProgress` | `DownloadProgress` |
| [FluidAudioLiveStreamingRecognizer.swift:906](Sources/Lorre/Core/Support/FluidAudioLiveStreamingRecognizer.swift:906) | `DownloadUtils.ProgressHandler?` + `downloadRepo(…, progressHandler:)` | `ProgressHandler?` + `ModelHub.download(…, progressHandler:)` |
| [TextNormalizationRuntimeSupport.swift](Sources/Lorre/Core/Support/TextNormalizationRuntimeSupport.swift) | Zoekt `libnemo_text_processing.dylib` via `dlopen` | Overbodig: de SDK linkt `NemoTextProcessing` statisch (`libtext_processing_rs.a`, standaard-trait). De loader en `TEXT_NORMALIZATION_LIBRARY_RELATIVE_PATH` kunnen weg |
| [package_macos_app.sh](scripts/package_macos_app.sh) | Kopieert alleen de executable, het icoon en optioneel de dylib | FluidAudio heeft nu een resources-target (LuxTTS-G2P). Kopieer `FluidAudio_FluidAudio.bundle` mee, of zet de TTS-trait uit zodra die is uitgebracht |
| [Package.swift](Package.swift) | `from: "0.15.0"` | `exact: "0.17.7"`. Leg `Package.resolved` vast |

Alle overige gebruikte types bestaan nog (onder meer `AsrModels`, `AsrManager`, `ASRConfig`, `CohereAsrConfig`, `CtcKeywordSpotter`, `VocabularyRescorer`, `OfflineDiarizer*`, `SortformerDiarizer`, `LSEENDDiarizer`, `StreamingEouAsrManager`, `StreamingNemotronAsrManager`, `VadManager`, `TextNormalizer`, `DiarizerManager`, `ModelRegistry.baseURL`). Gewijzigde standaardwaarden kunnen het gedrag wel veranderen zonder dat de compiler klaagt; daarvoor dient de audiobaseline in fase 0.

## 4. Plan

### Fase 0: voorwerk (klein, eerst)

1. **Toolchain herstellen.** Accepteer de Xcode-licentie (`sudo xcodebuild -license`) en draai `./scripts/ci_check.sh` op 0.15.0. Verwacht resultaat: 110 tests groen. Dit is ook de basis voor alles hieronder.
2. **Audiobaseline vastleggen** op 0.15.0, met een kleine vaste NL/EN-set zoals in ANALYSE.md §6: namen, getallen, stilte, ruis, overlap en een gesprek van een uur. Meet per opname:
   - WER en ontbrekende zinnen
   - eigennamen
   - sprekerwissels
   - verwerkingstijd
   - piekgeheugen

   Zonder deze nulmeting is niet aan te tonen dat Ultra of de nieuwe SDK beter is.

### Fase 1: snelle winst, onafhankelijk van de SDK

| # | Wijziging | Omvang |
| --- | --- | --- |
| 1a | `"nl": return .dutch` toevoegen aan [`parakeetLanguage`](Sources/Lorre/Core/Processing/FluidAudioAdapters.swift:426). Nu krijgt Nederlands geen taalhint en wordt de Cohere-pass stilzwijgend overgeslagen. `Language.dutch` bestaat in beide SDK-versies | Eén regel + test |
| 1b | Klembord alleen herstellen als `changeCount` ongewijzigd is (dicteerfallback) | Klein |
| 1c | Selectie en `transcript.sessionId == session.id` controleren na `await` (preview, bewerken, export) | Klein |

### Fase 2: opnamebetrouwbaarheid (P1 uit ANALYSE.md §3)

Ongewijzigd ten opzichte van ANALYSE.md. Dit gaat vóór nieuwe modellen, omdat een verloren opname met geen enkel model te herstellen is.
- Capture stoppen los van het opslaan van de sessie; bronaudio pas verwijderen na bevestigde opslag.
- Bij het opstarten `.processing`-sessies zonder lopende taak als "onderbroken" markeren en Retry aanbieden.
- Regressietests met geïnjecteerde fouten bij aanmaken, mixen en verplaatsen, plus een verbroken microfoon.

### Fase 3: SDK-migratie naar 0.17.7

1. Pin op `exact: "0.17.7"`; migreer de drie `DownloadUtils`-plekken (§3).
2. Verwijder de `dlopen`-ITN-route. Controleer met `TextNormalizer().isNativeAvailable` dat de native normalizer actief is. Test Nederlandse getallen en interpunctie apart: dat de normalizer meelinkt, bewijst nog niet dat die correct is.
3. Zet `AppLogger.minimumLevel` op `.info` of hoger en `mirrorsToConsole = false` in release-builds, zodat herkende tekst niet in de systeemlog belandt.
4. Bundelscript: SwiftPM-resourcebundels meekopiëren; de verpakte `.app` testen buiten `.build/`.
5. Laat `ModelRegistry.repoOverrides` aansluiten op Lorre's custom-registry-instelling, zodat mirrors ook werken voor repo's met een afwijkend pad.
6. **Klaar wanneer:**
   - de build en alle bestaande tests groen zijn
   - "Prepare Models" werkt bij een schone cache en na een afgebroken download
   - de audiobaseline gelijk of beter is dan op 0.15.0

### Fase 4: kwaliteitswinst met de nieuwe modellen

| # | Wijziging | Toelichting |
| --- | --- | --- |
| 4a | **Parakeet Ultra** als nieuwe standaard voor `BatchTranscriptionMode` | Nieuwe case `parakeetUltra`; [`asrModelVersion(for:)`](Sources/Lorre/Core/Processing/FluidAudioAdapters.swift:398) → `.ultra`. Houd v3 als terugvaloptie. Bestaande gebruikers krijgen eenmalig een download van ~630 MB; meld dat in de UI. Alleen standaard maken als de NL-baseline beter is |
| 4b | **Phonon-2** naast v2 voor Engels op macOS 15+ | Runtime-check `#available(macOS 15, *)`; op macOS 14 terugvallen naar Ultra (de SDK gooit daar een fout) |
| 4c | **Nemotron 3** als vierde `DiarizationEngine` | Vergelijk met Offline VBx op de baseline, vooral op 5–8 sprekers. Houd VBx als standaard tot dat bewezen is. Test ook op M3 (eenmalige v2-bundeldownload) |
| 4d | **"Aantal sprekers aanpassen"** zonder volledige herverwerking | Via `OfflineDiarizerManager.prepare()` + `cluster()`: segmentatie en embeddings per sessie cachen, alleen opnieuw clusteren |
| 4e | **Hertranscriberen met versiebehoud** (ANALYSE P2) | Nu extra waardevol: bestaande sessies kunnen dan ook profiteren van Ultra. Leg SDK-versie, model en instellingen per transcriptversie vast; handmatige correcties blijven behouden |
| 4f | Vocabulary-correcties in de segmenten (ANALYSE §4) | Onderzoek eerst of de iteratieve word-aligner uit 0.17.5 de tokentimings nu wél meeneemt; anders blijft de eigen uitlijning nodig |

### Fase 5: Nederlands live en verkenning

- **NL live preview.** Er is geen Nederlands streamingmodel in de SDK. Evalueer een "bijna-live"-route met `SlidingWindowAsrManager` + Ultra en de taalhint `nl`, waarbij elke paar seconden een venster wordt gedecodeerd. Meet de vertraging tot de eerste tekst. Toon tot die tijd in de UI dat de live-preview Engels is.
- **LocalVQE-echo-cancellation (bèta)** in de modus mic + systeemaudio: systeemaudio als far-end-referentie, zodat de stem van de gesprekspartner niet dubbel via de microfoon binnenkomt. Eerst als experimentele schakelaar.
- **Volgen op `main`:** `embedSpans` en schone enrollment-embeddings (bekende sprekers), Cohere op de ANE, TTS-opt-out-trait. Opnemen zodra ze in een release zitten.

## 5. Risico's

| Risico | Mitigatie |
| --- | --- |
| Gedrag verandert zonder compilerfout (andere standaardwaarden in 308 bestanden) | Audiobaseline vóór en na (fase 0) |
| Grote modeldownloads (Ultra ~630 MB; Nemotron 3 v2-bundel) | Downloadgrootte vooraf tonen; v3 als terugvaloptie behouden |
| BNNS-crash in de offline diarizer op macOS 14 | Testen op een macOS 14-machine, of de minimum-OS heroverwegen |
| Redux en Phonon-2 vereisen macOS 15 | Runtime-gating; nooit als standaard op macOS 14 |
| Kapotte toolchain blokkeert alles | Fase 0, stap 1 |

## 6. Volgorde in één oogopslag

| Stap | Resultaat | Omvang* |
| --- | --- | --- |
| 0 | Werkende toolchain, nulmeting op 0.15.0 | Klein |
| 1 | NL-taalhint, klembord, sessie-identiteit | Klein |
| 2 | Geen opnameverlies; herstel na herstart | Middel |
| 3 | Op 0.17.7, ITN native, logging privé, verpakking getest | Klein–middel |
| 4 | Ultra als standaard (indien bewezen), Phonon-2, Nemotron 3, opnieuw clusteren en hertranscriberen | Middel–groot, per onderdeel los te leveren |
| 5 | NL live, AEC, functies van `main` | Verkennend |

\* Relatieve inschatting, geen tijdsgarantie.
