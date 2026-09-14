extends Node

## dot-entity: the id layout, the allocator, both reverse indexes, and every way a
## handle can go stale.
##
## [b]What this suite is really for.[/b] The thing it exercises replaces four
## hand-written id schemes that the games disagreed about, and one of those four was
## collidable -- two nodes whose engine instance ids differ by a multiple of a million
## produced the same combat entity id, silently. A replacement only helps if the
## replacement is the one that is right, so the properties the old schemes lacked are
## the ones asserted hardest here: ids are unique, ids are never reused, and a stale id
## finds nothing rather than finding somebody else.
##
## Sections:
##
##   1. The layout: a kind goes in, a kind comes out, and bad input stays bad.
##   2. Allocation: unique, monotonic per kind, and zero is never handed out.
##   3. The node index, that it survives the node being freed, and the 2D/3D halves.
##   4. The key index: a game's own name, both directions, looked up not reconstructed.
##   5. Refusals: a double-open, a duplicate key, a bad kind, a null node.
##   6. Closing: the handle is still readable, and the id is gone for good.
##   7. Ownership: one disconnect takes everything that player owned.
##   8. The sweep: a node freed behind the table's back is found and reported.
##   9. describe() and describe_lines() say something true.
##
## [b]Output this suite produces on purpose.[/b] Section 8 frees three nodes behind the
## table's back and the sweep warns about it, which is the sweep doing its job. The
## suite runs at [code]ERROR[/code] so that line is invisible unless you pass
## [code]--verbose[/code] -- worth knowing, because seeing it there is correct and
## [i]not[/i] seeing it under [code]--verbose[/code] would be the bug.
##
## Run:
## [codeblock]
## godot --headless --path . res://examples/entity_selftest.tscn
## [/codeblock]

var _entered := 0
var _completed := 0
var _passed := 0
var _failed := 0
var _failures: Array[String] = []

## Nodes this suite made, so teardown can free the ones it did not free on purpose.
var _made: Array[Node] = []


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("dot-entity: the id space every world object shares")

	_test_the_layout()
	_test_allocation()
	_test_the_node_index()
	_test_the_key_index()
	_test_refusals()
	_test_closing()
	_test_ownership()
	_test_the_sweep()
	_test_describe()

	_teardown()

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


# --- 1. The layout ----------------------------------------------------------

func _test_the_layout() -> void:
	_section("an id carries its own kind")

	var id := DotEntity.make_id(DotEntity.KIND_NPC, 41)

	_check(id > 0, "an id is made")
	_check(DotEntity.kind_of(id) == DotEntity.KIND_NPC, "the kind comes back out")
	_check(DotEntity.serial_of(id) == 41, "the serial comes back out")
	_check(DotEntity.is_kind(id, DotEntity.KIND_NPC), "is_kind agrees")
	_check(not DotEntity.is_kind(id, DotEntity.KIND_PLAYER), "and disagrees with the rest")

	# The readability the decimal stride was chosen for.
	_check(
		DotEntity.describe_id(id) == "npc#41",
		"describe_id reads as a person would say it",
		DotEntity.describe_id(id)
	)

	# Zero is dot-combat's "no attacker" and nothing may ever collide with it.
	_check(DotEntity.kind_of(0) == DotEntity.KIND_NONE, "zero is not a kind")
	_check(not DotEntity.is_valid(0), "zero is not a valid id")
	_check(DotEntity.describe_id(0) == "none", "zero describes as none")
	_check(DotEntity.make_id(DotEntity.KIND_NONE, 1) == 0, "KIND_NONE cannot be allocated")
	_check(DotEntity.make_id(DotEntity.KIND_NPC, 0) == 0, "serial zero cannot be allocated")

	# Total for input it did not produce, rather than indexing off the end of the
	# name table: an id off a wire is not one this build necessarily understands.
	_check(DotEntity.kind_of(-5) == DotEntity.KIND_NONE, "a negative id is not a kind")
	_check(
		DotEntity.kind_of((DotEntity.KIND_MAX + 3) * DotEntity.STRIDE) == DotEntity.KIND_NONE,
		"a kind from the future is not a kind"
	)
	_check(DotEntity.kind_name(99) == &"?", "an unknown kind still has a name")

	# Every kind must round-trip, or a name table and a constant have drifted.
	var all_round_trip := true

	for kind in range(DotEntity.KIND_NONE + 1, DotEntity.KIND_MAX + 1):
		var made := DotEntity.make_id(kind, 7)

		if DotEntity.kind_of(made) != kind or DotEntity.serial_of(made) != 7:
			all_round_trip = false

		if DotEntity.kind_name(kind) == &"?":
			all_round_trip = false

	_check(all_round_trip, "every kind round-trips and has a name (%d kinds)" % DotEntity.KIND_MAX)

	_done()


# --- 2. Allocation ----------------------------------------------------------

func _test_allocation() -> void:
	_section("the allocator hands out unique ids")

	var table := DotEntityTable.new()
	var seen := {}
	var all_unique := true
	var all_right_kind := true

	for i in range(200):
		var kind := DotEntity.KIND_NPC if i % 2 == 0 else DotEntity.KIND_PROP
		var opened := table.open(kind, _node("n%d" % i))

		if not opened.ok:
			all_unique = false
			break

		var handle: DotEntityHandle = opened.value

		if seen.has(handle.id):
			all_unique = false

		if handle.kind != kind or DotEntity.kind_of(handle.id) != kind:
			all_right_kind = false

		seen[handle.id] = true

	_check(all_unique, "200 ids, no repeats")
	_check(all_right_kind, "each id carries the kind it was opened with")
	_check(table.count() == 200, "the table holds all of them (%d)" % table.count())
	_check(table.count_of_kind(DotEntity.KIND_NPC) == 100, "and counts them by kind")

	# The property the old schemes did not have. Arena derived a monster's id from
	# `instance_id % 1_000_000`, so two nodes a million apart collided and one lost
	# its health registration with no error anywhere.
	var serials := table.ids_of_kind(DotEntity.KIND_NPC).map(
		func(id: int) -> int: return DotEntity.serial_of(id)
	)
	serials.sort()

	var monotonic := true

	for i in range(1, serials.size()):
		if int(serials[i]) <= int(serials[i - 1]):
			monotonic = false

	_check(monotonic, "serials are strictly increasing within a kind")
	_check(int(serials[0]) == 1, "and the first one is 1, not 0")

	_done()


# --- 3. The node index ------------------------------------------------------

func _test_the_node_index() -> void:
	_section("a node can be turned back into an entity")

	var table := DotEntityTable.new()
	var body := _node("Body")
	var handle: DotEntityHandle = table.open(DotEntity.KIND_PLAYER, body).value

	_check(table.id_for_node(body) == handle.id, "node -> id")
	_check(table.handle_for_node(body) == handle, "node -> handle")
	_check(table.id_for_node(null) == 0, "a null node is not an entity")
	_check(table.id_for_node(_node("Stranger")) == 0, "an unregistered node is not one either")

	# The reason the record is beside the node and not on it. A freed node takes its
	# metadata with it, and the tick an entity's record matters most is the tick it
	# dies on -- which is the tick its node goes away.
	var where := handle.position()
	body.free()

	_check(not is_instance_valid(body), "the node is really gone")
	_check(table.handle(handle.id) == handle, "the handle is still readable by id")
	_check(handle.owner_id == &"" and handle.id > 0, "and still carries its record")
	_check(not handle.is_alive(), "is_alive says the node has gone")
	_check(handle.position() == Vector3.ZERO, "position answers rather than crashing")
	_check(where == Vector3.ZERO, "a plain Node has no position, which is not an error")

	# The dimension-free half. A 2D game gets a Node2D here and nothing else changes,
	# which is only true if these four actually answer -- and an addon whose 2D path
	# is never exercised is an addon that has a 3D path.
	var flat := Node2D.new()
	flat.name = "Flat"
	flat.position = Vector2(3.0, 4.0)
	add_child(flat)
	_made.append(flat)

	var flat_handle: DotEntityHandle = table.open(DotEntity.KIND_PROP, flat).value

	_check(flat_handle.is_2d(), "a Node2D entity knows it is 2D")
	_check(flat_handle.node_2d() == flat, "node_2d hands it back")
	_check(flat_handle.node_3d() == null, "and node_3d does not pretend")
	_check(flat_handle.position_2d() == Vector2(3.0, 4.0), "position_2d answers in its own plane")
	_check(flat_handle.position() == Vector3.ZERO, "and the 3D one declines rather than guessing")

	var tall := Node3D.new()
	tall.name = "Tall"
	tall.position = Vector3(1.0, 2.0, 3.0)
	add_child(tall)
	_made.append(tall)

	var tall_handle: DotEntityHandle = table.open(DotEntity.KIND_PROP, tall).value

	_check(not tall_handle.is_2d(), "a Node3D entity knows it is not")
	_check(tall_handle.node_3d() == tall, "node_3d hands it back")
	_check(tall_handle.node_2d() == null, "and node_2d does not pretend")
	_check(tall_handle.position() == Vector3(1.0, 2.0, 3.0), "position answers in three")
	_check(tall_handle.position_2d() == Vector2.ZERO, "and the 2D one declines")

	# The guard on both, and the reason it is there: a global transform is only defined
	# inside the tree, and the engine's two answers for a node outside it disagree --
	# Node3D pushes an error with a backtrace and returns identity, Node2D silently
	# hands back a LOCAL position dressed as a global one. An entity is opened before
	# its node is parented, so this window is ordinary rather than exotic.
	var orphan_3d := Node3D.new()
	orphan_3d.name = "Orphan3D"
	orphan_3d.position = Vector3(9.0, 9.0, 9.0)
	_made.append(orphan_3d)

	var orphan_2d := Node2D.new()
	orphan_2d.name = "Orphan2D"
	orphan_2d.position = Vector2(9.0, 9.0)
	_made.append(orphan_2d)

	var o3: DotEntityHandle = table.open(DotEntity.KIND_PROP, orphan_3d).value
	var o2: DotEntityHandle = table.open(DotEntity.KIND_PROP, orphan_2d).value

	_check(o3.position() == Vector3.ZERO, "an unparented 3D entity has no position")
	_check(o2.position_2d() == Vector2.ZERO, "and neither has an unparented 2D one")
	_check(o3.is_alive() and o2.is_alive(), "though both are alive -- it is a real state")

	_done()


# --- 4. The key index -------------------------------------------------------

func _test_the_key_index() -> void:
	_section("a game's own name for an entity")

	var table := DotEntityTable.new()

	# The gap every game closed by hand: a game keys players by something of its own
	# and dot-combat keys by int.
	var handle: DotEntityHandle = table.open(
		DotEntity.KIND_PLAYER, _node("P"), &"", &"u123"
	).value

	_check(table.id_for_key(&"u123") == handle.id, "key -> id")
	_check(table.handle_for_key(&"u123") == handle, "key -> handle")
	_check(table.key_for_id(handle.id) == &"u123", "id -> key")
	_check(table.id_for_key(&"u999") == 0, "an unknown key is not an entity")

	# The point of storing it rather than deriving it: the id and the name have no
	# arithmetic relationship at all, so there is no formula for the two ends of this
	# to disagree about.
	_check(
		DotEntity.serial_of(handle.id) != 123,
		"the id is not derived from the name (serial %d)" % DotEntity.serial_of(handle.id)
	)

	table.close(handle.id)

	_check(table.id_for_key(&"u123") == 0, "closing releases the key")
	_check(
		table.open(DotEntity.KIND_PLAYER, _node("P2"), &"", &"u123").ok,
		"so a reconnecting player can take their name back"
	)

	_done()


# --- 5. Refusals ------------------------------------------------------------

func _test_refusals() -> void:
	_section("what it refuses, and with which code")

	var table := DotEntityTable.new()
	var body := _node("Body")

	var first := table.open(DotEntity.KIND_PROP, body)
	_check(first.ok, "the first open succeeds")

	# Always a bug, and a quiet one: the second id works, the first is still in the
	# table, and the node index now answers with whichever was written last.
	var again := table.open(DotEntity.KIND_PROP, body)
	_check(not again.ok, "a node cannot be opened twice")
	_check(
		not again.ok and again.code() == DotError.CODE_STATE,
		"and it is a state error",
		"" if again.ok else again.code()
	)

	var dupe_a := table.open(DotEntity.KIND_PLAYER, _node("A"), &"", &"same")
	var dupe_b := table.open(DotEntity.KIND_PLAYER, _node("B"), &"", &"same")
	_check(dupe_a.ok and not dupe_b.ok, "two entities cannot share a key")
	_check(
		not dupe_b.ok and dupe_b.code() == DotError.CODE_STATE,
		"and that is a state error too"
	)

	var bad_kind := table.open(DotEntity.KIND_NONE, _node("C"))
	_check(not bad_kind.ok, "KIND_NONE cannot be opened")
	_check(
		not bad_kind.ok and bad_kind.code() == DotError.CODE_INVALID,
		"and that is invalid, not a state error"
	)

	var too_big := table.open(DotEntity.KIND_MAX + 1, _node("D"))
	_check(not too_big.ok, "a kind this build does not have cannot be opened")

	var no_node := table.open(DotEntity.KIND_PROP, null)
	_check(not no_node.ok, "an entity without a node is refused")
	_check(
		not no_node.ok and no_node.code() == DotError.CODE_INVALID,
		"and that is invalid"
	)

	# A refused open must not consume a serial or leave a half-written index entry.
	var before := table.count()
	table.open(DotEntity.KIND_PROP, null)
	table.open(DotEntity.KIND_NONE, _node("E"))
	_check(table.count() == before, "a refusal changes nothing (%d)" % table.count())

	_done()


# --- 6. Closing -------------------------------------------------------------

func _test_closing() -> void:
	_section("closing, and what a stale id finds")

	var table := DotEntityTable.new()
	var body := _node("Body")
	var handle: DotEntityHandle = table.open(DotEntity.KIND_NPC, body).value
	var id := handle.id

	# Captured into an Array, not into a scalar: a lambda captures locals by value,
	# so a captured int assigned inside a signal handler stays at its initial value
	# and the check reads as a signal that never fired.
	var heard: Array = []
	table.closed.connect(func(h: DotEntityHandle, reason: StringName) -> void:
		heard.append([h.id, reason, h.node != null])
	)

	var closed := table.close(id, DotEntityTable.REASON_KILLED)

	_check(closed.ok, "close succeeds")
	_check(heard.size() == 1, "the closed signal fired")
	_check(heard.size() == 1 and int(heard[0][0]) == id, "carrying the id")
	_check(
		heard.size() == 1 and StringName(heard[0][1]) == DotEntityTable.REASON_KILLED,
		"and the reason"
	)
	# The whole argument for emitting the handle rather than the id: a listener handed
	# only an id would be looking it up in a table that has already forgotten it.
	_check(heard.size() == 1 and bool(heard[0][2]), "and a handle whose node is still readable")

	_check(not table.is_open(id), "the id is gone from the table")
	_check(table.handle(id) == null, "and looks up to nothing")
	_check(table.id_for_node(body) == 0, "the node index was cleaned up")
	_check(not handle.alive, "the handle knows it was closed")

	# The property that makes a stale id safe, and the reason serials are never
	# reused: a handle from last round cannot silently resolve to this round's
	# entity in the same slot.
	var fresh: DotEntityHandle = table.open(DotEntity.KIND_NPC, _node("Next")).value
	_check(fresh.id != id, "the next entity does not get the dead one's id")
	_check(table.handle(id) == null, "so the stale id still finds nothing")

	var twice := table.close(id)
	_check(not twice.ok, "closing twice is refused rather than silent")
	_check(not twice.ok and twice.code() == DotError.CODE_STATE, "as a state error")

	_check(table.close(0).ok == false, "and closing nothing is refused")

	_done()


# --- 7. Ownership -----------------------------------------------------------

func _test_ownership() -> void:
	_section("one disconnect takes everything that player owned")

	var table := DotEntityTable.new()

	for i in range(5):
		table.open(DotEntity.KIND_PROP, _node("a%d" % i), &"alice")

	for i in range(3):
		table.open(DotEntity.KIND_PROP, _node("b%d" % i), &"bob")

	table.open(DotEntity.KIND_NPC, _node("map"), &"")

	_check(table.handles_of_owner(&"alice").size() == 5, "alice owns five")
	_check(table.handles_of_owner(&"bob").size() == 3, "bob owns three")
	_check(table.handles_of_kind(DotEntity.KIND_PROP).size() == 8, "eight props between them")
	_check(table.handles_of_kind(DotEntity.KIND_NPC).size() == 1, "and one NPC that is nobody's")
	_check(
		table.handles_of_kind(DotEntity.KIND_VEHICLE).is_empty(),
		"a kind with none of them lists none"
	)
	_check(
		table.ids_of_kind(DotEntity.KIND_PROP).size() == 8,
		"and the id listing agrees with the handle listing"
	)

	var reasons: Array = []
	table.closed.connect(func(_h: DotEntityHandle, reason: StringName) -> void:
		reasons.append(reason)
	)

	var n := table.close_owner(&"alice")

	_check(n == 5, "closing alice's takes five (%d)" % n)
	_check(table.handles_of_owner(&"alice").is_empty(), "and leaves her none")
	_check(table.handles_of_owner(&"bob").size() == 3, "and does not touch bob's")
	_check(table.count() == 4, "the map's entity survives too (%d left)" % table.count())
	_check(
		reasons.size() == 5 and StringName(reasons[0]) == DotEntityTable.REASON_OWNER_LEFT,
		"with the reason a listener can act on"
	)

	_check(table.close_owner(&"nobody") == 0, "an owner with nothing closes nothing")

	_check(table.clear() == 4, "clear takes the rest")
	_check(table.count() == 0, "and leaves an empty table")

	_done()


# --- 8. The sweep -----------------------------------------------------------

func _test_the_sweep() -> void:
	_section("a node freed behind the table's back")

	var table := DotEntityTable.new()
	var doomed: Array[Node] = []

	for i in range(3):
		var n := _node("doomed%d" % i)
		doomed.append(n)
		table.open(DotEntity.KIND_PROP, n, &"someone")

	var kept := _node("kept")
	table.open(DotEntity.KIND_PROP, kept, &"someone")

	# The leak this addon is most likely to grow: a scene reload or a queue_free on a
	# parent frees nodes without anybody calling close(), and the table then holds a
	# record -- and dot-combat a health and a hitbox set -- for something that has not
	# existed since the last map.
	for n in doomed:
		n.free()

	_check(table.count() == 4, "the table has not noticed yet (%d)" % table.count())

	var reasons: Array = []
	table.closed.connect(func(_h: DotEntityHandle, reason: StringName) -> void:
		reasons.append(reason)
	)

	# Prints one WRN on purpose: an orphan is recoverable, but it means a despawn
	# path somewhere is not calling close().
	var swept := table.sweep()

	_check(swept == 3, "the sweep finds all three (%d)" % swept)
	_check(table.count() == 1, "and leaves the live one")
	_check(table.id_for_node(kept) != 0, "which is still indexed")
	_check(
		reasons.size() == 3 and StringName(reasons[0]) == DotEntityTable.REASON_ORPHANED,
		"closed with the reason that says it was not a despawn"
	)
	_check(table.sweep() == 0, "a second sweep finds nothing")

	_done()


# --- 9. describe ------------------------------------------------------------

func _test_describe() -> void:
	_section("describe says something true")

	var table := DotEntityTable.new()

	table.open(DotEntity.KIND_PLAYER, _node("p1"), &"", &"u1")
	table.open(DotEntity.KIND_PLAYER, _node("p2"), &"", &"u2")
	table.open(DotEntity.KIND_NPC, _node("n1"))

	var d := table.describe()

	_check(int(d["open"]) == 3, "describe counts what is open")
	_check(int(d["opened_total"]) == 3, "and what was ever opened")
	_check(int(d["keyed"]) == 2, "and how many are keyed")

	var by_kind: Dictionary = d["by_kind"]
	_check(int(by_kind.get("player", 0)) == 2, "broken down by kind")
	_check(not by_kind.has("vehicle"), "and kinds with none of them are left out")

	# opened_total must not go down when entities close, or it is not a total.
	table.clear()
	var after := table.describe()
	_check(int(after["open"]) == 0, "after a clear, nothing is open")
	_check(int(after["opened_total"]) == 3, "but the total still remembers three")

	var lines := table.describe_lines()
	var mentions_count := false

	for line in lines:
		if line.findn("3 ever") >= 0:
			mentions_count = true

	_check(lines.size() > 0, "describe_lines says something (%d lines)" % lines.size())
	_check(mentions_count, "including how many entities there have been")

	var handle: DotEntityHandle = table.open(DotEntity.KIND_VEHICLE, _node("v")).value
	var hd := handle.describe()

	_check(String(hd["id"]) == DotEntity.describe_id(handle.id), "a handle describes its id")
	_check(String(hd["kind"]) == "vehicle", "and its kind by name")
	_check(bool(hd["alive"]), "and whether it is alive")

	_done()


# --- Harness ----------------------------------------------------------------

## A node the suite owns. Registered so teardown can free whatever survived.
func _node(who: String) -> Node:
	var n := Node.new()
	n.name = who
	_made.append(n)
	return n


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _check(ok: bool, label: String, detail: String = "") -> bool:
	if ok:
		_passed += 1
		print("  ok    %s" % label)
	else:
		_failed += 1
		print("  FAIL  %s%s" % [label, "" if detail == "" else "  -- " + detail])
		_failures.append(label)
	return ok


func _teardown() -> void:
	for n in _made:
		if is_instance_valid(n):
			n.free()
