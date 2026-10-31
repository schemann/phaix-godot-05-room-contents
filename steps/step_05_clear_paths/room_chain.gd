extends RefCounted
## The chain as data: one plan per room, made one at a time from a seed.
## It never touches the scene tree, so the same seed always gives the same chain.
## The room at goal_index is the goal room, the end of the run.
## Some rooms are locked. A locked room holds the key to its own door, at one of the room's
## key spots, so a run can always be finished (see _decide_contents).
## Some prop spots of a room hold a prop (see _decide_props): the plan only says which. What a room type
## may hold, and how likely each prop is, is data: the Resources in props/.

enum Type { STRAIGHT, LONG, TURN_LEFT, TURN_RIGHT, WIDE, VAULT, GOAL }

const SCENES: Array[PackedScene] = [
	preload("room_straight.tscn"),
	preload("room_long.tscn"),
	preload("room_turn_left.tscn"),
	preload("room_turn_right.tscn"),
	preload("room_wide.tscn"),
	preload("room_vault.tscn"),
	preload("room_goal.tscn"),
]
const PropSet := preload("prop_set.gd")
const RoomWeights := preload("room_weights.gd")

## How often each room type is tried first. Data: the designer tunes room_weights.tres.
const ROOM_WEIGHTS: RoomWeights = preload("room_weights.tres")

## What each room type may hold, in the order of Type (the goal room has no prop spots). A plan stores the
## index into the scenes of its own room type's set.
const PROP_SETS: Array[PropSet] = [
	preload("props/straight_set.tres"),
	preload("props/long_set.tres"),
	preload("props/turn_left_set.tres"),
	preload("props/turn_right_set.tres"),
	preload("props/wide_set.tres"),
	preload("props/vault_set.tres"),
]
const NO_PROP := -1 ## What a plan says for a prop spot that stays empty.
const START_HEADING := Vector3.FORWARD
const BACK_LIMIT := 0.05 ## How far a heading may lean back (0 = side on, 1 = straight back).
const SHRINK := 0.05 ## Metres. Rooms that only touch are not overlapping.

## What a room type is: its connection points and its box, in the room's own space.
class Module:
	var entrance: Transform3D
	var exit: Transform3D
	var bounds: AABB
	var key_spots: Array[Vector3] ## Where this room type can hold a key, in the room's own space.
	var prop_spots: Array[Transform3D] ## Where it can hold props, in the room's own space. -Z is the way a prop faces.

## One room of the chain.
class Plan:
	var index: int
	var type: int
	var transform: Transform3D
	var bounds: AABB ## In world space.
	var locked := false ## The exit door needs a key.
	var key_spot := -1 ## Which of the room's key spots holds the key. -1: no key in this room.
	var props: Array[int] = [] ## One entry per prop spot of the room: the index of a prop, or NO_PROP.

	func _init(plan_index: int, plan_type: int, plan_transform: Transform3D, plan_bounds: AABB) -> void:
		index = plan_index
		type = plan_type
		transform = plan_transform
		bounds = plan_bounds

var plans: Array[Plan] = [] ## Every room made so far, also the ones long removed.
var goal_index: int ## The plan that becomes the goal room. It moves on by one for every room the goal had to wait.

var lock_chance: float ## The chance for a room to be locked, 0 to 1.

var _rng := RandomNumberGenerator.new() ## Decides the rooms. Only room choices ever draw from it.
var _content_rng := RandomNumberGenerator.new() ## Decides what is in them. A second stream: contents never move a room.
var _last_vault := -1 ## The index of the last vault made, or -1 if there was none yet.
var _prop_rng := RandomNumberGenerator.new() ## Decides the props. A third stream, started again for every room.
var _chain_seed: int
var _modules: Array[Module] = []

func _init(chain_seed: int, goal_room: int, chance := 0.0) -> void:
	_chain_seed = chain_seed
	_rng.seed = chain_seed
	_content_rng.seed = hash([chain_seed, "content"])
	goal_index = goal_room
	lock_chance = chance
	for scene in SCENES:
		_modules.append(_read_module(scene))

## Makes the next room. Call it in order: the plan list is the history.
func next_plan() -> Plan:
	if plans.is_empty():
		return _add(Type.STRAIGHT, Transform3D.IDENTITY)

	var last := plans[-1]
	var exit_point := last.transform * _modules[last.type].exit

	# The goal room is a dead end, so it only has to fit: no heading to test.
	if plans.size() == goal_index:
		var goal := _modules[Type.GOAL]
		var goal_placed := exit_point * goal.entrance.affine_inverse()
		if not _hits_history(goal_placed * goal.bounds):
			return _add(Type.GOAL, goal_placed)
		goal_index += 1 # no room for it here: an ordinary room now, the goal after that

	for type: int in _weighted_types():
		var module := _modules[type]
		# Snap: the new room's entrance lands on the last room's exit.
		var placed := exit_point * module.entrance.affine_inverse()
		if _turns_back(placed, module.exit):
			continue # no U-turns
		if _hits_history(placed * module.bounds):
			continue # the room would run into an earlier one
		return _add(type, placed)

	push_error("room chain: no room type fits after room %d" % last.index)
	return _add(Type.STRAIGHT, exit_point * _modules[Type.STRAIGHT].entrance.affine_inverse())

## How many key spots a room type has. A plan's key_spot has to be below this (see check_solvable.gd).
func key_spot_count(type: int) -> int:
	return _modules[type].key_spots.size()

## Takes the prop spots away from every room type: the chain then plans the same rooms and locks without a
## single prop. The contents check builds this twin to prove that props change nothing else.
func clear_prop_spots() -> void:
	for module in _modules:
		module.prop_spots.clear()

## The scene a prop index of a plan stands for: it counts in the set of the plan's room type.
func prop_scene(type: int, prop: int) -> PackedScene:
	return PROP_SETS[type].scenes[prop]

## A weighted choice in three steps: add the weights up (sum), take a random number up to that sum (value), walk along
## the weights until the value is used up (walk). value is 0 up to 1. A bigger weight is a bigger slice of the range.
static func weighted_pick(weights: Array[float], value: float) -> int:
	var total := 0.0
	for weight in weights:
		total += weight
	var target := value * total
	for i in weights.size():
		target -= weights[i]
		if target < 0.0:
			return i
	return weights.size() - 1 # only reached by rounding: the last slice

## True while the next room, plans.size(), would be closer to the last vault than the weights allow.
func _vault_too_soon() -> bool:
	return _last_vault >= 0 and plans.size() - _last_vault < ROOM_WEIGHTS.min_gap

## True if the room's exit would send the chain back: against the start heading, or towards the start room.
func _turns_back(placed: Transform3D, exit_local: Transform3D) -> bool:
	var heading := -(placed * exit_local).basis.z
	var to_start := (plans[0].transform.origin - placed.origin).normalized()
	return heading.dot(START_HEADING) < -BACK_LIMIT or heading.dot(to_start) > BACK_LIMIT

func _add(type: int, placed: Transform3D) -> Plan:
	var plan := Plan.new(plans.size(), type, placed, placed * _modules[type].bounds)
	if type == Type.VAULT:
		_last_vault = plan.index
	_decide_contents(plan)
	_decide_props(plan)
	plans.append(plan)
	return plan

## Locks and keys. The random numbers come from _content_rng, never from _rng, so the rooms of a seed are the
## same with or without locks. Both numbers are drawn for every room with key spots, locked or not,
## so a room gets the same numbers whatever happens to the rooms around it.
func _decide_contents(plan: Plan) -> void:
	var spot_count := _modules[plan.type].key_spots.size()
	if spot_count == 0:
		return # the goal room has no door and nothing to lock
	var value := _content_rng.randf()
	var spot := _content_rng.randi_range(0, spot_count - 1)
	# Never locked: room 0, because the run starts with a door that simply opens, and the room before
	# the goal, so the last stretch is a clean sprint to the pad. (The goal room has no door.)
	var always_open := plan.index == 0 or plan.index == goal_index - 1
	if value < lock_chance and not always_open:
		plan.locked = true
		plan.key_spot = spot # the key lies in the same room as its lock

## Props. Their own generator, started again for every room from the seed and the room's index, so a room's
## props depend on nothing else: no lock, no goal room, no other room moves them, and they move none of
## those. One random number for every spot: the room type's set says what it may be.
func _decide_props(plan: Plan) -> void:
	var spot_count := _modules[plan.type].prop_spots.size()
	if spot_count == 0:
		return # the goal room has no prop spots
	var prop_set := PROP_SETS[plan.type]
	var weights: Array[float] = prop_set.weights.duplicate()
	weights.append(prop_set.empty_weight) # the last slice of the range is "nothing"
	_prop_rng.seed = hash([_chain_seed, "props", plan.index])
	for i in spot_count:
		var pick := weighted_pick(weights, _prop_rng.randf())
		plan.props.append(pick if pick < prop_set.scenes.size() else NO_PROP)

func _hits_history(box: AABB) -> bool:
	var inner := box.grow(-SHRINK)
	for plan in plans:
		if inner.intersects(plan.bounds):
			return true
	return false

## The room types in the order the chain tries them: drawn one at a time by weight, and a type that is
## drawn is not drawn again (a weighted order without replacement). Our own generator, as always:
## Array.shuffle() would use the global one. The goal room is never drawn: it is only placed at goal_index.
## A rare room is not even a candidate while the gap to the last one is too small.
func _weighted_types() -> Array[int]:
	var left: Array[int] = []
	for type in range(Type.GOAL):
		if type == Type.VAULT and _vault_too_soon():
			continue
		left.append(type)
	var order: Array[int] = []
	while not left.is_empty():
		var weights: Array[float] = []
		for type in left:
			weights.append(ROOM_WEIGHTS.weight_of(type))
		order.append(left.pop_at(weighted_pick(weights, _rng.randf())))
	return order

## Instancing a scene outside the tree is enough to read its markers and its box.
func _read_module(scene: PackedScene) -> Module:
	var room := scene.instantiate()
	var module := Module.new()
	module.entrance = (room.get_node("Entrance") as Marker3D).transform
	var exit_marker := room.get_node_or_null("Exit") as Marker3D # the goal room has none
	if exit_marker != null:
		module.exit = exit_marker.transform
	var spots := room.get_node_or_null("KeySpots") # the goal room has none
	if spots != null:
		for spot in spots.get_children():
			module.key_spots.append((spot as Marker3D).position)
	var decor := room.get_node_or_null("PropSpots") # nor has it prop spots
	if decor != null:
		for spot in decor.get_children():
			module.prop_spots.append((spot as Marker3D).transform)
	var shape := room.get_node("Inside/CollisionShape3D") as CollisionShape3D
	var box_size := (shape.shape as BoxShape3D).size
	module.bounds = shape.transform * AABB(-box_size / 2.0, box_size)
	room.free()
	return module
