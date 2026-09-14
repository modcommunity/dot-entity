@tool
class_name DotEntityHandle
extends RefCounted

## One world object's record: its id, its kind, its node, and who put it there.
##
## [b]The record is kept beside the node, never on it.[/b] Metadata on a node is
## invisible to anything that did not put it there, survives into a saved scene, and is
## unreachable the moment the node is freed — and the moment an entity's record matters
## most is the tick it dies on, which is the tick its node goes away. dot-props,
## dot-npc and dot-vehicle each arrived at this independently and each wrote the
## paragraph; this is the one copy.
##
## [b]This is the common half only.[/b] A prop is held, an NPC thinks, a vehicle has
## seats — none of that is here, and none of it should be. Those records keep their own
## fields and gain a handle; see [member DotEntityHandle.meta] for the small stuff and a
## subclass for the rest.

## The id. Stable for the life of the process, never reused. See [DotEntity].
var id: int = 0

## What sort of thing this is. One of [DotEntity]'s [code]KIND_*[/code].
##
## Stored as well as encoded in [member id], because a comparison is cheaper than a
## division and this is read on every damage event.
var kind: int = DotEntity.KIND_NONE

## The node in the world. May be freed; check with [method is_alive].
##
## [b]Typed [Node] rather than [Node3D], because an entity is not always a 3D one.[/b]
## Everything this addon does — allocation, ownership, budgets, the lookup, the
## teardown — is about who put what in the world and what it cost, and none of it is
## about dimension. A 2D game gets a [Node2D] here and the rest works unchanged.
var node: Node = null

## The engine's instance id for [member node]. The handle's own back-reference.
##
## [b]An int rather than the node, because a comparison against a freed [Node] is
## undefined and an int is an int.[/b] Also what [DotEntityTable] keys its reverse
## index on, so a node can be turned back into an entity id without a scan.
var instance_id: int = 0

## Who is responsible for it: a player id, a director's id, or empty for the map.
var owner_id: StringName = &""

## The game's own name for this entity, or empty.
##
## [b]The bridge between two id spaces, and the reason it is a field rather than a
## convention.[/b] A game keys its players by something of its own — a
## [code]"u123"[/code] userid, a peer id, a roster slot — and dot-combat keys by int.
## Every game that met this gap closed it by reconstructing one from the other, and the
## one that wrote the reconstruction down warned about it in a comment: a caller that
## hashes the name produces a number that is stable, plausible, and not the one the
## health and the hitboxes use. Stored once and looked up
## ([method DotEntityTable.handle_for_key]) is the only version that cannot drift.
var key: StringName = &""

## Simulated seconds when it entered the world. Never a wall clock.
var spawned_at: float = 0.0

## Whether the table still considers this entity to exist.
##
## [b]Separate from the node being valid, and it has to be.[/b] [code]queue_free()[/code]
## is deferred, so [code]is_instance_valid[/code] stays true for the rest of the frame
## after an entity is removed — and anything that checked only the node would keep
## counting a despawned entity against a budget, keep pulling on a crate an admin has
## already cleaned up, or keep chasing a monster that is dead, for as long as that frame
## lasts.
var alive: bool = true

## Anything the game keeps with an entity. Not interpreted here.
var meta: Dictionary = {}


## Whether this entity is still in the world and its node is still real.
func is_alive() -> bool:
	return alive and node != null and is_instance_valid(node)


## Whether this handle names a [param p_kind].
func is_kind(p_kind: int) -> bool:
	return kind == p_kind


## Whether this entity lives in a 2D world.
##
## Asked rather than assumed: a host with both — a game with a 2D world and a 3D menu
## preview is exactly that — cannot tell from the id, because the id deliberately says
## nothing about dimension. The node knows.
func is_2d() -> bool:
	return node is Node2D


## The node as a [Node3D], or null.
func node_3d() -> Node3D:
	return node as Node3D


## The node as a [Node2D], or null.
func node_2d() -> Node2D:
	return node as Node2D


## Where it is, in 3D. [constant Vector3.ZERO] when it is dead, not 3D, or unparented.
##
## [b]The [code]is_inside_tree[/code] guard is not defensive padding.[/b] A global
## transform is only defined for a node in the tree, and the two engine types disagree
## about what to do when it is not: [Node3D] pushes
## [code]Condition "!is_inside_tree()" is true[/code] -- an engine error with a full
## GDScript backtrace stapled to it, per call -- and returns the identity, while
## [Node2D] quietly returns the local position instead. So the same unparented entity
## answers [code](0, 0, 0)[/code] noisily in 3D and its real coordinates silently in 2D.
##
## That window is real: an entity is opened so that its id exists before anything is
## wired to it, and it is not in the tree until the spawner adds it. Anything that
## polled a position in between -- a spawn-site check, a [code]describe()[/code] dump,
## a log line -- got eight lines of stderr that read exactly like a crash, for an
## expected state. Both directions now answer [constant Vector3.ZERO] /
## [constant Vector2.ZERO] and neither shouts.
func position() -> Vector3:
	if not is_alive() or not (node is Node3D) or not node.is_inside_tree():
		return Vector3.ZERO

	return (node as Node3D).global_position


## Where it is, in 2D. [constant Vector2.ZERO] when it is dead, not 2D, or unparented.
##
## The same guard, for the reason written on [method position] -- and here it is the
## guard that makes the two agree, because [Node2D] would otherwise hand back a local
## position dressed as a global one.
func position_2d() -> Vector2:
	if not is_alive() or not (node is Node2D) or not node.is_inside_tree():
		return Vector2.ZERO

	return (node as Node2D).global_position


func describe() -> Dictionary:
	return {
		"id": DotEntity.describe_id(id),
		"kind": String(DotEntity.kind_name(kind)),
		"owner": String(owner_id) if owner_id != &"" else "-",
		"key": String(key) if key != &"" else "-",
		"alive": is_alive(),
		"node": node.name if is_alive() else "-",
	}


func _to_string() -> String:
	return "DotEntityHandle(%s%s)" % [
		DotEntity.describe_id(id),
		"" if owner_id == &"" else " by " + String(owner_id),
	]
