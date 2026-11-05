# Analyse van Lorre

Datum: 15 september 2026 · Codebasis: `2fb4b87` · Lorre 0.3, build 8

## Conclusie

Lorre heeft een bruikbare basis: lokale spraakverwerking, meerdere audiobronnen, sprekerlabels, transcriptbewerking, exports, dicteren in andere apps en Call Watcher. De belangrijkste volgende stap is betrouwbaarheid: opnamen behouden bij fouten, onderbroken verwerking herstellen en transcriptcorrecties daadwerkelijk laten doorwerken.

**Een update van FluidAudio 0.15.0 naar 0.15.7 is zinvol.** De nieuwe versie bevat relevante verbeteringen voor lange transcripties, sprekerherkenning en downloads. Tegelijk zijn er fouten in Lorre's eigen integratie die een SDK-update niet automatisch oplost. Mijn aanbevolen volgorde: opnameherstel → integratiefouten en kwaliteitsmeting → SDK-migratie → gebruiksgemak en prestaties.

Dit is een analyse en uitvoeringsvoorstel. Applicatiecode, SDK-versies en bestaande projectplannen zijn niet gewijzigd.

## 1. Huidige basis en verificatie

| Onderdeel | Vastgesteld |
| --- | --- |
| App | Native macOS-app met SwiftUI; minimum macOS 14 |
| Toolchain | `Package.swift` vereist Swift 6.3 |
| Externe package | FluidAudio; `Package.resolved` en lokale checkout staan op 0.15.0 |
| Transcriptie | Parakeet v3/v2; optionele extra Cohere-transcriptie |
| Live preview | Parakeet EOU of Engelstalige Nemotron-streamingroute |
| Sprekers | Offline VBx, Sortformer, LS-EEND en lokale stemprofielen |
| Opslag | Lokale JSON-/audiobestanden; atomic writes, padvalidatie en actor-geïsoleerde mutaties |
| Lokale CI | `./scripts/ci_check.sh` geslaagd: 110 tests in 6 suites |
| Distributie | Eigen bundelscript; bestaande app is arm64 en ad-hoc ondertekend |

De geslaagde controle omvatte een incrementele debugbuild en Swift Testing-tests. Testuitvoering: 1,299 seconden. De workflowtests gebruiken mocks voor ASR en diarization. Er is geen audiokwaliteitsbenchmark, nieuwe SDK-build of handmatige GUI-/opnametest uitgevoerd. De bevindingen hieronder zijn afgeleid uit concrete codepaden; optreden en frequentie op echte hardware zijn niet gemeten.

Bronnen: [Package.swift](/Users/jessescholtes/Development/Lorre/Package.swift:1), [Package.resolved](/Users/jessescholtes/Development/Lorre/Package.resolved:10), [dependencies](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Core/Support/AppDependencies.swift:25), [testlog](/tmp/lorre-analysis-ci.log).

## 2. Wat levert de SDK-update op?

De nieuwste gepubliceerde release is **0.15.7 van 10 september 2026**. [Release 0.15.7](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.7).

| Verbetering sinds 0.15.0 | Betekenis voor Lorre |
| --- | --- |
| Reparaties rond grenzen tussen audiovensters en het einde van een opname | Relevant voor volledige tekst bij langere gesprekken en stiltes. [0.15.6](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.6) |
| Gewijzigde standaard voor lange Parakeet-v3-transcripties | Vermindert een aangetoond geval van wegvallende zachte spraak rond lange stiltes. Lorre gebruikt deze batchroute. Dit is geen bewijs van een bepaald kwaliteitspercentage voor Nederlands. [Wijziging #869](https://github.com/FluidInference/FluidAudio/pull/869) |
| Verbeterde VBx-clustering, speakerlimieten en annulering | Relevant voor het ingestelde aantal sprekers en stoppen van werk. [0.15.6](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.6), [0.15.7](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.7) |
| Hervatbare modeldownloads, validatie en beter cachebehoud | Minder opnieuw downloaden en betere recovery na netwerkonderbrekingen. [0.15.5](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.5), [ModelHub-broncode](https://github.com/FluidInference/FluidAudio/blob/v0.15.7/Sources/FluidAudio/Shared/Download/ModelHub.swift) |
| Native NeMo-tekstnormalisatie standaard meegeleverd | Kan de huidige ontbrekende losse runtime vervangen en de verpakking vereenvoudigen. [Package-configuratie 0.15.7](https://github.com/FluidInference/FluidAudio/blob/v0.15.7/Package%40swift-6.2.swift) |
| Afzonderlijke voorbereiding en clustering van offline diarization | Maakt een toekomstige actie “aantal sprekers aanpassen” mogelijk zonder opnieuw alle segmentatie en stemkenmerken te berekenen. Vereist extra integratiewerk. [Wijziging #789](https://github.com/FluidInference/FluidAudio/pull/789) |

De release meldt ook een waarschuwing voor crashgevoelige macOS-14-builds bij offline diarization. De deployment target blijft macOS 14; compatibiliteit en runtimebetrouwbaarheid moeten apart op de ondersteunde OS-versies worden getest. Die waarschuwing is geen volledige oplossing voor het OS-probleem. [0.15.7](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.7).

### Migratie is meer dan een versienummer aanpassen

1. **Download-API migreren.** `DownloadUtils.downloadRepo` wordt `ModelHub.download`; `DownloadUtils.DownloadProgress` en `.ProgressHandler` worden losse types. De verwijdering is aanwezig in 0.15.7, ook al spreekt de oorspronkelijke PR-tekst nog over een beoogde 0.16.0. [Migratietabel](https://github.com/FluidInference/FluidAudio/pull/779), [getagde broncode](https://github.com/FluidInference/FluidAudio/blob/v0.15.7/Sources/FluidAudio/Shared/Download/ModelHub.swift).

   Concrete Lorre-aanpassingen: [Cohere-download](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Core/Processing/FluidAudioAdapters.swift:394), [voortgang](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Core/Processing/FluidAudioProgressSupport.swift:13), [live-modeldownload](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Core/Support/FluidAudioLiveStreamingRecognizer.swift:906).

2. **NeMo-integratie opschonen.** Lorre zoekt nu via `dlopen` naar een losse dylib; het ingestelde `ThirdParty`-bestand ontbreekt hier. SDK 0.15.7 linkt de meegeleverde engine rechtstreeks en biedt vanaf Swift 6.2 een opt-out-trait. Controleer eerst de gewenste tekstnormalisatie per taal en verwijder daarna de oude laad-/verpakkingsroute. Nederlandse getallen en interpunctie zijn hiermee nog niet bewezen correct. [Huidige loader](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Core/Support/TextNormalizationRuntimeSupport.swift:62), [nieuwe SDK-normalizer](https://github.com/FluidInference/FluidAudio/blob/v0.15.7/Sources/FluidAudio/ITN/TextNormalizer.swift).

3. **Releasebundel controleren.** De nieuwe package bevat ook resources en een binary target. Het huidige script kopieert executable, icoon en optioneel één dylib. Controleer de benodigde SwiftPM-resourcebundels en test de verpakte app buiten de builddirectory. [Bundelscript](/Users/jessescholtes/Development/Lorre/scripts/package_macos_app.sh:80), [nieuwe package](https://github.com/FluidInference/FluidAudio/blob/v0.15.7/Package%40swift-6.2.swift).

4. **Geteste versie reproduceerbaar vastleggen.** `from: "0.15.0"` is een versiebereik; het lockbestand bepaalt nu de feitelijke 0.15.0. Gebruik voor deze migratie een expliciet geteste 0.15.7 en leg lockbestand, toolchain en validatieresultaten vast. Alleen het SDK-nummer in documentatie wijzigen heeft geen effect op het gebouwde product.

## 3. Eerst oplossen: opname- en sessiebetrouwbaarheid

### P1 — Stoppen kan audio verliezen of opname onzichtbaar laten doorlopen

`stopRecordingTapped` schrijft eerst een sessie en roept daarna pas de recorder aan om te stoppen. Als die eerste opslag faalt, zet de catch de UI op “Ready to record”, terwijl de recorder niet noodzakelijk is gestopt. Bij een latere finalisatiefout worden tijdelijke audiobestanden verwijderd en wordt de aangemaakte sessie gewist. Ook een audiodevicewijziging kan via een writer-fout in deze verwijderroute eindigen.

**Aanpak:** stoppen van capture onafhankelijk maken van sessieopslag. Bewaar bruikbare bronbestanden in een herstelsessie. Scheid stoppen, mixen, verplaatsen en metadata opslaan in herhaalbare stappen. Verwijder audio alleen na bevestigde succesvolle opslag en volgens de ingestelde bewaartermijn.

**Controle:** fouten injecteren bij sessieaanmaak, metadata-opslag, mixen en bestandsverplaatsing; microfoonverbinding verbreken tijdens opname. Capture moet stoppen en bruikbaar bronmateriaal moet herstelbaar blijven.

Bewijs: [volgorde bij Stop](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Features/Shell/AppViewModel.swift:890), [sessie verwijderen](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Features/Shell/AppViewModel.swift:921), [tijdelijke audio verwijderen](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Core/Support/AVFoundationRecorderService.swift:942).

### P1 — Onderbroken verwerking blijft na herstart hangen

Startup laadt `.processing`-sessies zonder de taak opnieuw te starten of de sessie als onderbroken te markeren. Retry is alleen beschikbaar voor `.error`. Een crash of afsluiten tijdens verwerking kan daarom een sessie opleveren die via de UI niet verder kan.

**Aanpak:** bij starten actieve statussen vergelijken met werkelijk lopende taken, onderbroken werk herkenbaar maken en herstel aanbieden. Maak ook bij het begin van een opname een persistent herstelrecord.

Bewijs: [startup](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Features/Shell/AppViewModel.swift:145), [sessies laden](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Features/Shell/AppViewModel.swift:2955), [Retry-beperking](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Features/Shell/AppViewModel.swift:515).

### P1 — Vertraagd concept kan bij een andere sessie terechtkomen

De processing-preview controleert de selectie vóór het laden, maar niet na `await`. Een concept van A kan daardoor verschijnen terwijl B geselecteerd is. Export controleert vervolgens niet of transcript en sessie hetzelfde ID hebben.

**Aanpak:** selectie en taakidentiteit na het laden opnieuw controleren; de combinatie `transcript.sessionId == session.id` afdwingen bij tonen, wijzigen en exporteren. Test een vertraagde A-load terwijl de gebruiker B opent.

Bewijs: [preview-load](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Features/Shell/AppViewModel.swift:2943), [export](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Features/Shell/AppViewModel.swift:966).

## 4. Transcriptkwaliteit: fouten in de integratie

### Aangepaste woorden verdwijnen bij segmentopbouw

Vocabulary boosting wijzigt `ASRResult.text`, maar de bestaande SDK behoudt de oorspronkelijke token-timestamps en tokentekst. Lorre bouwt de zichtbare transcriptregels vervolgens opnieuw op uit die oude tokens. Daardoor kan een gecorrigeerde eigennaam verdwijnen terwijl de engine wel `+Vocabulary` vermeldt.

**Aanpak:** correcties en tijdstempels samen verwerken, of de gecorrigeerde tekst expliciet op de tijdsegmenten uitlijnen. Verifieer het opgeslagen én geëxporteerde transcript met een daadwerkelijk gewijzigde eigennaam.

Bewijs: [correctie](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Core/Processing/FluidAudioAdapters.swift:331), [segmentopbouw](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Core/Processing/FluidAudioAdapters.swift:596).

### Nederlands + Cohere wordt overgeslagen

De Cohere-route vereist eerst een geldige Parakeet-taalhint. Lorre's mapping mist `nl`, terwijl zowel de lokale SDK `Language.dutch` als Lorre's Cohere-mapping Nederlands kent. De extra transcriptie wordt daarom voor Nederlands stilzwijgend overgeslagen. Het gewone meertalige Parakeet-v3-model kan nog wel Nederlandse tekst herkennen; dit is geen totale uitval van Nederlands.

**Aanpak:** de ontbrekende mapping herstellen en modelbeschikbaarheid per engine bepalen. Toon of de extra transcriptie daadwerkelijk is uitgevoerd of mislukt.

Bewijs: [guard](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Core/Processing/FluidAudioAdapters.swift:352), [taalmapping](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Core/Processing/FluidAudioAdapters.swift:426).

### Nederlandse live preview heeft een eigen modelkeuze nodig

De vijf huidige presets gebruiken Engelse EOU/Nemotron-modellen. De batchtaalinstelling verandert die route niet. Maak de beperking zichtbaar en evalueer een meertalige Parakeet-v3-streamingroute voor Nederlands. Beoordeel vertraging en nauwkeurigheid met dezelfde opnamen voordat dit de standaard wordt.

Bewijs: [live-presets](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Core/Support/FluidAudioLiveStreamingRecognizer.swift:111), [documentatie van de gepinde SDK](/Users/jessescholtes/Development/Lorre/.build/checkouts/FluidAudio/Documentation/Models.md:28).

## 5. Prestaties en gebruiksgemak

| Prioriteit | Verbetering | Onderbouwing |
| --- | --- | --- |
| P2 | Microfoon en systeemaudio op dezelfde tijdlijn mengen | De live mixer verstuurt zodra één bron genoeg samples heeft en vult de andere met nul. Later binnengekomen audio van hetzelfde tijdvak wordt dan extra uitvoer. Gebruik timestamps en een korte wachtbuffer. [Mixer](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Core/Support/AVFoundationRecorderService.swift:517) |
| P2 | Grote opnamen eenmaal converteren, daarna per venster lezen | Vocabulary, VAD, Cohere en speaker matching laden de opname opnieuw volledig. Eén uur mono Float32 op 48 kHz is circa 691 MB; 16 kHz-output circa 230 MB. Dit is bufferomvang, geen gemeten app-geheugenpiek. [Voorbeeld](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Core/Processing/FluidAudioAdapters.swift:304) |
| P2 | “Opnieuw transcriberen” met versiebehoud | Voltooide sessies kunnen nu niet opnieuw worden verwerkt. Bewaar oude tekst en handmatige correcties; registreer SDK, model en instellingen per nieuwe versie. Dan zijn updates ook nuttig voor het bestaande archief. [Acties](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Features/Shell/AppViewModel.swift:515) |
| P2 | Klembord alleen herstellen als het ongewijzigd bleef | De dictation-fallback herstelt na 900 ms onvoorwaardelijk het oude klembord. Gebruik `changeCount` zodat tussentijds gekopieerde tekst behouden blijft. [Plakroute](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Core/Support/GlobalDictationPlatformServices.swift:275) |
| P2 | AppViewModel langs workflows opsplitsen | 4.076 regels beheren opname, archief, export, instellingen, dictation en Call Watcher. Splits toestanden en taken; behoud de bestaande serviceprotocollen. Dit verlaagt de kans op workflowraces. [AppViewModel](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Features/Shell/AppViewModel.swift:9) |
| P3 | Zoeken in transcriptinhoud en notities | Zoeken gebruikt nu titel, status, map en foutmelding. Een lokale tekstindex met tijdstempels maakt oudere gesprekken makkelijker terug te vinden. [Zoekvelden](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Features/Shell/AppViewModel.swift:4034) |
| P3 | Instellingen vanuit de taak aanbieden | Bied enkele geteste profielen, bijvoorbeeld Nederlands dicteren of gesprek met meerdere sprekers. Plaats modelnamen, compute-keuzes en debugopties bij Geavanceerd. Huidige instellingen staan in een omvangrijke popover. [Instellingen](/Users/jessescholtes/Development/Lorre/Sources/Lorre/Features/Shell/SessionShelfModelSettingsView.swift:80) |

## 6. Tests en distributie versterken

De bestaande tests zijn waardevol, maar missen juist echte transcriptkwaliteit en meerdere hierboven beschreven foutpaden. Voeg gerichte regressietests toe voor opnameherstel, herstart, selectie tijdens verwerking, vocabulary-resultaten en Nederlandse modelrouting.

Maak daarnaast een kleine vaste NL/EN-audioset met namen, getallen, stilte, achtergrondgeluid, overlap en een lang gesprek. Meet per SDK/model:

- Woordfoutpercentage en ontbrekende zinnen.
- Correctheid van eigennamen en getallen.
- Sprekerverwisselingen en tijdstempels.
- Tijd tot eerste live tekst en totale verwerkingstijd.
- Piekgeheugen, annulering en herstel na onderbreking.

Voer zware modeltests apart uit van de snelle reguliere suite. Er is geen ingecheckte CI-workflow aangetroffen; automatiseer debugtests plus een releasebuild en controle van de verpakte app.

Voor verspreiding buiten de eigen Mac verdient het releaseproces Developer ID-signing, hardened runtime en notarization. Nu gebruikt het script uitsluitend ad-hoc signing; de bestaande bundle bevestigt `Signature=adhoc` en geen TeamIdentifier. [Bundelscript](/Users/jessescholtes/Development/Lorre/scripts/package_macos_app.sh:122), [Apple: notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## 7. Aanbevolen uitvoering

| Stap | Resultaat | Omvang* | Klaar wanneer |
| --- | --- | --- | --- |
| 1 | Opnameherstel, hervatten na herstart en correcte transcriptidentiteit | Middel | Geïnjecteerde opslag-/devicefouten behouden audio; onderbroken werk is herstelbaar; export hoort altijd bij de juiste sessie |
| 2 | Vocabulary- en Nederlandse routingfouten herstellen; vaste audiobaseline vastleggen | Klein–middel | Correcties staan in segmenten/exports; NL+Cohere draait; referentieresultaten van 0.15.0 zijn vastgelegd |
| 3 | FluidAudio 0.15.7 integreren, downloads/NeMo/verpakking migreren | Middel | Build, 110 bestaande tests, nieuwe regressietests en verpakte app slagen; audiokwaliteit is vergeleken |
| 4 | Taalbewuste live preview, tijdlijncorrectie en geheugenoptimalisatie | Middel–groot | NL-live en lange/mixed opnamen zijn op echte hardware gemeten en verbeteren de baseline |
| 5 | Hertranscriptie met versiebehoud, zoeken, overzichtelijke instellingen en distributie | Afzonderlijke kleine/middelgrote taken | Bestaande sessies profiteren veilig van verbeteringen en de release is reproduceerbaar |

\* Relatieve inschatting op basis van codeonderzoek, geen tijdsgarantie. Met name audiotests en OS-afwijkingen bepalen de werkelijke inspanning.

**Besluit:** behoud SwiftUI, lokale opslag en de service-adapters. Geef prioriteit aan betrouwbare opname en aantoonbaar betere transcripties. De SDK-upgrade hoort daarbij; een brede herbouw of extra modellen toevoegen is op dit moment minder waardevol.
