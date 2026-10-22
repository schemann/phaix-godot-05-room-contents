extends RefCounted
## Walks the real player from door to door through the input actions only (look_*
## and move_forward), like a person with a gamepad. Never teleports and never sets
## a transform. Used by the tests and by tools/capture.gd with the levels of the steps.
## In the goal room, which has no door, it walks onto the goal pad.
## Tutorial 04's, unchanged for tutorial 05: in a room whose door is locked it first walks to the key (a child of the room,
## named Key) and picks it up by walking into it, then goes to the door.
## Call physics_step() once per physics frame.

const TURN_IN_PLACE := 0.35 ## Radians. Stand still and turn while the target is further off than this.
const PASSED_DEPTH := 1.0 ## Metres behind the door plane before the next door becomes the target.
const THROUGH_DEPTH := 1.2 ## Metres in front of the door plane: from here on walk straight through.
const STICK_GAIN := 1.6 ## Stick strength per radian of error, on top of the 0.2 dead zone.
const PAD_REACHED := 0.3 ## Metres from the middle of the pad: stop walking.

var fetch_keys := true ## Fetch the key of a locked room before going to its door. Off: walk straight at the door and get refused.
var fetch_every_key := false ## Also fetch a key whose door is not locked (step 1, where the key has no use yet).

var door_index := 0 ## The room whose exit door is the current target.
var _level: Node3D

func _init(level: Node3D) -> void:
	_level = level

func physics_step() -> void:
	var player: CharacterBody3D = _level.player
	var room: Node3D = _level.rooms.get(door_index)
	if room == null:
		release()
		return

	var exit_marker := room.get("exit") as Marker3D
	if exit_marker == null:
		_walk_to_pad(player, room.get_node("GoalPad") as Node3D)
		return

	var key := _key_to_fetch(room)
	if key != null:
		_walk_to_key(player, key)
		return

	var door_point := exit_marker.global_transform
	var forward := -door_point.basis.z
	var depth := (player.global_position - door_point.origin).dot(forward) ## Negative in front of the door.
	if depth > PASSED_DEPTH:
		door_index += 1
		return

	# First aim at the middle of the doorway, close to it straight through.
	var aim := door_point.origin if depth < -THROUGH_DEPTH else door_point.origin + forward * 3.0
	var direction := aim - player.global_position
	var error := wrapf(atan2(-direction.x, -direction.z) - player.rotation.y, -PI, PI)
	_steer(error)
	if absf(error) < TURN_IN_PLACE:
		Input.action_press("move_forward")
	else:
		Input.action_release("move_forward")

## How far the player is in front of the door of room index; negative before it.
## The goal room has no door: the player never gets past it (-INF).
func depth_at(index: int) -> float:
	var room: Node3D = _level.rooms.get(index)
	if room == null:
		return INF
	if room.get("exit") == null:
		return -INF
	var door_point: Transform3D = (room.get("exit") as Marker3D).global_transform
	var player: CharacterBody3D = _level.player
	return (player.global_position - door_point.origin).dot(-door_point.basis.z)

## The key the player has to fetch before this room's door can be passed, or null: the door is
## locked and shut, the player holds no key and the room still has one.
func _key_to_fetch(room: Node3D) -> Node3D:
	if not fetch_keys or _level.get("keys") != 0:
		return null
	var door: Node3D = room.get("door")
	if door == null or door.get("is_open") == true or (door.get("locked") != true and not fetch_every_key):
		return null
	var key := room.get_node_or_null("Key") as Node3D
	return key if key != null and not key.is_queued_for_deletion() else null

## Look at the key and walk until the key is gone (picked up).
func _walk_to_key(player: CharacterBody3D, key: Node3D) -> void:
	var direction := key.global_position - player.global_position
	var error := wrapf(atan2(-direction.x, -direction.z) - player.rotation.y, -PI, PI)
	_steer(error)
	if absf(error) < TURN_IN_PLACE:
		Input.action_press("move_forward")
	else:
		Input.action_release("move_forward")

## The goal room: look at the middle of the pad and walk until the player stands on it.
func _walk_to_pad(player: CharacterBody3D, pad: Node3D) -> void:
	var direction := pad.global_position - player.global_position
	var error := wrapf(atan2(-direction.x, -direction.z) - player.rotation.y, -PI, PI)
	_steer(error)
	if absf(error) < TURN_IN_PLACE and Vector2(direction.x, direction.z).length() > PAD_REACHED:
		Input.action_press("move_forward")
	else:
		Input.action_release("move_forward")

func release() -> void:
	for action: String in ["move_forward", "look_left", "look_right"]:
		Input.action_release(action)

## Positive error: the target is to the left, so the stick goes left (yaw grows).
func _steer(error: float) -> void:
	Input.action_release("look_left")
	Input.action_release("look_right")
	if absf(error) < 0.01:
		return
	var strength := clampf(0.2 + absf(error) * STICK_GAIN, 0.0, 1.0)
	Input.action_press("look_left" if error > 0.0 else "look_right", strength)
