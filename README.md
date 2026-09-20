This is the **entity** asset for TMC's **Dot** collection. It hands out the ids that every other addon keys its records by, and replaces the four incompatible schemes the games invented before it — one of which collided in silence.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## The Id Space Every World Object Shares

A game in this family already had a number for "which thing is this": `DotCombatManager` keys hitboxes, health, authoritative origins and its `entity_killed` signal by an `entity_id: int`. What it did not have was anywhere that number came from. Every game invented one, and no two agreed:

| | players | everything else |
| --- | --- | --- |
| a 3D deathmatch | the peer id | `1_000_000 + (instance_id % 1_000_000)` |
| an asymmetric round game | a counter handed out at spawn | — |
| a movement-timer server | the digits parsed out of a `"u123"` userid | — |

Three id spaces, three hand-written spellings of "is this one a player", and one of them collidable: two nodes whose engine instance ids differ by a multiple of a million produce the same entity id, so the second registers its health over the first and the loser simply stops taking damage. Nothing errors. Nothing can.

This addon is the allocator those three were missing, plus the two lookups each of them was maintaining by hand.

## What an id is

```
id = kind * 1_000_000_000_000 + serial
```

```gdscript
var id := DotEntity.make_id(DotEntity.KIND_NPC, 41)

DotEntity.kind_of(id)            # DotEntity.KIND_NPC
DotEntity.is_kind(id, DotEntity.KIND_PLAYER)   # false
DotEntity.describe_id(id)        # "npc#41"
```

**An id carries its own kind**, because the question asked most often about one is not "which entity" but "what sort of thing" — a kill feed deciding whether to write a name, a damage rule deciding whether friendly fire applies, a spectator deciding whether this is worth following. Every game answered it with a magic constant and a range check; here it is one division.

**A decimal stride rather than a bit layout**, because these numbers are read by people far more often than they are decoded by machines. They turn up in kill feeds, in `describe()` dumps, in server logs and in bug reports, and `2000000000041` is visibly the forty-first NPC.

**Zero is reserved and nothing can allocate it.** dot-combat already reads `entity_id == 0` as "no attacker" — a fall, drowning, the world — and every game relies on that. Reserving it here keeps that true by construction rather than by everybody remembering.

**Serials are never reused.** The shipped practice for handles like these is an index plus a generation counter, so a stale handle can be told from a live one that took its slot. Reusing nothing buys the same guarantee outright: an id that named a dead entity is simply absent from the table, for the life of the process, and every lookup that would have quietly found the wrong object finds nothing.

## The table

```gdscript
var table := DotEntityTable.new()

var opened := table.open(DotEntity.KIND_PLAYER, body, &"", player.userid)
if opened.ok:
    var handle: DotEntityHandle = opened.value
    combat.register_health(handle.id, health)

# ... on despawn, in this order:
table.close(handle.id, DotEntityTable.REASON_KILLED)
combat.forget(handle.id)
```

`open()` refuses a node that is already an entity, a key that already names one, a kind this build does not have, and a null node — each with a `DotResult` the caller can branch on. A refusal consumes no serial and leaves no half-written index entry.

`close()` does **not** free the node. Whoever put the node in the world takes it out; this forgets the bookkeeping. The order matters and it is the one above: close the handle first, so a listener on `closed` can still read where the entity was.

### Both directions, because both are asked constantly

| | |
| --- | --- |
| `id_for_node(node)` | a trace returns a `Node` and damage is keyed by id, so this runs once per pellet |
| `id_for_key(&"u123")` | a game keys its players by a name of its own and dot-combat keys by int |
| `key_for_id(id)` | the inverse, **looked up and never reconstructed** |

That last row is the whole reason `key` is a stored field rather than a formula. The two ends of one serialisation are exactly as capable of never meeting as the two ends of a wire, and a caller who hashes a name instead produces a number that is stable, plausible, and not the one the health and the hitboxes use.

### The sweep

`sweep()` closes every handle whose node was freed without anybody calling `close()` — a scene reload, a `queue_free` on a parent, a round reset. It returns how many and warns when that is not zero, because an orphan is recoverable but it means a despawn path somewhere is not calling `close()`. The per-entity dictionaries in dot-combat have the same shape and the same exposure; this is the one that can see it.

## The record

`DotEntityHandle` is kept **beside** the node, never on it. Metadata on a node is invisible to anything that did not put it there, survives into a saved scene, and is unreachable the moment the node is freed — and the tick an entity's record matters most is the tick it dies on, which is the tick its node goes away. dot-props, dot-npc and dot-vehicle each arrived at this independently and each wrote the paragraph.

It is the common half only. A prop is held, an NPC thinks, a vehicle has seats: those records keep their own fields and gain a handle.

Everything here is dimension-free. A 2D game gets a `Node2D` in the handle and the rest works unchanged; `position()` and `position_2d()` both guard on `is_inside_tree()`, because a global transform is undefined outside the tree and the two engine types disagree about what to do then — `Node3D` pushes an error with a backtrace stapled to it, `Node2D` quietly hands back a local position dressed as a global one.

## What is not here

No `Node` base class for entities to inherit. This family keeps state in a record beside the node precisely so nothing has to, a mandatory base class is a fork point, and we do not own the engine's `Node`.

No spawner, no catalogue, no budgets. Those are a real second layer — props, NPCs and vehicles have grown three near-identical `def` / `catalogue` / `limits` / `spawner` sets, down to two limit files of exactly the same length that differ only in prose — and extracting them is a change across three addons and a dozen consumers. It is designed in `CLAUDE.md` and not yet built, because an abstract base nobody subclasses is worse than no base at all.

## Who uses it

Four games, and the two that do not are the two with no combat entity ids at all — game-hungario resolves its eating in its own world model and game-simple-lobby has no `dot_combat` linked. Adding a dependency to either would be adding one for nothing.

| | what it replaced | what that cost |
| --- | --- | --- |
| game-arena | `1_000_000 + (instance_id % 1_000_000)` for monsters | two monsters a million instance ids apart shared an id, and the loser was unkillable |
| mg-buses-from-hell | a `_next_entity_id` counter, and no `forget()` anywhere | a `DotHealth` per player who ever joined, pointing at a freed node |
| game-g2gfast | `"u123"` → `123`, one function doing two jobs | none yet; the loadout filename and a session lookup were riding on a runtime handle |
| game-playground | a counter in one layer, a **name hash** in another | one player had two ids depending on which modes were switched on |

The client shell in dot-server-deploy links it too, and has to: a delivered game pack's scripts resolve addon `class_name`s against the host build, so an addon a game names must be in that list or the pack compiles to nothing.

## Installing

Copy `addons/dot_entity/` into your project. It depends on dot-core and on nothing else.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
timeout 120 godot --headless --path . res://examples/entity_selftest.tscn
```

109 checks over 9 sections. It asserts hardest on the properties the schemes it replaces did not have: ids are unique, serials never repeat, and a stale id finds nothing rather than finding somebody else.

## Licence

MIT. See [LICENSE](LICENSE).
