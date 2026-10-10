# dot-entity history

## Why it exists: every game invented its own entity id

`DotCombatManager` has always keyed by `entity_id: int` and never said where one comes from, so the games filled the gap independently:

- game-arena: the peer id for players, `ENTITY_BASE + (npc.instance_id % ENTITY_BASE)` for monsters with `ENTITY_BASE = 1_000_000`, and `is_npc_entity()` as a range check.
- mg-buses-from-hell: a `_next_entity_id` counter incremented per player at spawn.
- game-g2gfast: `entity_id_for("u123") == 123`, with a `player_id_for` inverse that was *looked up rather than reconstructed*, and a comment explaining why that matters. That comment was this addon describing itself before it existed.
- game-hungario and game-playground: variants of the same.

The arena scheme was collidable. Two NPCs whose engine instance ids differ by a multiple of a million got the same entity id; the second `register_health` overwrote the first, and the loser stopped taking damage with no error anywhere. Godot instance ids are not small and not dense, so the modulo was doing real work. The symptom to recognise if a hand-rolled scheme ever comes back: one monster in a crowd that cannot be hurt, and nothing in the log.

None of this was carelessness. There was nowhere to put it. game-arena and mg-buses-from-hell have since moved to `DotEntityTable` (their comments record what was replaced).
