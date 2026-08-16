# Metaprompt 01 — Prove the architecture

Copia tutto il blocco qui sotto (dentro il progetto Godot, con Claude Code
aperto nella root — così legge CLAUDE.md automaticamente) e incollalo come
primo messaggio.

---

```
Contesto: leggi CLAUDE.md nella root del progetto prima di iniziare, contiene
l'architettura e le convenzioni da rispettare. Non deviare da quell'architettura
senza spiegarmi prima perché.

Obiettivo di questa sessione: NON voglio ancora il gioco completo. Voglio
validare che il pattern EventBus + CardResource + CardEffect regge, con il
minimo indispensabile per testarlo end-to-end.

Fammi questo, in ordine, fermandoti a chiedere conferma tra uno step e l'altro:

STEP 1 — Import pipeline
Scrivi uno script Godot (tool script, eseguibile dall'editor) che legge
data/cards_base_set_template.csv e genera un file .tres (CardResource) per
ogni riga in resources/cards/base_set/. Gestisci correttamente i campi vuoti
(effect_script_path e trigger_events possono essere vuoti = carta "vanilla").
Aggiungi 10-12 righe extra al CSV: mix di monster/loot/treasure semplici
(senza effetti scriptati) più 2-3 con un effetto scriptato semplice
(es. "Bomb" fa 2 danni a un mostro bersaglio quando giocata).

STEP 2 — CardEffect di esempio
Implementa 2-3 subclass di CardEffect in scripts/cards/effects/ per le carte
con effetto dello step 1. Ognuna con il commento a blocco richiesto da
CLAUDE.md (testo regole in chiaro).

STEP 3 — Turn loop minimo, hotseat, no UI grafica
Uno script/scena di test (non serve grafica curata, va bene anche solo
output su console/label) che:
- inizializza GameState per 2 giocatori
- esegue un ciclo di turni: buy phase (nessuna azione reale richiesta,
  puoi stub-are), attack phase (attacca un mostro pescato a caso dal mazzo
  monster importato, tira un dado, applica danno via EventBus), loot phase
  (pesca e opzionalmente gioca una loot card)
- si ferma dopo 3-4 turni completi e stampa lo stato finale (HP, cents,
  souls di ogni giocatore)

STEP 4 — Verifica
Esegui il test e mostrami l'output. Poi dimmi onestamente: il pattern
EventBus/CardEffect ha retto senza attriti, o hai dovuto piegare
l'architettura per farlo funzionare? Se hai dovuto aggirarla in qualche
punto, segnalamelo esplicitamente prima di continuare — è esattamente quello
che questa fase deve far emergere.

Non aggiungere: networking, UI grafica rifinita, salvataggio persistente,
altre carte oltre a quelle richieste. Resta scoperto e minimale.
```

---

### Cosa aspettarti
Se l'architettura regge, alla fine di questo step avrai: pipeline di import
CSV→resource funzionante, 2-3 effetti scriptati come prova, un loop di turno
che gira in console per un paio di giocatori. Non è un gioco, è una prova
di fattibilità. Se qualcosa nel pattern EventBus non regge (es. troppi
listener da wire-are a mano, o CardEffect troppo rigido per certi tipi di
carte), è qui che lo scopri — con 12 carte, non con 340.

### Prossimo metaprompt (02)
Una volta validato questo step, il prossimo giro sarà: espandere a un
sottoinsieme più ampio (~20-25 carte, includendo un paio di tipi di
interazione più complessi — es. carte che modificano il tiro di dado, o che
danno souls condizionali) per stressare ulteriormente il pattern prima di
buttarsi sulle ~250+ carte rimanenti.
