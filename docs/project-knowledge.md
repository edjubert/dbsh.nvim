# Connaissances projet

Ce document consolide les conventions du dépôt, aujourd'hui lisibles seulement dans le code.
Il décrit le plugin tel qu'il est, et servira de référence aux chantiers à venir.

## Ce que fait le plugin

psql.nvim pilote le CLI `psql` en sous-processus depuis un buffer Neovim.
Il ne contient aucun driver : la connexion, l'authentification et le rendu du tableau sont délégués au CLI.

## Runtime

Neovim ≥ 0.10, LuaJIT (Lua 5.1) : pas de `goto`, pas d'opérateurs bitwise, `unpack` et non `table.unpack`.
Les sous-processus passent par `vim.system`.
telescope.nvim est une dépendance **optionnelle** : tout chemin qui l'utilise passe par `pcall(require, "telescope")` et dégrade avec un message clair.

## Forme d'un module

`local M = {}` en tête, `return M` en pied ; fonctions publiques `function M.x()`, helpers `local function`.
Les `require` de tête sont en haut du fichier, sauf en cas de cycle où le `require` est fait dans le corps de la fonction (`init` ↔ `telescope/pickers`, `resolve` → `pickers`).

## Style

Tabulations pour l'indentation, aucun formateur configuré.
Commentaires et identifiants en anglais.
**Un commentaire explique pourquoi, jamais quoi** — par exemple, dans `exec.build_argv` : `-X ignores ~/.psqlrc, -w never prompts for a password`.

## Gestion d'erreur

Jamais d'`error()` sur un chemin utilisateur.
Synchrones : `return nil, err`.
Asynchrones : `callback(nil, err)` pour l'introspection et l'export, `callback(code, stdout, stderr)` pour `exec.run`.
Les messages utilisateur passent par `vim.notify` et sont préfixés `psql.nvim: `.
Un store JSON corrompu ou absent est traité comme vide et ne fait jamais échouer une requête (cf. `history.load`).

## État

L'état vit dans deux modules et nulle part ailleurs : `config.state` (connexions déclarées, connexion courante, `generation`) et `exec.slots` (un processus en vol par slot, `user` et `introspect`).
Le compteur `generation` est une garde d'annulation : un résultat qui revient après un changement de connexion est jeté.

## Persistance

Tout ce qui persiste vit sous `vim.fn.stdpath("data")/psql/` : `exports/` (CSV), `vars/<connexion>.json` (historique des variables), `<connexion>.sql` (scratchpad).
`vim.fn.mkdir(dir, "p")` avant toute écriture.

## Tests

MiniTest, lancés par `make test` (`nvim --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run()"`).
Un fichier par module de production, nommé `tests/test_<module>.lua`, commençant par `local helpers = dofile("tests/helpers.lua")` — `require()` ne cherche que dans `lua/`.
Assertions : `helpers.eq`, `helpers.neq`, `helpers.expect_match`.
Setup/teardown via `MiniTest.new_set({ hooks = { pre_case = ..., post_case = ... } })`.
Un test asynchrone attend avec `vim.wait(500, function() return got ~= nil end)`.

## Points d'injection

Pas de framework de mock, l'injection se fait par champ de module réassignable : `exec.runner` (par défaut `vim.system`, remplacé par un faux runner qui appelle `on_exit` immédiatement) et `pickers._telescope()` (renvoie `nil` pour simuler telescope absent).
Un test qui les remplace les restaure en `post_case`.

## Commits

Conventional commits, en anglais.
