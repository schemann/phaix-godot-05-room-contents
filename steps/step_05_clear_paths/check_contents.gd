extends SceneTree
## Checks the contents of the rooms, for seeds 1 to 1000. Data only, like check_solvable.gd: no level is
## started and no player walks, the chain is asked for its plans and the plans are read against the
## room scenes. Content needs rules too, and a check proves them for every seed, not for the lucky seed 42:
## props must never block the way, never sit on a key or in a door, and a rare room must stay rare.
##
##   godot --headless --path godot/05-room-contents -s res://steps/step_05_clear_paths/check_contents.gd
##
## Option: `-- --seeds=200` checks seeds 1 to 200 only. The exit code is 0 if every seed passes and
## 1 if any fails, so a build server can run it. The solvability rules of check_solvable.gd are
## part of it: a decorated chain must still be one a player can finish.

const Chain := preload("room_chain.gd")
const DoorScene := preload("door.tscn")
const Solvable := preload("check_solvable.gd")

const DEFAULT_SEEDS := 1000
const GOAL_ROOM := 20
const LOCK_CHANCES: Array[float] = [0.4, 1.0] ## The level's default, and the worst case: every room that can be locked is.
const CORRIDOR_WIDTH := 2.0 ## Metres. The way from the entrance to the exit: a player is 0.8 m wide, this leaves 0.6 m on each side.
const KEY_WAY_WIDTH := 1.6 ## Metres. The straight way from the entrance to a key, and from the key to the exit.
const KEY_CLEARANCE := 1.0 ## Metres between a prop and a key spot.
const WALL := 0.2 ## Metres. A wall's thickness: the inside of a room begins behind it.

static var _footprints := {} ## [prop scene path, spot] -> the prop's footprint in the room.

## What the rules need to know about one room type, read from its scene.
class Layout:
	var inside := Rect2() ## The floor between the walls, in the room's own space (x, z).
	var corridor := PackedVector2Array() ## From the entrance to the exit, 2 m wide.
	var key_spots: Array[Vector2] = []
	var key_ways: Array[PackedVector2Array] = [] ## From the entrance to each key spot, and from each key spot to the exit.
	var door_zones: Array[Rect2] = [] ## The exit door's trigger and swing, and the swing of the door in the entrance.
	var fixtures: Array[Rect2] = [] ## What stands in the room for good: the vault's pillars and platform.
	var prop_spots: Array[Transform3D] = []

func _initialize() -> void:
	var seed_count := DEFAULT_SEEDS
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--seeds="):
			seed_count = int(argument.trim_prefix("--seeds="))

	var layouts := read_layouts()
	var failed := 0
	for chance in LOCK_CHANCES:
		var rooms := 0
		var props := 0
		var spots := 0
		var vaults := 0
		var seeds_with_vault := 0
		var locked_rooms := 0
		var seeds_with_problems := 0
		for chain_seed in range(1, seed_count + 1):
			if chain_seed % 100 == 0:
				await process_frame # every chain reads seven room scenes: let the engine empty its queue now and then
			var chain := Solvable.build(chain_seed, GOAL_ROOM, chance)
			var problems := problems_of(chain, build_without_props(chain_seed, GOAL_ROOM, chance), layouts)
			problems.append_array(Solvable.problems_of(chain, Solvable.build(chain_seed, GOAL_ROOM, 0.0)))
			var vaults_here := 0
			for plan in chain.plans:
				rooms += 1
				locked_rooms += 1 if plan.locked else 0
				vaults_here += 1 if plan.type == Chain.Type.VAULT else 0
				spots += plan.props.size()
				for prop in plan.props:
					props += 1 if prop != Chain.NO_PROP else 0
			vaults += vaults_here
			seeds_with_vault += 1 if vaults_here > 0 else 0
			if not problems.is_empty():
				seeds_with_problems += 1
				if seeds_with_problems <= 5: # the first few are enough to find the cause
					for problem in problems:
						printerr("seed %d, lock chance %.1f: %s" % [chain_seed, chance, problem])
		print("seeds 1-%d, lock chance %.1f: %d rooms, %d props on %d prop spots, %d vaults (%d seeds have one), %d locked rooms, %d seeds with problems" % [seed_count, chance, rooms, props, spots, vaults, seeds_with_vault, locked_rooms, seeds_with_problems])
		failed += seeds_with_problems
	print("CONTENTS " + ("OK" if failed == 0 else "FAILED: %d seeds" % failed))
	quit(1 if failed > 0 else 0)

#region The rules

## The same chain with every prop spot taken away: the twin that proves the props change nothing but the props.
static func build_without_props(chain_seed: int, goal_room: int, chance: float) -> Chain:
	var chain := Chain.new(chain_seed, goal_room, chance)
	chain.clear_prop_spots()
	while chain.plans.size() < Solvable.MAX_PLANS:
		if chain.next_plan().type == Chain.Type.GOAL:
			break
	return chain

## Every way the contents of a chain could be wrong, as sentences. Empty: fine.
## bare is the same seed, goal and lock chance without any prop spot; layouts come from read_layouts().
static func problems_of(chain: Chain, bare: Chain, layouts: Array[Layout]) -> Array[String]:
	var problems: Array[String] = []

	# Props never change the rooms or the locks: the same rooms in the same places, as without props.
	if chain.plans.size() != bare.plans.size():
		problems.append("%d rooms with props, %d without" % [chain.plans.size(), bare.plans.size()])
	for i in mini(chain.plans.size(), bare.plans.size()):
		var plan := chain.plans[i]
		var other := bare.plans[i]
		if plan.type != other.type or plan.transform != other.transform or plan.bounds != other.bounds or plan.locked != other.locked or plan.key_spot != other.key_spot:
			problems.append("room %d is not the room it is without props" % i)
			break

	# A rare room stays rare: two vaults are at least min_gap rooms apart.
	var min_gap: int = Chain.ROOM_WEIGHTS.min_gap
	var last_vault := -1
	for plan in chain.plans:
		if plan.type != Chain.Type.VAULT:
			continue
		if last_vault >= 0 and plan.index - last_vault < min_gap:
			problems.append("the vaults in rooms %d and %d are %d rooms apart, the gap is %d" % [last_vault, plan.index, plan.index - last_vault, min_gap])
		last_vault = plan.index

	for plan in chain.plans:
		problems.append_array(_room_problems(chain, plan, layouts[plan.type]))
	return problems

static func _room_problems(chain: Chain, plan: Chain.Plan, layout: Layout) -> Array[String]:
	var problems: Array[String] = []
	var where := "room %d (type %d)" % [plan.index, plan.type]
	if plan.props.size() != layout.prop_spots.size():
		problems.append("%s has %d props for %d prop spots" % [where, plan.props.size(), layout.prop_spots.size()])
		return problems

	# Where each placed prop stands: its footprint on the floor, by spot.
	var feet: Dictionary[int, Rect2] = {}
	var names: Dictionary[int, String] = {}
	for spot in plan.props.size():
		var prop := plan.props[spot]
		if prop == Chain.NO_PROP:
			continue
		if prop < 0 or prop >= Chain.PROP_SETS[plan.type].scenes.size():
			problems.append("%s: spot %d holds prop %d, which its room type does not have" % [where, spot, prop])
			continue
		var scene := chain.prop_scene(plan.type, prop)
		feet[spot] = footprint(scene, layout.prop_spots[spot])
		names[spot] = "%s at spot %d" % [scene.resource_path.get_file().get_basename(), spot]

	for spot: int in feet:
		var foot := feet[spot]
		var what := "%s: the %s" % [where, names[spot]]
		if not layout.inside.encloses(foot):
			problems.append("%s sticks into a wall" % what)
		if overlaps(layout.corridor, foot):
			problems.append("%s stands in the walking corridor from the entrance to the exit" % what)
		for key in layout.key_spots.size():
			if distance_to_rect(layout.key_spots[key], foot) < KEY_CLEARANCE:
				problems.append("%s is within %.0f m of key spot %d" % [what, KEY_CLEARANCE, key])
		for zone in layout.door_zones:
			if foot.intersects(zone):
				problems.append("%s stands in a door's trigger or swing" % what)
				break
		for way in layout.key_ways.size():
			if overlaps(layout.key_ways[way], foot):
				problems.append("%s blocks the way between the entrance, key spot %d and the exit" % [what, floori(way / 2.0)])
		for fixture in layout.fixtures:
			if foot.intersects(fixture):
				problems.append("%s stands on a pillar or a platform of the room" % what)
		for other: int in feet:
			if other > spot and foot.intersects(feet[other]):
				problems.append("%s overlaps the %s" % [what, names[other]])
	return problems

## Reads every room type of the chain: where its markers are, which way is clear, what stands in it for good.
static func read_layouts() -> Array[Layout]:
	var layouts: Array[Layout] = []
	var door := DoorScene.instantiate()
	var trigger := door.get_node("Trigger") as Area3D
	var swing := door.get_node("Swing") as Area3D
	for scene in Chain.SCENES:
		var room := scene.instantiate()
		var layout := Layout.new()
		var entrance := room.get_node("Entrance") as Marker3D
		var exit_marker := room.get_node_or_null("Exit") as Marker3D # the goal room has none
		var inside := room.get_node("Inside/CollisionShape3D") as CollisionShape3D
		layout.inside = _shape_rect((inside.get_parent() as Node3D).transform, inside).grow(-WALL)
		layout.door_zones.append(_shape_rect(entrance.transform * swing.transform, swing.get_node("CollisionShape3D") as CollisionShape3D))
		if exit_marker != null:
			layout.corridor = corridor(_flat(entrance.position), _flat(exit_marker.position), CORRIDOR_WIDTH)
			layout.door_zones.append(_shape_rect(exit_marker.transform * trigger.transform, trigger.get_node("CollisionShape3D") as CollisionShape3D))
			layout.door_zones.append(_shape_rect(exit_marker.transform * swing.transform, swing.get_node("CollisionShape3D") as CollisionShape3D))
			for spot in room.get_node("KeySpots").get_children():
				var key := _flat((spot as Marker3D).position)
				layout.key_spots.append(key)
				layout.key_ways.append(corridor(_flat(entrance.position), key, KEY_WAY_WIDTH))
				layout.key_ways.append(corridor(key, _flat(exit_marker.position), KEY_WAY_WIDTH))
			for spot in room.get_node("PropSpots").get_children():
				layout.prop_spots.append((spot as Marker3D).transform)
		for part in room.get_node("Shell").get_children():
			if part is CSGBox3D and not (part.name == &"Floor" or part.name.begins_with("Wall")):
				layout.fixtures.append(_rect(part.transform, (part as CSGBox3D).size / 2.0))
			elif part is CSGCylinder3D:
				var radius := (part as CSGCylinder3D).radius
				layout.fixtures.append(_rect(part.transform, Vector3(radius, 0.0, radius)))
		layouts.append(layout)
		room.free()
	door.free()
	return layouts

#endregion

#region Geometry on the floor (x and z of the room's own space)

## Where a prop of this scene stands when it is put on a spot: the rectangle its collision shapes cover.
static func footprint(scene: PackedScene, spot: Transform3D) -> Rect2:
	var key: Array = [scene.resource_path, spot]
	if _footprints.has(key):
		return _footprints[key]
	var prop := scene.instantiate()
	var covered := Rect2()
	var first := true
	for child in prop.get_children():
		var shape_node := child as CollisionShape3D
		if shape_node == null:
			continue
		var half := Vector3.ZERO
		if shape_node.shape is BoxShape3D:
			half = (shape_node.shape as BoxShape3D).size / 2.0
		elif shape_node.shape is CylinderShape3D:
			half = Vector3((shape_node.shape as CylinderShape3D).radius, 0.0, (shape_node.shape as CylinderShape3D).radius)
		else:
			push_error("check_contents: %s has a %s, which the footprint does not know" % [scene.resource_path, shape_node.shape])
		var rect := _rect(spot * shape_node.transform, half)
		covered = rect if first else covered.merge(rect)
		first = false
	prop.free()
	_footprints[key] = covered
	return covered

## The rectangle a box shape covers on the floor; parent_to_room brings the shape's parent into the room's space.
static func _shape_rect(parent_to_room: Transform3D, shape_node: CollisionShape3D) -> Rect2:
	return _rect(parent_to_room * shape_node.transform, (shape_node.shape as BoxShape3D).size / 2.0)

## The rectangle a box of this half size covers on the floor once transform has put it into the room. A turn
## of 90 degrees is fine: the rectangle stays square to the room.
static func _rect(transform: Transform3D, half: Vector3) -> Rect2:
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for x: float in [-half.x, half.x]:
		for z: float in [-half.z, half.z]:
			var corner := transform * Vector3(x, 0.0, z)
			low = low.min(Vector2(corner.x, corner.z))
			high = high.max(Vector2(corner.x, corner.z))
	return Rect2(low, high - low)

static func _flat(point: Vector3) -> Vector2:
	return Vector2(point.x, point.z)

## A box of this width along the way from one point to another: the way a player walks.
static func corridor(from: Vector2, to: Vector2, width: float) -> PackedVector2Array:
	var side := (to - from).normalized().orthogonal() * width / 2.0
	return PackedVector2Array([from + side, to + side, to - side, from - side])

## True if the rectangle and the polygon share some floor. Touching does not count.
static func overlaps(polygon: PackedVector2Array, rect: Rect2) -> bool:
	if polygon.is_empty():
		return false
	var box := PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])
	return not Geometry2D.intersect_polygons(polygon, box).is_empty()

## How far a point is from a rectangle, 0 inside it.
static func distance_to_rect(point: Vector2, rect: Rect2) -> float:
	var outside := Vector2(maxf(maxf(rect.position.x - point.x, 0.0), point.x - rect.end.x), maxf(maxf(rect.position.y - point.y, 0.0), point.y - rect.end.y))
	return outside.length()

#endregion
