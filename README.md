# Four Souls Digital (working title)

Progetto personale, non commerciale. Adattamento digitale flat-screen (no VR)
del gioco da tavolo "The Binding of Isaac: Four Souls".

## Come partire
1. Apri questa cartella in Godot 4.3+.
2. Apri Claude Code nella root del progetto (leggerà `CLAUDE.md` automaticamente).
3. Usa il metaprompt in `docs/METAPROMPT_01_prove_the_architecture.md` come
   primo messaggio.

## Struttura
```
scripts/
  autoload/       EventBus, GameState, Log, Rng (singleton)
  core/           CardResource, CardEffect, CardEffectRegistry (classi base)
  cards/effects/  effetti scriptati, uno per carta (da creare)
resources/cards/  file .tres generati dall'import CSV
data/             catalogo carte in CSV, sorgente di verità
docs/             metaprompt e note di progetto
```

## Roadmap
Vedi la sezione "Development phases" in `CLAUDE.md` — non saltare fasi.

## Nota legale
Four Souls è proprietà di Edmund McMillen / Studio71. Questo progetto resta
privato/non distribuito finché non viene ottenuto un accordo esplicito.
