extends SceneTree
## Walks the autopilot through the finished game (step 5) for a range of seeds and writes one line per seed to a file:
##   ok <seed> <ticks>                       the player stood on the goal pad
##   held <seed> <room> <local position> <ticks>   the player stopped moving, or the run took too long
## and "done" as the last line. The test suite starts several of these side by side (tests/run_tests.gd).
##   godot --headless --path godot/05-room-contents -s res://tools/sweep_seeds.gd -- --from=1 --to=50 --out=/tmp/sweep.txt
## The ticks are the same 1/60 s ones at any speed, so a seed walks the same way fast or slow. The speed is the engine's own
## limit of 8 physics steps per frame: faster than that Jolt warns about running out of jobs.

const Autopilot := preload("res://tools/autopilot.gd")
const FINAL_SCENE := "res://steps/step_05_clear_paths/main.tscn"
const SPEED_UP := 8 ## Times real time.
const STATE_FINISHED := 2 ## Level.State.FINISHED
const STALL_TICKS := 120 ## A run that has not moved for this many ticks (2 s) is held in place.
const STALL_DISTANCE := 0.0005 ## Metres a tick has to move the player to count as moving.
const BUDGET := 60 * 60 * 3 ## Ticks a run may take (3 minutes of game time; a run takes about one).

## Calls its callback once per physics tick, before the player's own tick.
class Driver extends Node:
	signal finished
	var tick: Callable

	func _physics_process(_delta: float) -> void:
		if tick.is_valid() and tick.call():
			tick = Callable()
			finished.emit()

func _initialize() -> void:
	await process_frame
	var first := 1
	var last := 1
	var out_path := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--from="):
			first = int(argument.trim_prefix("--from="))
		elif argument.begins_with("--to="):
			last = int(argument.trim_prefix("--to="))
		elif argument.begins_with("--out="):
			out_path = argument.trim_prefix("--out=")
	var out := FileAccess.open(out_path, FileAccess.WRITE)
	if out == null:
		printerr("sweep_seeds: cannot write ", out_path)
		quit(1)
		return
	Engine.physics_ticks_per_second = 60 * SPEED_UP
	Engine.time_scale = float(SPEED_UP)
	for chain_seed in range(first, last + 1):
		out.store_line(await _walk(chain_seed))
		out.flush()
	out.store_line("done")
	out.close()
	quit(0)

## One seed from the first door to the goal pad. Returns the line for the result file.
func _walk(chain_seed: int) -> String:
	var save_path := OS.get_temp_dir().path_join("phaix-godot-05-sweep-%d.json" % chain_seed)
	var main := (load(FINAL_SCENE) as PackedScene).instantiate()
	var level: Node3D = main.get_node("Level")
	level.set("save_path", save_path)
	level.set("chain_seed", chain_seed)
	root.add_child(main)
	for i in 10:
		await physics_frame # the CSG shapes build their collision
	var pilot := Autopilot.new(level)
	var run := {"ticks": 0, "still": 0, "last": level.player.global_position}
	var driver := Driver.new()
	driver.process_priority = -100
	driver.tick = func() -> bool:
		pilot.physics_step()
		run["ticks"] += 1
		var at: Vector3 = level.player.global_position
		run["still"] = run["still"] + 1 if at.distance_to(run["last"]) < STALL_DISTANCE else 0
		run["last"] = at
		return level.state == STATE_FINISHED or run["still"] >= STALL_TICKS or run["ticks"] >= BUDGET
	root.add_child(driver)
	await driver.finished
	pilot.release()
	var line := "ok %d %d" % [chain_seed, run["ticks"]]
	if level.state != STATE_FINISHED:
		var room: Node3D = level.rooms[level.current]
		var local: Vector3 = room.global_transform.affine_inverse() * level.player.global_position
		line = "held %d %d %s %d" % [chain_seed, level.current, local, run["ticks"]]
	root.remove_child(driver)
	driver.queue_free()
	root.remove_child(main)
	main.free()
	for path: String in [save_path, save_path + ".tmp"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	await process_frame
	return line
