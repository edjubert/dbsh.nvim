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
Un backend peut préparer un runtime privé asynchrone. Pour Snowflake, ce runtime
contient seulement un mot de passe en mémoire provenant d’un `password_command`
argv, mis dans `SNOWFLAKE_PASSWORD` pour le processus `snow` enfant. Les secrets
ne doivent jamais rejoindre le contexte public, les clés de catalogue, les
buffers de résultat, les erreurs ou la persistance.

`progress.lua` rapporte les opérations en vol sur deux surfaces : le winbar de la
fenêtre qui portera la sortie, et une notification titrée du nom de connexion. Il
ne requiert que `config` : la fenêtre à décorer lui arrive sous forme de
résolveur `function(): integer|nil` fourni par l’appelant, ce qui évite le cycle
`definitions → exec → progress → definitions`. `exec.lua` est le seul à l’armer
et à le désarmer, sur ses deux portes d’entrée, et tient pour cela un registre
d’identifiants indexé `"<session_id>/<slot>"` : après le lancement du process, le
slot ne contient plus l’opération mais son handle, et l’identifiant ne serait
plus joignable depuis l’annulation. L’armement précède `backend.prepare`, donc il
couvre l’authentification d’un backend. Seuls un titre et un résumé publics
atteignent l’indicateur : jamais un argv, jamais un environnement, jamais un
`runtime`.

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
`pickers._telescope`, les coutures LSP (`start_client`, `attach_client`,
`detach_client`, `request`, `stop_client`, diagnostics et timers), et les
modules purs (`safety.classify`, constructeurs de requêtes backend). Restaurer
toute injection dans les hooks.

## PgLS

`lsp.mode` vaut `off`, `external` ou `managed`. Le booléen historique
`lsp.enabled = true` reste un alias déprécié de `external`; la valeur `false`
reste `off`. Le chemin `external` cible exclusivement un client PgLS appartenant
à l'utilisateur : notification de configuration sans mot de passe et
invalidation du cache après requête, sans jamais gérer son cycle de vie. Son
statut doit rappeler la limitation **last-synchronized context wins**.

Le chemin `managed` ne concerne que PostgreSQL. Il possède les clients natifs
Neovim, indexés par l’empreinte publique de connexion, la base effective, la
racine de projet et le `search_path` résolu. Le mot de passe reste en mémoire et
ne transite que par `pgls/setDatabaseContext`; il ne doit jamais apparaître dans
une clé, un statut, une notification, un log ou une configuration persistée.
Les stratégies de pool sont `immediate`, `idle` et `session`. La réconciliation
de contexte ne détache que les clients gérés, et réinitialise uniquement leur
namespace de diagnostics.

`DbLspStatus` affiche seulement l’état public du contexte actif. Le protocole
requiert une version de PgLS contenant `pgls/setDatabaseContext`: livrer/merger
d’abord cette évolution PgLS, puis dbsh. Un binaire local patché via
`lsp.command` est autorisé uniquement pour le développement et la revue, jamais
dans une configuration partagée.

Les commits suivent Conventional Commits, en anglais.

## Snowflake

Le backend Snowflake utilise exclusivement `snow sql` avec une connexion
temporaire structurée. Les profils ne contiennent ni JDBC URL ni mot de passe
littéral. Les flags de rôle, warehouse, base et schéma représentent le contexte
effectif ; un `USE` saisi dans le SQL ne modifie pas le contexte dbsh.

Les catalogues Snowflake utilisent `JSON_EXT`. Les requêtes à plusieurs
instructions, notamment `SHOW` suivi de `RESULT_SCAN`, retournent plusieurs
jeux de résultats : le parseur utilise le dernier, qui porte la sélection,
le filtre et la pagination. Les catégories avec un schéma utilisent le scope
générique ; les catégories compte n’en demandent pas.

Le cache de credentials est en mémoire, expire par TTL, est invalidé après une
erreur d’authentification reconnue et est vidé à la sortie de Neovim. Les
permissions Snowflake restent la frontière de sécurité.
