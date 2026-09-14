@tool
class_name DotEntityTable
extends RefCounted

## Every world object a game currently knows about, and the only thing that hands out
## an entity id.
##
## [b]One allocator, because the alternative is what the tree already had.[/b] Four
## games each invented an id scheme for [code]DotCombatManager[/code] and no two
## agreed; one derived monster ids from engine instance ids modulo a million, which
## collides in silence and costs the loser its health registration. An allocator is
## three fields and a counter, and it is the difference between "these numbers are
## unique" being a property of the code and being a hope.
##
## [b]Two reverse indexes, because both directions are asked constantly.[/b] A trace
## returns a [Node] and damage is keyed by id, so node → id runs once per pellet;
## [code]DotCombatManager[/code] already carried a hand-rolled copy of exactly this map.
## And a game keys its own players by name, so key → id runs on every chat line, vote
## and kill feed entry. Both are maintained here so neither can drift from the table.
##
## [codeblock]
## var table := DotEntityTable.new()
##
## var opened := table.open(DotEntity.KIND_PLAYER, body, &"", player.userid)
## if opened.ok:
##     var handle: DotEntityHandle = opened.value
##     combat.register_health(handle.id, health)
##
## # ... later, on despawn:
## table.close(handle.id, DotEntityTable.REASON_DESPAWN)
## combat.forget(handle.id)
## [/codeblock]
##
## [b]Not a [Node], and not an autoload.[/b] A table belongs to a game, and a process
## running a server and a client — or two servers in one editor session — has two of
## them. It has no tick and nothing to place, so it is a plain object a game owns.

const CHANNEL := "entity"

## An entity entered the world.
signal opened(handle: DotEntityHandle)

## An entity left it. [param reason] is one of the REASON_* constants, or a game's own.
##
## [b]Emitted with the handle rather than with the id.[/b] The one moment an entity's
## record is most wanted is the moment it stops existing, and a listener handed only an
## id would have to look it up in a table that has already forgotten it.
signal closed(handle: DotEntityHandle, reason: StringName)

const REASON_DESPAWN := &"despawn"    ## Ordinary removal.
const REASON_KILLED := &"killed"      ## It died.
const REASON_OWNER_LEFT := &"owner_left"  ## Whoever owned it disconnected.
const REASON_CLEANUP := &"cleanup"    ## An admin or a round reset cleared the world.
const REASON_ORPHANED := &"orphaned"  ## Its node was freed without telling the table.

## Whether [method sweep] runs automatically inside [method count] and the listings.
##
## [b]Off by default, and the reason is the cost.[/b] A sweep walks every handle, and
## the listings are called from per-frame code. A game that frees nodes itself — which
## is most of them, because a scene reload frees everything at once — should call
## [method sweep] once per tick or once per round instead.
var auto_sweep: bool = false

## id -> [DotEntityHandle].
var _by_id: Dictionary = {}

## Engine instance id -> entity id. The node → entity direction.
var _by_instance: Dictionary = {}

## Game key -> entity id. The name → entity direction.
var _by_key: Dictionary = {}

## Kind -> the next serial to hand out for it.
##
## Per kind rather than one counter, so [code]npc#1[/code] and [code]player#1[/code] can
## both exist and a reader of a log is not asked to hold a global ordering in their
## head to tell which of two entities is older within its own kind.
var _next_serial: Dictionary = {}

## How many ids this table has ever handed out. Diagnostics only.
var _opened_total: int = 0


## Puts an entity into the table and gives it an id.
##
## [param key] is the game's own name for it, and may be empty. [param now] is
## simulated seconds; never pass a wall clock.
##
## Fails with [constant DotError.CODE_INVALID] for a kind that is not one of
## [DotEntity]'s or a node that is null, with [constant DotError.CODE_STATE] for a node
## or a key that is already in the table, and with
## [constant DotError.CODE_QUOTA] when a kind has exhausted its serials.
func open(
	kind: int,
	node: Node,
	owner_id: StringName = &"",
	key: StringName = &"",
	now: float = 0.0
) -> DotResult:
	if kind <= DotEntity.KIND_NONE or kind > DotEntity.KIND_MAX:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"That is not an entity kind.",
			"kind=%d" % kind
		)

	if node == null or not is_instance_valid(node):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"An entity needs a node.",
			DotEntity.kind_name(kind)
		)

	var instance_id := node.get_instance_id()

	# Double-opening one node is always a bug, and a quiet one: the second id works
	# perfectly, the first is still in the table, and every lookup that goes through
	# the node index now answers with whichever was written last. Two health
	# registrations for one body is a player who takes half damage.
	if _by_instance.has(instance_id):
		return DotResult.fail(
			DotError.CODE_STATE,
			"That node is already an entity.",
			DotEntity.describe_id(int(_by_instance[instance_id]))
		)

	if key != &"" and _by_key.has(key):
		return DotResult.fail(
			DotError.CODE_STATE,
			"That key already names an entity.",
			"%s -> %s" % [String(key), DotEntity.describe_id(int(_by_key[key]))]
		)

	var serial := int(_next_serial.get(kind, 1))

	if serial > DotEntity.SERIAL_MAX:
		# Reachable only after a trillion spawns of one kind, which is decades of a
		# busy server -- but "unreachable" is what every id scheme in this tree
		# assumed, and one of them was wrong within a single map. A refusal a caller
		# can see beats a silent wrap onto live ids.
		DotLog.error(CHANNEL, "entity serials exhausted for a kind", {
			"kind": String(DotEntity.kind_name(kind)),
			"max": DotEntity.SERIAL_MAX,
		})

		return DotResult.fail(
			DotError.CODE_QUOTA,
			"This kind has no entity ids left.",
			String(DotEntity.kind_name(kind))
		)

	_next_serial[kind] = serial + 1

	var handle := DotEntityHandle.new()
	handle.id = DotEntity.make_id(kind, serial)
	handle.kind = kind
	handle.node = node
	handle.instance_id = instance_id
	handle.owner_id = owner_id
	handle.key = key
	handle.spawned_at = now
	handle.alive = true

	_by_id[handle.id] = handle
	_by_instance[instance_id] = handle.id

	if key != &"":
		_by_key[key] = handle.id

	_opened_total += 1

	DotLog.debug(CHANNEL, "entity opened", {
		"id": DotEntity.describe_id(handle.id),
		"owner": String(owner_id),
		"key": String(key),
	})

	opened.emit(handle)

	return DotResult.success(handle)


## Takes an entity out of the table.
##
## [b]Does not free the node.[/b] Whoever put the node in the world takes it out; this
## forgets the bookkeeping. The order matters and it is this one: close the handle,
## then free the node, so a listener on [signal closed] can still read where it was.
##
## Returns the handle on success, and fails with [constant DotError.CODE_STATE] for an
## id the table does not hold — which includes one that was already closed, because
## serials are never reused and a stale id is therefore simply absent.
func close(id: int, reason: StringName = REASON_DESPAWN) -> DotResult:
	var handle: DotEntityHandle = _by_id.get(id)

	if handle == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"No such entity.",
			DotEntity.describe_id(id)
		)

	handle.alive = false

	_by_id.erase(id)
	_by_instance.erase(handle.instance_id)

	if handle.key != &"":
		_by_key.erase(handle.key)

	DotLog.debug(CHANNEL, "entity closed", {
		"id": DotEntity.describe_id(id),
		"reason": String(reason),
	})

	closed.emit(handle, reason)

	return DotResult.success(handle)


## Closes every entity [param owner_id] is responsible for. Returns how many.
func close_owner(owner_id: StringName, reason: StringName = REASON_OWNER_LEFT) -> int:
	# Collected before erasing: a Dictionary mutated during its own iteration is
	# undefined here as it is everywhere.
	var doomed: Array[int] = []

	for id: int in _by_id:
		var handle: DotEntityHandle = _by_id[id]

		if handle.owner_id == owner_id:
			doomed.append(id)

	for id in doomed:
		close(id, reason)

	return doomed.size()


## Closes every handle whose node has been freed out from under the table.
##
## [b]The leak this addon is most likely to grow, so it has a name and a counter.[/b]
## A scene reload, a [code]queue_free[/code] on a parent, or a round reset frees nodes
## without anybody calling [method close] — and the table then holds a handle, a health
## record and a hitbox set for something that has not existed since the last map. The
## per-entity dictionaries in dot-combat have the same shape and the same exposure.
##
## Returns how many it closed, and warns when that is not zero: an orphan is recoverable
## but it means a despawn path somewhere is not calling [method close].
func sweep(reason: StringName = REASON_ORPHANED) -> int:
	var doomed: Array[int] = []

	for id: int in _by_id:
		var handle: DotEntityHandle = _by_id[id]

		if handle.node == null or not is_instance_valid(handle.node):
			doomed.append(id)

	for id in doomed:
		close(id, reason)

	if not doomed.is_empty():
		DotLog.warn(CHANNEL, "entities were freed without being closed", {
			"count": doomed.size(),
		})

	return doomed.size()


## Closes everything. Returns how many.
func clear(reason: StringName = REASON_CLEANUP) -> int:
	var doomed: Array[int] = []

	for id: int in _by_id:
		doomed.append(id)

	for id in doomed:
		close(id, reason)

	return doomed.size()


## The handle for an id, or null.
func handle(id: int) -> DotEntityHandle:
	return _by_id.get(id)


## The handle for a node, or null.
func handle_for_node(node: Node) -> DotEntityHandle:
	if node == null or not is_instance_valid(node):
		return null

	return _by_id.get(_by_instance.get(node.get_instance_id(), 0))


## The handle for a game's own key, or null.
func handle_for_key(key: StringName) -> DotEntityHandle:
	return _by_id.get(_by_key.get(key, 0))


## The entity id for a node, or 0.
##
## The hot one: a trace returns a node and damage is keyed by id, so this runs once per
## pellet. A lookup rather than an arithmetic reconstruction, for the reason the whole
## addon exists.
func id_for_node(node: Node) -> int:
	if node == null or not is_instance_valid(node):
		return 0

	return int(_by_instance.get(node.get_instance_id(), 0))


## The entity id for a game's own key, or 0.
func id_for_key(key: StringName) -> int:
	return int(_by_key.get(key, 0))


## The game's own key for an entity id, or empty.
##
## [b]Looked up, never reconstructed.[/b] The inverse of a formula is a second spelling
## of one serialisation, and the two ends of one serialisation are exactly as capable of
## never meeting as the two ends of a wire.
func key_for_id(id: int) -> StringName:
	var found: DotEntityHandle = _by_id.get(id)

	return found.key if found != null else &""


## Whether the table still holds this id.
func is_open(id: int) -> bool:
	return _by_id.has(id)


## Whether the table holds it and its node is still real.
func is_alive(id: int) -> bool:
	var found: DotEntityHandle = _by_id.get(id)

	return found != null and found.is_alive()


## How many entities are open.
func count() -> int:
	if auto_sweep:
		sweep()

	return _by_id.size()


## How many entities of one kind are open.
func count_of_kind(kind: int) -> int:
	var n := 0

	for id: int in _by_id:
		if (_by_id[id] as DotEntityHandle).kind == kind:
			n += 1

	return n


## Every open id.
func ids() -> Array[int]:
	if auto_sweep:
		sweep()

	var out: Array[int] = []

	for id: int in _by_id:
		out.append(id)

	return out


## Every open id of one kind.
func ids_of_kind(kind: int) -> Array[int]:
	var out: Array[int] = []

	for id: int in _by_id:
		if (_by_id[id] as DotEntityHandle).kind == kind:
			out.append(id)

	return out


## Every open handle of one kind.
func handles_of_kind(kind: int) -> Array[DotEntityHandle]:
	var out: Array[DotEntityHandle] = []

	for id: int in _by_id:
		var found: DotEntityHandle = _by_id[id]

		if found.kind == kind:
			out.append(found)

	return out


## Every open handle one owner is responsible for.
func handles_of_owner(owner_id: StringName) -> Array[DotEntityHandle]:
	var out: Array[DotEntityHandle] = []

	for id: int in _by_id:
		var found: DotEntityHandle = _by_id[id]

		if found.owner_id == owner_id:
			out.append(found)

	return out


func describe() -> Dictionary:
	var by_kind := {}

	for kind in range(DotEntity.KIND_NONE + 1, DotEntity.KIND_MAX + 1):
		var n := count_of_kind(kind)

		if n > 0:
			by_kind[String(DotEntity.kind_name(kind))] = n

	return {
		"open": _by_id.size(),
		"opened_total": _opened_total,
		"by_kind": by_kind,
		"keyed": _by_key.size(),
		"auto_sweep": auto_sweep,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var d := describe()

	out.append("entities: %d open, %d ever" % [d["open"], d["opened_total"]])

	var by_kind: Dictionary = d["by_kind"]

	for name in by_kind:
		out.append("  %-10s %d" % [name, int(by_kind[name])])

	if _by_key.is_empty():
		out.append("  no keyed entities")
	else:
		out.append("  %d keyed by the game's own names" % _by_key.size())

	return out


func _to_string() -> String:
	return "DotEntityTable(%d open, %d ever)" % [_by_id.size(), _opened_total]
