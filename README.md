# NotchLite

Dynamic Island leggera per il notch del MacBook. Ispirata a Notchly, ridotta
alle funzioni utili e senza componenti fragili (niente helper root, niente hack
del wallpaper, niente framework privati nell'app).

## Funzioni

- **Musica**: brano, artwork, avanzamento con seek, precedente/play/successivo.
  Funziona con qualsiasi sorgente che pubblica il Now Playing di macOS: YouTube
  Music (app o PWA), Spotify, Apple Music, browser. Clic sull'artwork per aprire il player.
- **Batteria**: pop di collegamento/scollegamento caricatore, avviso sotto il 20%.
- **HUD volume**: livello e muto (CoreAudio, event-driven).
- **Sessioni agenti live** (Claude Code e Codex, stile omarchy-spaces): spinner
  mentre lavorano, "!" pulsante quando chiedono un permesso, ✓ quando finiscono,
  errore. Una riga per sessione con progetto e tempo trascorso; clic per tornare
  al terminale. Le sessioni chiuse spariscono da sole (controllo del processo).
- **Scheda Agenti** (stile pannello Agents di Omarchy): limiti del piano con
  barra e countdown al reset (Claude: sessione 5 ore, settimana, limiti per
  modello; Codex: finestre del piano, limite di spesa, reset gratuiti), riga
  che ruota con token di oggi/settimana, prompt, sessioni, modello più usato.
  Avviso nel notch e icona rossa nella menu bar quando un limite supera il 90%.
  Pulsante per aprire una nuova sessione di Claude o Codex nel terminale.
- **Consenti / Nega dal notch** per i permessi di Claude Code e Codex: lo script hook
  attende la risposta (max 2 min); se rispondi dal terminale vale quella.
- **Riepilogo a fine task**: l'ultima risposta dell'agente nella riga della sessione.
- **Previsione dei limiti**: "finisce gio 14:00" in arancione se al ritmo
  attuale il limite si esaurisce prima del reset.
- **Clic su una sessione → la sua scheda** in iTerm2 o Terminale (via tty).
- **Server di modelli locali**: pallino verde/rosso, controllo ogni minuto.
  Si aggiungono e rimuovono dall'ingranaggio nel notch → *Server locali*.
- **Rete** (scheda accanto a Ora e Agenti, stile pannello Network di Omarchy): Wi-Fi o Ethernet
  con banda, velocità e segnale, ping verso internet (1.1.1.1) e router, velocità
  di ricezione/invio, dati scaricati/caricati, IP e gateway. Lavora solo mentre
  la scheda è aperta.
- **Microfono / fotocamera in uso**: pallino arancione / verde sul notch.
- **Prossimo evento del calendario** (entro 12 ore) nella scheda Ora.
- **Risposte rapide** (menu *Rispondi* sulla sessione) scritte nel terminale
  dell'agente; l'elenco si modifica dall'ingranaggio nel notch → *Risposte rapide*.
- **Interrompi**: preme Esc nella scheda iTerm dell'agente al lavoro.
- **Ripiano file**: trascina file sul notch, poi trascinali fuori, clic per
  aprirli, clic destro per rimuoverli.
- **Statistiche per agente** nella scheda Agenti (token oggi/settimana, prompt, modello).
- Si nasconde da solo nelle app a schermo intero. Avvio al login dall'ingranaggio.

Passa col mouse sul notch per espanderla. Impostazioni dall'ingranaggio nel notch; l'icona nella menu bar serve solo a chiudere l'app.

## Build

Servono solo i Command Line Tools (non Xcode):

```sh
./build.sh            # crea build/NotchLite.app
./build.sh install    # e la copia in /Applications
```

## Hook Claude Code / Codex

Dall'ingranaggio nel notch → *Hook agenti*, oppure:

```sh
/Applications/NotchLite.app/Contents/MacOS/NotchLite --install-hooks
/Applications/NotchLite.app/Contents/MacOS/NotchLite --uninstall-hooks
```

Aggiunge le sue voci a `~/.claude/settings.json` e `~/.codex/hooks.json` senza
toccare gli altri hook (backup `*.notchlite.bak`). Codex chiede di approvare i
nuovi hook al primo avvio.

Da dove arrivano i limiti (come Omarchy): endpoint OAuth di Anthropic con il
token che Claude Code tiene nel Portachiavi; `codex app-server`
(`account/rateLimits/read`) per Codex. Controllo ogni 10 minuti, o entro 2
minuti quando apri la scheda Agenti. Le statistiche leggono in modo incrementale
`~/.claude/projects` e `~/.codex/sessions` (ultimi 8 giorni).

`NotchLite --usage-report` stampa limiti e statistiche dal terminale.

Lo script hook accoda una riga JSON a
`~/Library/Application Support/NotchLite/events.jsonl` (circa 30 ms per evento).

## Agenti supportati

Gli agenti di Omarchy con limiti o credito. Nella scheda compaiono solo quelli
in uso (con limiti o credito leggibili).

- **Limiti di abbonamento**: Claude Code, Codex, Cursor, Grok Bot, GitHub Copilot,
  Devin, Grok, Kimi Code, Muse, Antigravity, Z.ai, MiniMax, Synthetic, Ollama
  Cloud, OpenCode.
- **Credito prepagato**: OpenRouter, DeepSeek, Fireworks, Kimchi.

Le chiavi API si possono mettere nelle variabili d'ambiente di ciascun provider
oppure in `~/.config/notchlite/agents/<id>.json` (`{"apiKey": "..."}`).
I collector leggono le credenziali in sola lettura e le inviano solo al
dominio del proprio provider.

I collector sono un port in Swift di quelli di
[Omarchy](https://github.com/basecamp/omarchy) (licenza MIT, © David Heinemeier Hansson).

## Architettura

| File | Ruolo |
|---|---|
| `App.swift` | avvio, icona menu bar, impostazioni |
| `NotchController.swift` | finestra overlay, posizione sul notch, hover/click-through |
| `IslandModel.swift` | stato dell'isola (compatta/espansa, priorità attività, dimensioni) |
| `IslandViews.swift` | interfaccia SwiftUI |
| `MediaService.swift` + `Bridge/` | Now Playing via MediaRemote, ospitato da `/usr/bin/perl` (unico modo consentito da macOS 15.4+) |
| `SystemServices.swift` | batteria (IOPS) e volume (CoreAudio), entrambi a notifiche |
| `NetworkService.swift` | dati della scheda Rete (SystemConfiguration, CoreWLAN, `/sbin/ping`) |
| `AgentService.swift` | sessioni live dagli eventi hook, installer degli hook |
| `UsageService.swift` | aggiornamento dei collector e statistiche Claude/Codex |
| `Collectors/` | un collector per provider, sul protocollo di `CollectorKit.swift` |
| `AgentLauncher.swift` | nuova sessione agente in iTerm2/Terminale |

A riposo: circa 0% CPU, circa 65 MB (più circa 22 MB del processo bridge musicale).

## Licenza

MIT © matrixfede, vedi [LICENSE](LICENSE).
