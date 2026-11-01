extends Node3D
## A hinged door. It swings away from the player who walks up to it.
## A locked door only asks: it never knows what a key is, the level answers.

signal opened ## Emitted as the door starts to swing open.
signal closed ## Emitted when the door has swung shut. Opened again on the way, it never comes.
signal unlock_requested ## Somebody walked up to a locked door. Whoever listens may answer with unlock().

const OPEN_ANGLE := -PI / 2.0 ## Away from the player, into the next room.
const SWING_TIME := 0.5 ## Seconds.
const RATTLE_ANGLE := deg_to_rad(-4.0) ## How far a locked door gives under a push: away from the player, never towards.
const RATTLE_STRENGTHS: Array[float] = [1.0, 0.65, 0.35] ## One push each, the next one weaker.
const RATTLE_OUT_TIME := 0.04 ## Seconds to give way ...
const RATTLE_BACK_TIME := 0.05 ## ... and to snap back.
const FLASH_ENERGY := 5.0 ## Emission of the lock at the first instant of the flash.
const FLASH_TIME := 0.4 ## Seconds for the flash to fade.
const DROP_DISTANCE := 0.6 ## Metres the lock falls when the door is unlocked.
const DROP_TIME := 0.3 ## Seconds.

@export var locked := false ## A locked door does not open on approach. See lock() and unlock().

var is_open := false

var _tween: Tween
var _sleep_steps := 2 ## Counts down before each physics step. At 0 the trigger wakes up.
var _close_pending := false
var _lock_tween: Tween
var _flash_tween: Tween
var _flash_material: StandardMaterial3D ## A private copy of the lock material, made on the first flash.

@onready var hinge: AnimatableBody3D = $Hinge
@onready var trigger: Area3D = $Trigger
@onready var swing: Area3D = $Swing ## Where the door sweeps through when it moves.
@onready var lock_block: Node3D = $Hinge/Lock ## The plate and the bar on the panel. Shown while the door is locked.
@onready var lock_meshes: Array[MeshInstance3D] = [$Hinge/Lock/Bar, $Hinge/Lock/Plate]
@onready var _lock_rest_y := lock_block.position.y ## Where the lock sits on the panel.

func _ready() -> void:
	lock_block.visible = locked
	trigger.body_entered.connect(_on_trigger_body_entered)

func _physics_process(_delta: float) -> void:
	# The trigger sleeps (monitoring is off in the scene) through the first physics step: Jolt moves a
	# player the level has just teleported during that step, so it still finds the player at the old
	# place. The count is 2 because it runs before each step: the trigger wakes up before the second.
	if _sleep_steps > 0:
		_sleep_steps -= 1
		if _sleep_steps == 0:
			trigger.monitoring = true
	# Never close on somebody: wait until nobody stands in the swing.
	if _close_pending and not swing.has_overlapping_bodies():
		_close_pending = false
		is_open = false
		_swing_to(0.0)
		_tween.tween_callback(closed.emit)

func open() -> void:
	_close_pending = false
	if is_open:
		return
	is_open = true
	_swing_to(OPEN_ANGLE)
	opened.emit()

func lock() -> void:
	locked = true
	if _lock_tween != null:
		_lock_tween.kill()
	lock_block.visible = true
	lock_block.position.y = _lock_rest_y
	for mesh in lock_meshes:
		mesh.transparency = 0.0

## The lock drops off the door and fades out. The door is unlocked at once, the show is for the eye.
func unlock() -> void:
	locked = false
	if _lock_tween != null:
		_lock_tween.kill()
	_lock_tween = create_tween().set_parallel() # idle time: it moves a picture, not a collider
	_lock_tween.tween_property(lock_block, "position:y", lock_block.position.y - DROP_DISTANCE, DROP_TIME).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	for mesh in lock_meshes:
		_lock_tween.tween_property(mesh, "transparency", 1.0, DROP_TIME)
	_lock_tween.chain().tween_callback(func() -> void: lock_block.visible = false)

## A locked door gives a little under a push and snaps back, and the lock lights up. The level calls
## it the moment a player without a key walks up. The hinge is a collider: its tween runs in physics time.
func rattle() -> void:
	if _tween != null:
		_tween.kill()
	_tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	for strength in RATTLE_STRENGTHS:
		_tween.tween_property(hinge, "rotation:y", RATTLE_ANGLE * strength, RATTLE_OUT_TIME)
		_tween.tween_property(hinge, "rotation:y", 0.0, RATTLE_BACK_TIME)
	_flash_lock()

## The lock material is shared by every door, so the flash goes through a private copy of it.
func _flash_lock() -> void:
	var shared := (lock_meshes[0].mesh as PrimitiveMesh).material as StandardMaterial3D
	if _flash_material == null:
		_flash_material = shared.duplicate() as StandardMaterial3D
	_flash_material.emission_energy_multiplier = FLASH_ENERGY
	for mesh in lock_meshes:
		mesh.material_override = _flash_material
	if _flash_tween != null:
		_flash_tween.kill()
	_flash_tween = create_tween()
	_flash_tween.tween_property(_flash_material, "emission_energy_multiplier", shared.emission_energy_multiplier, FLASH_TIME)
	_flash_tween.tween_callback(func() -> void:
		for mesh in lock_meshes:
			mesh.material_override = null)

## Closes as soon as the swing is free.
func close() -> void:
	_close_pending = true

func _swing_to(angle: float) -> void:
	if _tween != null:
		_tween.kill()
	# Physics process mode: the door's collider moves in step with the physics.
	_tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_tween.tween_property(hinge, "rotation:y", angle, SWING_TIME).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

## A locked door asks first. If it is unlocked by the time the question is answered, it opens.
func _on_trigger_body_entered(_body: Node3D) -> void:
	if locked:
		unlock_requested.emit()
	if not locked:
		open()
