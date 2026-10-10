# dot-entity design

Why the id space is shaped the way it is, what is deliberately not built yet, and why it is its own repository. The one-line rules are in [CLAUDE.md](../CLAUDE.md).

## The layout, and what is load-bearing

`id = kind * STRIDE + serial`, `STRIDE = 1e12`, kinds 1..8, zero reserved.

Four things about it are decisions rather than details, and each has a comment at its definition:

1. **Kind constants are plain `int`s, not an `enum`.** The kind is multiplied into an id and sent over the wire inside that id. An enum invites `KIND_X as int` at every boundary and buys nothing; the numbers are part of the format, so they are written as numbers.
2. **Zero is not a kind.** dot-combat reads `attacker == 0` as "no attacker" (`DotDamage`) and every game depends on it.
3. **The stride is decimal.** These numbers are read by people, not decoded by machines. `2000000000041` is visibly `npc#41`.
4. **Serials are never reused, per kind.** A stale id is absent rather than wrong. `open()` refuses with `CODE_QUOTA` after a trillion of one kind rather than wrapping onto live ids: reachable only after decades, but "unreachable" is what every scheme it replaced assumed, and one of them was wrong inside a single map ([history](history.md)).

`KIND_NAMES` is indexed by kind rather than matched, so adding a kind is one line in two adjacent places instead of two edits in two files. The suite asserts every kind round-trips *and* has a name, which is what catches the half-done addition.

## Positions before the node is in the tree

`open()` before the node is in the tree is the ordinary case, because an id has to exist before anything is wired to it. `DotEntityHandle.position()` and `position_2d()` therefore guard on `is_inside_tree()`. Without the guard `Node3D.global_position` pushes `Condition "!is_inside_tree()" is true` with a full GDScript backtrace, per call, for a completely expected state, which reads to an admin exactly like a crash, while `Node2D` silently returns the *local* position instead, so the same entity answers differently in the two dimensions. The suite asserts both sides.

## Lifetimes: close, then free, then sweep

`close()` forgets bookkeeping only; nothing frees nodes for you. Close first, then free, or a `closed` listener cannot read where the entity was.

A node freed without `close()` leaks a handle for the life of the process, because serials are never reused and nothing polls. That is what `sweep()` is for, and it logs a WARN naming how many it found (the suite provokes this on purpose: under `--verbose` the line appearing is correct, and its absence would be the bug). `auto_sweep` exists and defaults to **off**: a sweep walks every handle and the listings are called from per-frame code. Call `sweep()` once per tick or once per round instead.

`count()` and `ids()` honour `auto_sweep`; `count_of_kind()`, `ids_of_kind()` and the handle listings do not. That asymmetry is deliberate (the kind listings are the hot ones) and it is exactly the sort of thing a reader will "simplify" into a per-frame full scan.

## The second layer, designed and not built

dot-props, dot-npc and dot-vehicle have each independently grown the same six-file set: `def` / `catalogue` / `limits` / `instance` / `spawner` / `net_sync`.

- The three `*Instance` records share `node`, `instance_id`, `owner_id`, `spawned_at` and `alive`, and all three carry the same paragraph about why `alive` cannot be `is_instance_valid`. `DotEntityHandle` holds that half, but none of the three extends or uses it yet.
- `dot_npc_limits.gd` and `dot_prop_limits.gd` differ mostly in prose.
- The three spawners share a set of identically named methods: `spawn`, `_prepare`, `_adopt`, `may_spawn`, `_refuse`, `remove`, `clear_owner`, `clear_all`, `owner_left`, `X_for_node`, `world_count`, `world_cost`, `all_X`, `_resolve_world`, `describe`, `describe_lines`.
- The catalogues (props, npc, vehicle, weapon) are near-copies of one another.

A `DotEntityDef` / `DotEntityCatalogue` / `DotEntityLimits` / `DotEntitySpawner` base is the obvious extraction and it is **deliberately not here yet**. Shipping an abstract base that nothing subclasses is worse than shipping none: it is dead code that reads as an API, and this family has a detector for exactly that. It lands when props, NPCs and vehicles are converted in the same pass, which is a change across three addons plus every project that links them, each needing its own `--import`.

The behaviour half stays where it is regardless. An NPC thinks, a vehicle has seats, a prop is held; none of that is common and none of it should move.

## Why this is its own repository and not part of dot-core

It very nearly was. dot-core is linked in every project, so putting the table there would cost no new dependency edge, and the argument for that is real.

Against it: dot-core is the foundation (logging, platform capabilities, paths, transports, randomness) and none of it knows what a game is. An entity table is a runtime game concept with a lifetime tied to a match. Putting it in dot-core would be the first thing there that only a game uses.

If dot-combat, dot-effects or dot-net ever need the handle *without* taking a dot-entity dependency, that argument flips and `DotEntity` plus `DotEntityTable` move to dot-core. They are two files with no dependencies of their own, which is the shape that makes such a move cheap; keep it that way.
