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
curseur opaque et une limite. La construction des pages et les filtres de
requête restent côté backend ; l’UI filtre localement les entrées déjà
chargées et ne récupère pas toutes les pages en mémoire.

MongoDB expose `DbMongoDatabases` (contexte), `DbMongoCollections`,
`DbMongoIndexes` et `DbMongoPreview` (catalogues). Les API d’inventaire Mongo
n’exposent pas de tri avec limite : le backend filtre, trie et pagine les
métadonnées des index par nom. Le contexte des bases et les catalogues
collections/preview renvoient tous les noms en une seule requête, sans limite
de page. Les filtres littéraux explicites des bases et collections sont aussi
transmis au serveur. Les index déclarent `parent = "collections"` : le picker
sélectionne d’abord une collection sans déclencher son aperçu. Les actions
`on_select`/`action` reçoivent les options en troisième argument et conservent
le snapshot du buffer source ; `query(text, snapshot)` accepte ce contexte.
Le script Mongo utilise une fonction `async` et attend le résultat d’`eval`,
puis la matérialisation du curseur avec `toArray`. `eval` ne bénéficie pas de
la réécriture asynchrone de mongosh : l’aperçu passe donc la limite aux options
de `find({}, null, { limit: n })`, sans chaîner `limit()` sur sa promesse.
Une commande Mongo choisit son opération à partir de sa première clé BSON :
`listDatabases` est donc émis explicitement avant les options, sans dépendre de
l’ordre des clés d’une table Lua lors de l’encodage JSON.

Un backend ne requiert jamais `config`, `definitions` ou l’état global. Les
valeurs nécessaires lui sont passées en argument. Les accès à `exec` depuis un
backend sont différés pour éviter le cycle avec le registre de backends.

Un backend non SQL peut déclarer `compose` pour envelopper le texte,
`script_delivery = "stdin"` pour porter un secret sans fichier temporaire,
`classify` pour remplacer le scanner SQL et `tabular = false` pour une sortie
documentaire. `csv.lua` découpe les cellules sur │, donc les yanks refusent
explicitement une sortie non tabulaire.

MongoDB accepte `auth = "aws"` avec un `aws_profile` géré par AWS CLI v2.
`aws.lua` appelle `aws configure export-credentials --format process` :
il ne lit aucun cache SSO et ne passe aucun token dans l’argv. L’URI
`MONGODB-AWS` n’a pas de userinfo, car ces champs représenteraient une clé
d’accès et une clé secrète AWS, pas un ARN IAM. Les credentials sont transmis
uniquement dans l’environnement du processus enfant, et leur cache respecte
l’expiration AWS ainsi que le TTL dbsh. Le proxy SOCKS est facultatif.

## Contextes, résultats et définitions

`config.lua` contient les options et profils déclarés immuables.
`context.lua` porte les contextes d’exécution : un fallback pour les buffers non
liés et un contexte indépendant par buffer/scratchpad. Un snapshot est copié
avant chaque requête, catalogue, résultat ou définition ; `generation` empêche
un callback tardif d’écraser un contexte modifié.

`results.lua` garde un buffer `__DBSH__` par session. Le nom d’un buffer est
dérivé de la clé de son registre, jamais d’un libellé plus large : `results.lua`
suffixe la connexion par une empreinte de l’id de session, `definitions.lua`
suffixe le libellé de l’objet par une empreinte de sa clé. Deux entrées
distinctes du registre ne peuvent donc pas se disputer un nom et déclencher
`E95`. `find_buf` récupère aussi un buffer par sa variable locale
`dbsh_context_id` : un rechargement du plugin vide l’état du module, pas les
buffers.

Scratchpads et résultats utilisent `backend.filetype` : `sql` pour
PostgreSQL/Snowflake, `javascript` pour MongoDB. Les nouveaux scratchpads suivent
`backend.extension` (`.sql` ou `.js`). Les fichiers existants sont réutilisés
sans renommage ; le filetype suit aussi les changements de connexion. Les
résultats choisissent leur filetype depuis le snapshot source, puis le mettent
à jour même quand leur buffer existe déjà.

`DbCSVView` / `csv_view(opts)` réexécute une requête dans un buffer CSV séparé,
avec `csvview.nvim` facultatif mais requis pour cette commande. Depuis un
résultat, la requête est `b:dbsh_result_query`, pas le texte décoré du buffer ni
la dernière requête d’un autre affichage. La confirmation de sécurité et
`resolve.preamble` passent par le même chemin que les requêtes ordinaires.
Les contextes devenus obsolètes sont refusés avant d’ouvrir une vue.

Les backends exposent `csv_mode`, éventuellement `csv_query(text, delimiter)`,
`csv_output(stdout, delimiter)` et `csv_delimiter`. PostgreSQL utilise
`psql --csv`, sans pied de tableau, et fixe `csv_fieldsep` avant le SQL original :
aucun wrapper `COPY`, donc les points-virgules/commentaires sont préservés.
Snowflake demande `--format CSV` (virgule native) ;
Mongo convertit les documents EJSON raw avec `csv.documents_to_csv`.
Les objets Mongo imbriqués deviennent des chemins ; tableaux et wrappers EJSON
restent dans une seule cellule, les colonnes sont l’union des champs.

Le buffer CSV conserve sa requête et son snapshot dans `b:dbsh_csv_source`,
sans utiliser `dbsh_context_id` qui appartient au registre des résultats.
Il est en lecture seule, `bufhidden=wipe`, respecte `results_split` et ne
focalise pas au retour asynchrone. `DbCancel` utilise son snapshot, et les
mappings de lecture des requêtes refusent ce buffer. La configuration parser
de CSVView fixe le séparateur, les guillemets, la première ligne d’en-tête et
désactive les commentaires propres à la configuration personnelle.

Le focus de la fenêtre de résultat est dérivé de `results_split`, il n’a pas
d’option à lui : un split reste à côté du buffer SQL et ne prend jamais le
curseur, un flottant le couvre et le prend au lancement de la requête, sinon ses
mappings `q` et `<Esc>` ne peuvent pas partir. Seule `running` focalise :
`render` part du callback du CLI, longtemps après que l’utilisateur est passé à
autre chose, et un vol de focus asynchrone est pire que pas de focus. Les
entrées qui lisent le buffer courant (`query_paragraph`, `query_current_line`,
`query_selection`) refusent un buffer `__DBSH__` : les mappings sont globaux et
le premier paragraphe d’un résultat est la requête recopiée. `M.query` reste
sans garde, elle reçoit son texte.

`definitions.lua` garde un buffer DDL par identité publique d’objet : backend,
empreinte publique de la connexion, niveaux effectifs, type et OID (ou nom
qualifié). Ni mot de passe, ni chaîne de connexion brute, ni SQL ne sont
présents dans cette clé.

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

Lors d’une erreur d’authentification reconnue, `exec` utilise le hook facultatif
`backend.invalidate_credentials(connection, key)` avant son unique nouvelle
tentative. MongoDB invalide ainsi le cache AWS ou le cache des mots de passe
selon le profil ; les autres backends conservent l’invalidation par défaut.

`exec.compose_script` est le point unique de fabrication du script et reçoit la
connexion et le runtime. `safety.classify` délègue à `backend.classify` ;
`config.connection` utilise `backend.validate`, tandis que `config.backend_for`
signale seul un type inconnu. dbsh ne possède aucun tunnel : un proxy SOCKS doit
être ouvert hors de l'éditeur.

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
Tous les sélecteurs Telescope filtrent leurs entrées chargées localement :
aucun callback de saisie ne lance de requête ni ne rouvre le picker. Les
catalogues paginés gardent l’action explicite « Load more » ; les filtres
`query` fournis à l’API Lua restent transmis au backend.

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
ne transite que par `pgls/set_configuration_overrides`; il ne doit jamais
apparaître dans une clé, un statut, une notification, un log ou une
configuration persistée.
Les stratégies de pool sont `immediate`, `idle` et `session`. La réconciliation
de contexte ne détache que les clients gérés, et réinitialise uniquement leur
namespace de diagnostics.

`DbLspStatus` affiche seulement l’état public du contexte actif. Le mode géré
requiert PgLS 0.26.0 ou plus récent et utilise sa couche officielle de
surcharges persistantes. Aucun binaire patché n’est requis.

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
