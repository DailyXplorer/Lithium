# Audit de performance Lithium et Helium du 27 septembre 2026

Les changements locaux améliorent le traitement des grands conteneurs, le bruit anti-fingerprinting du canvas et l'application des filtres. Une régression de police est reproduite dans l'optimisation des grands conteneurs. Helium reste plus rapide sur la création du DOM de cette page de test. WebKit sans les ajouts de Lithium présente déjà presque tout cet écart.

## Périmètre et protocole

Le code Swift et les ressources du répertoire de travail ont été compilés en release, y compris les modifications non commitées. Le commit de référence est `75c9f0f7a272c59845a1f930dd2aa321e795d314`. Les comparaisons avant et après portent sur les scripts `page-font.js` et `farbling.js`, et séparément sur les règles natives brutes et préparées. La colonne « scripts HEAD » n'est pas une compilation complète de l'ancienne application.

La machine est un MacBook avec Apple M4 Pro et 24 Gio, sous macOS 27.0, build 26A428. WebKit est en version 22625.1.29.11.27. Helium 0.18.1.1 embarque Chromium 154.0.8037.57. Les tests tournent sur batterie, avec une priorité réduite `nice 15`. Les navigateurs de l'utilisateur et les autres applications restent ouverts.

Lithium est exercé via le WebKit système et ses vrais types compilés. Les `WKWebView` n'ont pas de fenêtre visible. Helium est lancé avec `--headless=new`, un profil temporaire propre et le son coupé. Le [mode headless de Chromium](https://developer.chrome.com/docs/automation-and-testing/headless) permet cette exécution sans fenêtre affichée. Chaque navigateur tourne séparément. Les profils temporaires ne lisent pas l'historique ni les extensions de l'utilisateur.

La taille est de 1280 × 800. Chaque microtest comporte un passage de chauffe et sept mesures. Trois processus de test successifs donnent 21 mesures par case. L'ordre WebKit et Helium, ainsi que l'ordre des variantes WebKit, est inversé au deuxième passage. Les nombres sont les médianes regroupées, en millisecondes. Plus petit est meilleur.

| Opération | WebKit seul | Scripts HEAD | Scripts locaux | Helium |
|---|---:|---:|---:|---:|
| JSON et tri, 15 séries de 6 000 objets | 16,0 | 17,0 | 17,0 | 15,3 |
| DOM, 2 500 lignes avec lecture de hauteur | 19,0 | 18,0 | 18,0 | 7,3 |
| Mise en page, 12 changements sur 1 200 lignes | 28,0 | 28,0 | 29,0 | 21,1 |
| Canvas, 8 lectures de 512 × 512 pixels | 2,0 | 9,0 | 4,0 | 39,3 |

Les [mesures brutes](../.tools/perf-audit-2026-09-27/final/) et le [résumé JSON](../.tools/perf-audit-2026-09-27/final/summary.json) contiennent les valeurs de chaque passage.

Le test DOM mesure une création synchrone et une lecture de hauteur. Il ne comprend pas le travail différé de l'observateur de polices, mesuré séparément ci-dessous. Le résultat DOM est de 18 ms pour les scripts locaux contre 7,3 ms pour Helium. WebKit seul est à 19 ms. Ce résultat ne permet pas d'imputer cet écart aux protections ajoutées par Lithium.

Le canvas descend de 9 à 4 ms avec le nouveau script, soit environ 56 % de temps en moins sur ce cas. Le canvas de 512 × 512 reste sous la limite de 500 000 pixels du script. Les protections diffèrent entre Helium et Lithium. Le résultat canvas n'est donc pas une preuve de supériorité générale de WebKit, ni d'équivalence de leur protection contre le fingerprinting.

## Changements locaux mesurés

### Polices et grands conteneurs

Une page de 1 500 lignes, soit 4 500 descendants du conteneur, alterne sa classe six fois. L'instrumentation du monde isolé mesure le temps passé dans les callbacks de police et le nombre de lectures de style. L'attente de 450 ms entre mutations est exclue du temps rapporté.

Le script HEAD fait entre 4 501 et 7 501 lectures de style par changement. Sa médiane est de 13,5 ms. Le script local n'en fait qu'une. Sa médiane est inférieure à la résolution de l'horloge, de l'ordre de la milliseconde. Il ne faut pas lire les valeurs 0 ms comme un coût nul.

Une régression accompagne ce gain. La règle `.special .icon { font-family: Menlo, monospace; }` s'applique à un enfant lorsque son grand parent prend la classe `special`. L'ancien script conserve alors Menlo. Le nouveau conserve DM Sans sur les trois activations testées. La condition de [page-font.js, ligne 192](../Sources/Lithium/Resources/Scripts/page-font.js#L192) ne recontrôle que le grand conteneur. Elle ignore le changement de police du descendant causé par un sélecteur CSS sur l'ancêtre.

C'est le premier point à corriger. Un recontrôle sélectif doit inclure les descendants dont une règle de police dépend de la classe modifiée. Une reprise complète différée est une autre piste à comparer. Réintroduire systématiquement le scan synchrone initial rétablirait aussi son coût.

Preuve dans [font-mutations.json](../.tools/perf-audit-2026-09-27/final/round-1/font-mutations.json). Les tests `PageFontTests` existants passent parce que leur grand conteneur change lui-même de police. Ils ne couvrent pas ce sélecteur appliqué uniquement à un descendant.

### Filtres natifs

Une page locale charge 160 scripts distincts sans cache. Les trois listes réelles embarquées sont compilées. Cinq chargements alternent les variantes.

| Variante | Médiane du chargement |
|---|---:|
| Sans règles | 84 ms |
| Règles brutes | 91 ms |
| Règles préparées par le code local | 84 ms |

Le gain observé est d'environ 8 % par rapport aux règles brutes dans ce scénario. Il ne confirme pas le facteur 2,3 mentionné dans un commentaire du code, mesuré sur une autre charge. Une règle cosmétique de contrôle masque bien son élément avec les variantes brute et préparée. Les 160 scripts attendus s'exécutent dans chaque variante.

La préparation et la compilation initiales des trois listes prennent 5,10 s au total contre 4,75 s pour les listes brutes dans ce passage. Ce temps comprend la réécriture JSON, pas seulement le compilateur WebKit. Ce n'est pas le temps de chaque navigation. Le cache évite normalement ce travail. Cependant, `Tab.applyProtections` attend `privacy.waitUntilReady()` avant d'autoriser la navigation. Un démarrage avec un cache absent ou invalidé peut donc attendre la compilation. C'est une déduction du code, pas une mesure du lancement complet de l'application. Il faut préserver la protection pendant toute optimisation de ce chemin.

Preuves dans [native-rules.json](../.tools/perf-audit-2026-09-27/final/round-1/native-rules.json), [rule-compilation.json](../.tools/perf-audit-2026-09-27/final/round-1/rule-compilation.json), [Privacy.swift](../Sources/Lithium/Privacy/Privacy.swift#L187) et [Tab.swift](../Sources/Lithium/Model/Tab.swift#L192).

### Recherche dans l'historique

La base de test est synthétique. Aucun historique personnel n'a été utilisé. Les requêtes sont exécutées cinq fois par cas via les fonctions réelles de `HistoryStore`.

| Historique et requête | Fonction synchrone | Fonction en arrière-plan |
|---|---:|---:|
| 10 000 visites, `site` | 4,7 ms | 4,6 ms |
| 200 000 visites, `site` | 61,3 ms | 59,6 ms |
| 200 000 visites, `article 123` | 22,3 ms | 22,0 ms |
| 200 000 visites, aucun résultat | 14,1 ms | 14,0 ms |

Le déplacement hors du thread principal est utile pour la réactivité. Il ne réduit pas le travail SQL. La requête conserve une recherche `LIKE '%texte%'`, un scan `NOT INDEXED` et un regroupement des visites. À grande taille, une table de pages préagrégées et un index de recherche sont des pistes à mesurer avant de les adopter. Le débit CPU et la consommation d'énergie de ce chemin ne sont pas mesurés ici.

Preuves dans [history-search.json](../.tools/perf-audit-2026-09-27/final/round-1/history-search.json) et [History.swift, ligne 98](../Sources/Lithium/Model/History.swift#L98).

## Vérifications et limites

Les quatre tests de mesure du premier passage passent. Les deux répétitions du microtest passent. Les 12 tests existants des suites AddressSuggestions, Extensions, Fingerprinting, HistoryStore, PageFont et RuleList passent en release avec un répertoire utilisateur temporaire. Le [journal des tests existants](../.tools/perf-audit-2026-09-27/regression-tests.log) contient le détail. Le passage des tests existants ne couvre pas la régression de sélecteur CSS reproduite ici.

Le processus Lithium de l'utilisateur, PID 14072 au début de l'audit, est resté actif. Aucun script de packaging, installation ou fermeture de l'application n'a été exécuté. L'assertion de visibilité du test confirme l'absence de fenêtre visible. WebKit crée une fenêtre interne `TUINSWindow` cachée, visible dans [test-windows.json](../.tools/perf-audit-2026-09-27/final/round-1/test-windows.json).

Ces mesures ne constituent pas un classement global des deux navigateurs. Elles ne mesurent ni la batterie, ni la mémoire de l'application complète, ni les images perdues pendant YouTube, ni la fluidité du défilement visible. Les changements de chargement des extensions, de création paresseuse des onglets et de favicons sont inclus dans la compilation, mais leur gain n'est pas quantifié ici. Les filtres avancés par site et les extensions installées ne sont pas présents dans les microtests DOM et canvas.

`document.visibilityState` vaut `hidden` dans les vues WebKit et `visible` dans Helium headless. Cela limite surtout les conclusions sur les animations et le travail différé. Les mesures synchrones n'attendent pas de `requestAnimationFrame`. La vidéo de l'utilisateur et les autres applications restent une source de variation. L'horloge JavaScript de WebKit est grossière, proche de la milliseconde dans ce protocole. Les petits écarts ne sont pas à surinterpréter. Aucun score officiel Speedometer n'est annoncé.

## Reproduire

Depuis le dépôt, lancer la commande suivante. Elle compile les tests en release par défaut. Elle ne lance pas `scripts/build-app.sh` ni l'ancien `scripts/bench/run.py`, car ils ferment Lithium.

```sh
python3 scripts/bench/run-headless.py .tools/perf-audit-new --rounds 3
```

Après une compilation récente des tests, `--skip-build` évite de recompiler. Les résultats détaillés sont écrits dans le dossier choisi. Les profils temporaires sont supprimés après les tests. Les sources sont [HeadlessPerformanceTests.swift](../Tests/LithiumTests/HeadlessPerformanceTests.swift), [workloads.js](../scripts/bench/workloads.js), [headless-helium.mjs](../scripts/bench/headless-helium.mjs) et [run-headless.py](../scripts/bench/run-headless.py).

Le skill `poteto-mode` a guidé l'audit. Build the Lever a conduit à conserver les scripts reproductibles. Model the Domain a conduit à comparer une table de variantes sur les mêmes charges. Prove It Works et Test Behavior, Not Implementation ont conduit aux mesures du WebKit réel, au contrôle de masquage et à la vérification des polices calculées. Aucun sous-agent n'a été utilisé.
