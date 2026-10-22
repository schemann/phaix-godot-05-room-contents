extends Area3D
## A key lying in a room. The player walks into it and it is gone: the key only says "I was
## picked up", the level counts it. The spinning and bobbing is for the eye only: the Area3D
## never moves, so what the player can reach is always the same.

signal picked_up ## The player touched the key. Sent once, then the key frees itself.

const SPIN_SPEED := 1.6 ## Radians per second.
const BOB_HEIGHT := 0.08 ## Metres up and down.
const BOB_SPEED := 2.0 ## Radians per second of the sine wave.

var _age := 0.0 ## Seconds since the key appeared, added up from the frame delta.
var _sleep_steps := 2 ## Counts down before each physics step. At 0 the reach wakes up.

@onready var model: Node3D = $Model
@onready var _hover_height := model.position.y

func _ready() -> void:
	body_entered.connect(_on_body_entered)

func _process(delta: float) -> void:
	_age += delta
	model.rotation.y = _age * SPIN_SPEED
	model.position.y = _hover_height + sin(_age * BOB_SPEED) * BOB_HEIGHT

func _physics_process(_delta: float) -> void:
	# The reach sleeps (monitoring is off in the scene) through the first physics step, like the door's
	# trigger: a player the level has just placed is still at the old place in that step. The count is 2
	# because it runs before each step. Without this a restart pressed on the spot of a key would pick up
	# the key of the new run.
	if _sleep_steps > 0:
		_sleep_steps -= 1
		if _sleep_steps == 0:
			monitoring = true

func _on_body_entered(_body: Node3D) -> void:
	picked_up.emit()
	queue_free()
