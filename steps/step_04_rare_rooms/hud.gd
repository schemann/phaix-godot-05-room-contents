extends CanvasLayer
## The on-screen display. It listens to the level's signals and never touches the game.

const BestTimes := preload("best_times.gd")
const Level := preload("level.gd")

@export var level: Level

@onready var room_label: Label = $Stats/RoomLabel
@onready var keys_label: Label = $Stats/KeysLabel
@onready var message_label: Label = $MessageLabel
@onready var message_timer: Timer = $MessageTimer
@onready var time_label: Label = $Stats/TimeLabel
@onready var best_label: Label = $Stats/BestLabel
@onready var finish_panel: PanelContainer = $FinishPanel
@onready var finish_time: Label = $FinishPanel/Rows/FinishTime
@onready var new_best_label: Label = $FinishPanel/Rows/NewBest

func _ready() -> void:
	level.room_entered.connect(_on_room_entered)
	level.state_changed.connect(_on_state_changed)
	level.keys_changed.connect(_on_keys_changed)
	level.door_blocked.connect(_on_door_blocked)
	message_timer.timeout.connect(message_label.hide)
	_on_room_entered(level.current) # the level started before the HUD was ready
	_on_state_changed(level.state)
	_on_keys_changed(level.keys)

func _process(_delta: float) -> void:
	time_label.text = format_time(level.run_time)

## 42.37 -> "0:42.3". The tenths are cut, not rounded: the display never runs ahead of the clock.
## Milliseconds first, because a float like 39.8 is really 39.79999.
static func format_time(seconds: float) -> String:
	var tenths := floori(roundi(seconds * 1000.0) / 100.0)
	var minutes := floori(tenths / 600.0)
	return "%d:%04.1f" % [minutes, (tenths - minutes * 600) / 10.0]

func _on_room_entered(index: int) -> void:
	room_label.text = "Room %d / %d" % [index, level.chain.goal_index]

func _on_keys_changed(count: int) -> void:
	keys_label.text = "Keys %d" % count

## "Locked: find the key" for the time of the timer (1.5 s). A second knock starts the time again.
func _on_door_blocked() -> void:
	message_label.show()
	message_timer.start()

func _on_state_changed(state: Level.State) -> void:
	message_label.hide() # a new run or the finish: no message from the run before
	var best := level.best_times.best(level.chain_seed)
	best_label.text = "Best " + (format_time(best) if best != BestTimes.NO_TIME else "-:--.-")
	finish_time.text = format_time(level.run_time)
	new_best_label.visible = level.new_best
	finish_panel.visible = state == Level.State.FINISHED
