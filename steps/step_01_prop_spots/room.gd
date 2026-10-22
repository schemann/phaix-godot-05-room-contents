extends Node3D
## A room module: a CSG shell with two connection points and a door at the exit.
## The goal room has no exit, so it gets no door.

const Door := preload("door.gd")
const DoorScene := preload("door.tscn")

var door: Door ## Null in the goal room.
var key_spots: Array[Marker3D] = [] ## Where this room can hold its key. Empty in the goal room.
var prop_spots: Array[Marker3D] = [] ## Where this room can hold props, facing into the room. Empty in the goal room.

@onready var entrance: Marker3D = $Entrance
@onready var exit: Marker3D = get_node_or_null("Exit") as Marker3D ## Null in the goal room.
@onready var inside: Area3D = $Inside
@onready var goal_pad: Area3D = get_node_or_null("GoalPad") as Area3D ## Null in every room but the goal room.

func _ready() -> void:
	var spots := get_node_or_null("KeySpots")
	if spots != null:
		for spot in spots.get_children():
			key_spots.append(spot as Marker3D)
	var decor := get_node_or_null("PropSpots")
	if decor != null:
		for spot in decor.get_children():
			prop_spots.append(spot as Marker3D)
	if exit == null:
		return
	door = DoorScene.instantiate() as Door
	door.transform = exit.transform
	add_child(door)

## Room 0 has nothing behind it, so its entrance becomes a plain wall.
## A hidden cutter is ignored by the CSG shape, which closes the hole.
func seal_entrance() -> void:
	$Shell/WallEntrance/Opening.visible = false
