# Connaissances projet

Ce document décrit les contrats actuels de dbsh.nvim. Le plugin pilote un CLI de
base de données depuis Neovim ; il ne contient pas de driver. Les modules vivent
sous `lua/dbsh/`, les messages utilisateur commencent par `dbsh.nvim: ` et les
données persistantes vivent sous `stdpath("data")/dbsh/`.

## Backends

Un backend est une table sans état sous `lua/dbsh/backends/<nom>.lua`, enregistrée
dans `lua/dbsh/backends/init.lua`. Il déclare notamment `argv`, `env`, `preamble`,
`parse_raw`, `variable_preamble`, `export_query`, `preview_query`, les contrats
`contexts` et `catalogs`, et éventuellement `definition_request` et `lsp`.

`contexts` représente les changements de contexte persistés dans le buffer
actif ; `catalogs` représente les objets à parcourir. Un catalogue expose
`key`, `command`, `title`, `list(request, callback)` et ses actions. Son
`request` contient un contexte **public**, une portée, un filtre littéral, un
curseur opaque et une limite. La pagination reste côté backend : aucune couche
partagée ne filtre ni ne récupère toutes les pages en mémoire.

Un backend ne requiert jamais `config`, `definitions` ou l’état global. Les
valeurs nécessaires lui sont passées en argument. Les accès à `exec` depuis un
backend sont différés pour éviter le cycle avec le registre de backends.

## Contextes, résultats et définitions

`config.lua` contient les options et profils déclarés immuables.
`context.lua` porte les contextes d’exécution : un fallback pour les buffers non
liés et un contexte indépendant par buffer/scratchpad. Un snapshot est copié
avant chaque requête, catalogue, résultat ou définition ; `generation` empêche
un callback tardif d’écraser un contexte modifié.

`results.lua` garde un buffer `__DBSH__` par session. `definitions.lua` garde un
buffer DDL par identité publique d’objet : backend, empreinte publique de la
connexion, niveaux effectifs, type et OID (ou nom qualifié). Ni mot de passe,
ni chaîne de connexion brute, ni SQL ne sont présents dans cette clé.

Les définitions conservent le snapshot capturé à l’ouverture. Le slot
`definition` d’`exec.lua` utilise donc ce contexte même si l’utilisateur change
ensuite de connexion dans un autre buffer. Ouvrir une nouvelle définition depuis
un buffer de définition crée un split au lieu de remplacer le DDL visible.

## Exécution et sécurité

`exec.lua` possède des slots par session : `user`, `introspect` et `definition`.
`run` écrit un script SQL temporaire ; `run_argv` exécute un argv fourni par un
backend, sans script temporaire ni journalisation des arguments/environnements.

`safety.lua` est pur et ne dépend pas de l’UI. Son classifieur est volontairement
conservateur : lectures connues exécutées directement, mutations/privilèges,
entrées ambiguës et multi-statements confirmés par défaut. C’est un garde-fou
ergonomique, jamais une frontière de sécurité : les permissions de la base
restent la source d’autorité. `dbsh.query` confirme avant la résolution des
variables, puis exécute avec le snapshot déjà capturé.

## Commandes et UI

`init.lua` déclare les commandes génériques et l’union des commandes
`backend.contexts`/`backend.catalogs`. Leur exécution est vérifiée contre le
backend du buffer actif. `telescope/pickers.lua` est générique : connexion,
scratchpad, contexte, catalogue et définitions. Telescope est optionnel ; les
chemins concernés dégradent vers une UI Neovim ou une erreur explicite.

`DbTables` est le contrat de compatibilité PostgreSQL ; `DbRelations` est le
parcours de relations canonique. Ne pas réintroduire `backend.levels` ni une
navigation globale.

## Persistance

Les exports CSV, historiques de variables et métadonnées/fichiers de scratchpad
sont sous `stdpath("data")/dbsh/`. Toujours créer le répertoire parent avec
`vim.fn.mkdir(dir, "p")` avant une écriture. Les secrets ne sont jamais copiés
dans cette persistance.

## Style, erreurs et tests

Neovim ≥ 0.10 et LuaJIT/Lua 5.1 : pas de `goto` ni opérateurs bitwise.
Indentation par tabulations. Les commentaires expliquent le pourquoi, les
identifiants et commentaires de code restent en anglais.

Pas d’`error()` sur un chemin utilisateur. Les chemins synchrones retournent
`nil, err`; les chemins asynchrones suivent le contrat de leur module. Les
notifications passent par `vim.notify` avec le préfixe standard.

Les tests MiniTest se lancent avec `make test`. Utiliser un fichier
`tests/test_<module>.lua`, `tests/helpers.lua`, et `vim.wait` pour l’asynchrone.
Les coutures de test sont des champs réassignables : `exec.runner`,
`pickers._telescope`, les tables LSP, et les modules purs (`safety.classify`,
constructeurs de requêtes backend). Restaurer toute injection dans les hooks.

Les commits suivent Conventional Commits, en anglais.
