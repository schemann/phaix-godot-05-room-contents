extends SceneTree
## Headless tests for tutorial 05. From the repository root:
##   godot --headless --path godot/05-room-contents -s res://tests/run_tests.gd
## Prints PASS or FAIL per test and exits with 0 only if every test passed.
## `-- --only=text` runs the tests whose name contains the text (for example `-- --only=vault`).
##
## Saves: every level the tests load gets its own temporary save file (OS temp dir, wiped
## first), so a test run never reads or writes the real best_times.json. A few tests damage a file or write to a missing folder on
## purpose: the game logs a WARNING line for each of those, that is expected.

const Chain00 := preload("res://steps/step_00_start/room_chain.gd") ## Tutorial 04's chain: locks and keys, no props, the rooms in shuffled order.
const Chain := preload("res://steps/step_05_clear_paths/room_chain.gd") ## The finished chain (step 5: step 4's plus clear_prop_spots()).
const Solvable := preload("res://steps/step_05_clear_paths/check_solvable.gd")
const Contents := preload("res://steps/step_05_clear_paths/check_contents.gd")
const Autopilot := preload("res://tools/autopilot.gd")
const BestTimes := preload("res://steps/step_05_clear_paths/best_times.gd")

const STEPS: Array[String] = [
	"step_00_start",
	"step_01_prop_spots",
	"step_02_prop_sets",
	"step_03_weighted_rooms",
	"step_04_rare_rooms",
	"step_05_clear_paths",
]
const FINAL_STEP := "step_05_clear_paths"
const ROOM_TYPES: Array[String] = ["straight", "long", "turn_left", "turn_right", "wide"] ## The ordinary rooms, from step 0 on. Step 4 adds the vault.
const PROP_NAMES: Array[String] = ["crate", "stack", "table", "shelf", "pillar"]

## What each step changes against the one before (file names under the step folder, props/ included; .uid files do not count).
const CHANGES: Dictionary[String, Dictionary] = {
	"step_01_prop_spots": {
		changed = ["level.gd", "room.gd", "room_chain.gd", "room_long.tscn", "room_straight.tscn", "room_turn_left.tscn", "room_turn_right.tscn", "room_wide.tscn"],
		added = ["props/crate.tscn", "props/pillar.tscn", "props/shelf.tscn", "props/stack.tscn", "props/table.tscn"],
	},
	"step_02_prop_sets": {
		changed = ["room_chain.gd"],
		added = ["prop_set.gd", "props/long_set.tres", "props/straight_set.tres", "props/turn_left_set.tres", "props/turn_right_set.tres", "props/wide_set.tres"],
	},
	"step_03_weighted_rooms": {changed = ["room_chain.gd"], added = ["room_weights.gd", "room_weights.tres"]},
	"step_04_rare_rooms": {changed = ["room_chain.gd", "room_weights.gd", "room_weights.tres"], added = ["props/vault_set.tres", "room_vault.tscn"]},
	"step_05_clear_paths": {changed = ["room_chain.gd"], added = ["check_contents.gd"]},
}

const STATE_READY := 0 ## Level.State, checked by test_state_enum.
const STATE_RUNNING := 1
const STATE_FINISHED := 2

const RAY_HEIGHT := 1.2 ## Metres above the floor: through the middle of a doorway.
const CEILING_LAYER := 2 ## VisualInstance3D.layers of the ceilings and lamp blocks: layer 2 only.
const ALL_LAYERS := 1048575 ## Camera3D.cull_mask default: all 20 layers.
const WALL_THICKNESS := 0.2 ## Studio graybox standard: interior wall 0.1-0.25 x 3.0 m.
const WALL_HEIGHT := 3.0
const SLAB_THICKNESS := 0.2 ## Floor and ceiling.
const DOORWAY_WIDTH := 1.6
const DOORWAY_HEIGHT := 2.4
const MATERIAL_DIR := "res://materials/"
const SEED_COUNT := 1000
const ROOMS_PER_SEED := 300
const GOAL_SEEDS := 500 ## Seeds 1..500 for the goal room placement.
const MAX_EXTRA_ROOMS := 3 ## The goal may wait at most this many rooms for a free place.
const STREAM_ROOMS := 10 ## How many rooms the streaming test walks through.
const SPEED_UP := 4 ## The walking tests run this many times faster than real time.
const SWEEP_SEEDS := 200 ## Seeds 1..200 of the finished game for the autopilot sweep.
const SWEEP_WORKERS := 5 ## Processes the sweep is split over (tools/sweep_seeds.gd, 8 times real time each).
const SHORT_GOAL := 3 ## Goal room of the quick runs.
const LOCK_CHANCE := 0.4 ## The level's default.
const CONTENT_SEEDS := 200 ## Seeds 1..200 for the comparisons that build two chains per seed.
const PROP_SEEDS := 500
const VAULT_PLATFORM_HEIGHT := 0.12 ## The raised middle of the vault: a step the capsule climbs, like the goal pad. ## Seeds 1..500 for the prop rules.
const SEED_42_LOCKS: Array[int] = [3, 4, 12] ## Rooms the default settings lock in seed 42 (goal room 20, lock chance 0.4): the same in every step.
const SEED_42_VAULTS: Array[int] = [2] ## The vaults of seed 42 in steps 4 and 5.

## Counts the script errors the engine logs. A test that hits one stops at that line and the engine hands back an
## empty array, which reads as a pass: `_report` charges the count to the test that ran.
class ScriptErrorCounter extends Logger:
	var count := 0
	var _lock := Mutex.new() ## The engine calls a logger from any thread.

	func _log_error(_function: String, _file: String, _line: int, _code: String, _rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != ERROR_TYPE_SCRIPT:
			return
		_lock.lock()
		count += 1
		_lock.unlock()

var _passed := 0
var _failed := 0
var _skipped := 0
var _script_errors := ScriptErrorCounter.new() ## Registered with the engine's logger for the whole run.
var _script_errors_reported := 0 ## How many script errors the tests reported so far have been charged with.
var _save_dir := ""
var _save_counter := 0

func _initialize() -> void:
	OS.add_logger(_script_errors)
	await process_frame
	var started := Time.get_ticks_msec()
	_save_dir = OS.get_temp_dir().path_join("phaix-godot-05-tests")
	_wipe_save_dir()

	await _run("code rules: no class_name, no global random, no wall clock, input only through named actions", test_code_rules)
	await _run("code rules: the HUD only reads the level", test_hud_reads_only)
	await _run("code rules: the door never knows what a key is, the key never knows the level, locks, props and rooms have their own generators", test_key_rules)
	await _run("code rules: props and room weights are data (Resource scripts with exports, .tres files), the code only rolls and walks", test_data_rules)
	await _run("steps: each step changes only what its concept needs, everything else is copied forward", test_copy_forward)
	await _run("step_00_start: tutorial 04's final state, file for file (only the folder names differ)", test_step_zero_is_tutorial_04)
	for step in STEPS:
		await _run("%s chain: same seed gives the same plans 0-99, another seed another ones" % step, test_determinism.bind(_chain_script(step)))
	await _run("chain: seeds 1-%d x %d rooms, no overlap, no fallback, never backwards (finished chain, vault and weights)" % [SEED_COUNT, ROOMS_PER_SEED], test_no_overlap.bind(Chain, SEED_COUNT))
	await _run("chain (tutorial 04's): seeds 1-300 x %d rooms, no overlap, no fallback, never backwards" % ROOMS_PER_SEED, test_no_overlap.bind(Chain00, 300))
	await _run("chain (step 3, weighted rooms without the vault): seeds 1-300 x %d rooms, no overlap, never backwards" % ROOMS_PER_SEED, test_no_overlap.bind(_chain_script("step_03_weighted_rooms"), 300))
	for chain_script: GDScript in [Chain00, Chain]:
		var which := "tutorial 04's chain" if chain_script == Chain00 else "finished chain"
		await _run("goal (%s): plan %d is the goal room, once, last, no overlap, no U-turn, seeds 1-%d" % [which, 20, GOAL_SEEDS], test_goal_placement.bind(chain_script))
		await _run("goal (%s): other goal rooms (1, 2, 7, 50, 120), 100 seeds each" % which, test_goal_other_indices.bind(chain_script))
		await _run("goal (%s): a goal that does not fit waits for the next room, and the plans stay valid" % which, test_goal_waits.bind(chain_script))
	await _run("contents: locks never move a room, in every step (seeds 1-%d)" % CONTENT_SEEDS, test_locks_keep_rooms)
	await _run("contents: more lock chance only adds locks, the key spots stay; the goal room moves no roll (seeds 1-%d)" % CONTENT_SEEDS, test_contents_second_stream)
	await _run("contents: room 0, the room before the goal and the goal room are never locked, a lock has a key in the same room (tutorial 04's chain and the finished one)", test_contents_rules)
	await _run("contents: seed 42 locks rooms %s with the default settings in every step, the lock rate is the chance" % [SEED_42_LOCKS], test_contents_statistics)
	await _run("solvable: seeds 1-%d, every lock has its key in its own room, the player never gets stuck (finished chain)" % SEED_COUNT, test_solvable_seeds)
	await _run("solvable: the check finds each kind of broken generator", test_solvable_finds_faults)
	await _run("solvable: check_solvable.gd runs from the command line and exits 0", test_solvable_command)
	await _run("materials: shared graybox materials, 1 m grid, orange door, gold goal and key, red-orange lock, darker gray props, emissive fixture, no private materials", test_materials)
	for step in STEPS:
		for room_type in _room_types_of(step):
			await _run("%s room_%s: entrance, exit, doorway size, bounds" % [step, room_type], test_room_module.bind(room_type, step))
	await _run("room_vault: 14 x 14 hall, entrance and exit opposite, four pillars, a raised platform of 0.12 m in the middle, three key spots, six prop spots", test_vault_room)
	for step in STEPS:
		await _run("%s room_goal: entrance only, 10 x 14, raised pad 3 x 3 in gold, its own light and fixture, trigger on the player layer" % step, test_goal_room.bind(step))
	for step in STEPS:
		await _run("%s: every room is closed (0.2 m floor, walls and ceiling), lamp and fixture, shared materials" % step, test_graybox_rooms.bind(step))
		await _run("%s: ambient fill reads inside closed rooms, the sun casts shadows" % step, test_lighting.bind(step))
		await _run("%s: every Entrance is on the previous Exit" % step, test_snapping.bind(step))
	for step in STEPS:
		await _run("%s: walks on the floor, relative to its facing" % step, test_walk.bind(step))
		await _run("%s: jumps about 1 m, stays below the ceiling and lands" % step, test_jump.bind(step))
		await _run("%s: the player's camera sees the ceiling" % step, test_player_camera.bind(step))
		await _run("%s: the sealed entrance of room 0 holds" % step, test_sealed_entrance.bind(step))
		await _run("%s: right stick turns the body and tilts the head, clamped at 89 deg" % step, test_stick_look.bind(step))
		await _run("%s: mouse look maths (0.002 rad per pixel, clamped)" % step, test_mouse_math.bind(step))
	if DisplayServer.get_name() == "headless":
		_skip("mouse capture: Esc releases, a click recaptures; the mouse is released at the finish and captured again by a restart", "the headless display server never reports a captured mouse; tools/capture.gd checks it in a window")
	for step in STEPS:
		await _run("%s: a door in the accent material opens on approach, lets a ray pass when open and blocks when closed" % step, test_door.bind(step))
		await _run("%s: a door never closes on the player" % step, test_door_waits_for_the_swing.bind(step))
		await _run("%s: a player sliding past the free end of an open door leaf keeps moving" % step, test_open_leaf_end.bind(step))
	for step in STEPS:
		await _run("%s key.tscn: a graybox key in the key material, a reach on the player layer, spins and bobs without moving its reach" % step, test_key_scene.bind(step))
		await _run("%s: key spots: on the floor, in view from the entrance, off the walking line, clear of the door" % step, test_key_spots.bind(step))
		await _run("%s: walking into a key counts it once and frees it; the HUD shows \"Keys N\"" % step, test_pickup.bind(step))
		await _run("%s: the keys label sits in the stats box with the other labels" % step, test_keys_label.bind(step))
		await _run("%s: a locked door shows its lock, stays shut without a key, opens with one and uses it up" % step, test_locked_door.bind(step))
	await _run("every step: every locked room has its key in the same room, and the player can finish with them", test_locks_in_level)
	for step: String in ["step_00_start", FINAL_STEP]:
		await _run("%s: a locked door without a key rattles within one physics frame, the lock flashes, \"Locked: find the key\" shows for 1.5 s" % step, test_feedback.bind(step))
		await _run("%s: with a key the lock drops and fades and the door opens normally" % step, test_unlock_animation.bind(step))

	# Tutorial 05: props.
	for step in _steps_from("step_01_prop_spots"):
		await _run("%s props/*.tscn: five graybox props in prop.tres, a StaticBody3D on the world layer, origin at the back middle, facing -Z" % step, test_prop_scenes.bind(step))
		await _run("%s: every module has 4 to 6 prop spots on the floor against a wall, facing into the room; the goal room has none" % step, test_prop_spots.bind(step))
		await _run("%s: same seed, same props; they depend on the seed and the room only (not on locks, goal room or lock chance)" % step, test_prop_determinism.bind(step))
		await _run("%s: the level builds the props the plans say, on the spots, as children of their room, and they go with it" % step, test_props_in_level.bind(step))
	await _run("props: the spot rules hold for every prop at every spot (and every pair of props), not just for the seeds we try", test_prop_spot_rules)
	await _run("props: a prop is solid: the player walking into one stops at its face", test_props_are_solid)
	await _run("props: step 1 fills about half of the spots, with every prop in use", test_step_one_props)
	for step in _steps_from("step_02_prop_sets"):
		await _run("%s: the prop sets are Resources: one .tres per room type, scenes and weights match, the long hall favours pillars, the wide room tables and shelves" % step, test_prop_sets.bind(step))
	await _run("weighted pick: sum, roll, walk: boundaries, zero weights, and 100000 rolls land in proportion", test_weighted_pick)
	await _run("props: the weights decide: what a set holds shows in the plans in proportion (seeds 1-%d), and changing the data changes the plans" % PROP_SEEDS, test_prop_distribution)
	for step in _steps_from("step_03_weighted_rooms"):
		await _run("%s: the room weights are a Resource: the data decides the order, the same seed gives the same order" % step, test_room_weights.bind(step))
	await _run("weighted rooms: a new order for the same seed (tutorial 04's is gone), the weights show in the mix, the heading and overlap rules did not change", test_weighted_rooms)
	await _run("vault: at most once every min_gap rooms (seeds 1-%d), never room 0 or the goal, exactly min_gap apart sometimes, the filter's boundary" % SEED_COUNT, test_vault_spacing)
	await _run("vault: seed 42 shows a vault before the goal room; a locked vault holds its key at one of its spots", test_vault_seed_42)
	await _run("contents: the check (check_contents.gd) holds for seeds 1-%d at lock chance 0.4 and 1.0" % SEED_COUNT, test_contents_check_seeds)
	await _run("contents: the check finds each kind of broken content", test_contents_finds_faults)
	await _run("contents: the chain's clear_prop_spots() gives the twin without props: the same rooms and locks, no prop anywhere", test_clear_prop_spots)
	await _run("contents: check_contents.gd runs from the command line and exits 0", test_contents_command)

	for step in STEPS:
		await _run("%s: rooms stream in and out through %d rooms, keys fetched on the way" % [step, STREAM_ROOMS], test_streaming.bind(step))
	for step: String in ["step_00_start", FINAL_STEP]:
		await _run("%s: the plans do not depend on when the player walks" % step, test_timing_independence.bind(step))
	for step in STEPS:
		await _run("%s: the map starts visible, Tab toggles it" % step, test_toggle_map.bind(step))
		await _run("%s: the map reads data only" % step, test_map_reads_data_only.bind(step))
	for step in STEPS:
		await _run("%s: the HUD counter reads \"Room N / goal\", follows the player and fits the screen" % step, test_counter.bind(step))
		await _run("%s: the run ends in the goal room (no door, a pad to walk onto)" % step, test_goal_in_level.bind(step))
	await _run("state: the enum is READY, RUNNING, FINISHED in every step", test_state_enum)
	for step in STEPS:
		await _run("%s: READY in room 0, RUNNING when the first door opens, FINISHED on the goal pad, input ignored after" % step, test_states.bind(step))
		await _run("%s: the finish panel is centred and hidden until the finish" % step, test_finish_panel.bind(step))
	await _run("timer: format_time cuts to tenths (0:00.0, 0:42.3, 1:00.0 ...)", test_format_time)
	for step in STEPS:
		await _run("%s: the timer adds physics deltas only, never the wall clock, and stops at the finish" % step, test_timer.bind(step))
		await _run("%s: R restarts the same seed, N starts seed + 1, both through start(), keys back to 0" % step, test_restart.bind(step))
	await _run("restart: the reset lives in start() and nowhere else", test_reset_in_one_place)
	for step in STEPS:
		await _run("%s: R and N pressed at the first door do not open the door of the new room 0" % step, test_restart_at_the_door.bind(step))
	await _run("best times: a saved time loads again (round trip), the file has the documented shape", test_best_round_trip)
	await _run("best times: only a faster time replaces the best", test_best_only_faster)
	await _run("best times: no file is an empty list and loading writes nothing", test_best_missing_file)
	await _run("best times: a damaged file is kept as .bad, the list starts empty, no crash", test_best_damaged_file)
	await _run("best times: unknown keys and odd entries survive a rewrite", test_best_unknown_keys)
	await _run("best times: the save goes through a temp file, a stale temp file does no harm", test_best_atomic_write)
	await _run("best times: a save that cannot be written does not crash and keeps the time in memory", test_best_write_failure)
	await _run("best time: the HUD shows \"Best 0:39.8\" for the current seed and follows N", test_best_label)
	await _run("best time: a faster run says \"New best!\" and is saved, a slower one is not", test_best_in_level)
	await _run("full run: seed 42, goal room 20, props and a vault on the way: the autopilot fetches every key, opens every lock and finishes; the best time is saved", test_full_run)
	await _run("full runs: other seeds, locked vaults, and every lockable room locked, still finish", test_more_full_runs)
	await _run("worst case: every prop spot filled with the biggest prop it can hold, the autopilot still finishes (seeds 42, 3, 7)", test_full_runs_all_spots_filled)
	await _run("autopilot: seeds 1-%d of the finished game all reach the goal, none is held in place (%d processes)" % [SWEEP_SEEDS, SWEEP_WORKERS], test_autopilot_seed_sweep)
	for step in STEPS:
		await _run("%s: main scene runs 30 frames" % step, test_scene_runs.bind(step))

	_wipe_save_dir()
	OS.remove_logger(_script_errors)
	print("\n%d passed, %d failed, %d skipped in %.1f s" % [_passed, _failed, _skipped, (Time.get_ticks_msec() - started) / 1000.0])
	quit(1 if _failed > 0 else 0)

## Runs one test unless a `-- --only=text` argument asks for other tests only.
func _run(test_name: String, test: Callable) -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--only=") and not test_name.contains(argument.trim_prefix("--only=")):
			return
	await process_frame # the engine empties its message queue between tests: the chain tests build thousands of room scenes
	var failures: Array[String] = await test.call()
	_report(test_name, failures)

func _steps_from(first: String) -> Array[String]:
	var result: Array[String] = []
	for step: String in STEPS.slice(STEPS.find(first)):
		result.append(step)
	return result

#region Source rules

func test_code_rules() -> Array[String]:
	var failures: Array[String] = []
	var global_random := RegEx.create_from_string("(^|[^.\\w])(randi|randf|randi_range|randf_range|randomize|pick_random)\\(")
	var wall_clock := RegEx.create_from_string("(Time\\.get_|OS\\.get_ticks|OS\\.get_unix|OS\\.delay)")
	var scripts := _scripts_in("res://steps")
	_expect(failures, scripts.size() >= 50, "found only %d scripts under steps" % scripts.size())
	for path in scripts:
		var source := FileAccess.get_file_as_string(path)
		var lines := source.split("\n")
		for i in lines.size():
			var line := lines[i].strip_edges()
			if line.begins_with("##") or line.begins_with("#"):
				continue
			var where := "%s:%d" % [path.trim_prefix("res://"), i + 1]
			_expect(failures, not line.begins_with("class_name"), "%s: class_name" % where)
			_expect(failures, global_random.search(line) == null, "%s: global random call" % where)
			_expect(failures, wall_clock.search(line) == null, "%s: reads the wall clock (the run time comes from the physics delta)" % where)
			_expect(failures, not line.contains(".shuffle("), "%s: Array.shuffle() uses the global generator" % where)
			_expect(failures, not line.contains("Input.is_key_pressed") and not line.contains("Input.is_physical_key_pressed"), "%s: reads a key directly" % where)
			_expect(failures, not line.contains("Input.is_mouse_button_pressed") and not line.contains("get_joy_axis") and not line.contains("is_joy_button_pressed"), "%s: reads a device directly" % where)
			_expect(failures, not line.contains("event is InputEventKey") and not line.contains("event is InputEventJoypad"), "%s: reads a key or button event directly" % where)
	# Gameplay state is never written in _process.
	for step in STEPS:
		var level_source := FileAccess.get_file_as_string("res://steps/%s/level.gd" % step)
		_expect(failures, not level_source.contains("func _process("), "%s/level.gd has a _process: the clock belongs in _physics_process" % step)
		_expect(failures, level_source.contains("func _physics_process(delta: float)") and level_source.contains("run_time += delta"), "%s/level.gd does not add the physics delta" % step)
	return failures

func _scripts_in(dir_path: String) -> Array[String]:
	var found: Array[String] = []
	var dir := DirAccess.open(dir_path)
	for sub in dir.get_directories():
		found.append_array(_scripts_in(dir_path.path_join(sub)))
	for file in dir.get_files():
		if file.ends_with(".gd"):
			found.append(dir_path.path_join(file))
	return found

func test_hud_reads_only() -> Array[String]:
	var failures: Array[String] = []
	var assignment := RegEx.create_from_string("\\blevel\\.[\\w.]+\\s*(=|\\+=|-=)[^=]")
	var call_that_changes := RegEx.create_from_string("\\blevel\\.(start|_set_state|_spawn_room|_spawn_key|_on_unlock_requested)\\(")
	for step in STEPS:
		var lines := FileAccess.get_file_as_string("res://steps/%s/hud.gd" % step).split("\n")
		for i in lines.size():
			var line := lines[i].strip_edges()
			if line.begins_with("#"):
				continue
			_expect(failures, assignment.search(line) == null and call_that_changes.search(line) == null, "%s/hud.gd:%d changes the level: %s" % [step, i + 1, line])
	return failures

## The steps are copies of each other: a file only differs where the step's concept needs it.
func test_copy_forward() -> Array[String]:
	var failures: Array[String] = []
	for i in range(1, STEPS.size()):
		var before := STEPS[i - 1]
		var after := STEPS[i]
		var before_files := _step_files(before)
		var after_files := _step_files(after)
		var changed: Array[String] = []
		var added: Array[String] = []
		for file in before_files:
			if not after_files.has(file):
				failures.append("%s lost %s" % [after, file])
			elif _step_text(before, file) != _step_text(after, file):
				changed.append(file)
		for file in after_files:
			if not before_files.has(file):
				added.append(file)
		changed.sort()
		added.sort()
		var expected: Dictionary = CHANGES[after]
		_expect(failures, changed == expected.changed, "%s changes %s, expected %s" % [after, changed, expected.changed])
		_expect(failures, added == expected.added, "%s adds %s, expected %s" % [after, added, expected.added])
	return failures

func _step_files(step: String) -> Array[String]:
	var files: Array[String] = []
	for file in DirAccess.get_files_at("res://steps/" + step):
		if not file.ends_with(".uid"):
			files.append(file)
	if DirAccess.dir_exists_absolute("res://steps/%s/props" % step): # the props of tutorial 05 live in a folder of their own
		for file in DirAccess.get_files_at("res://steps/%s/props" % step):
			if not file.ends_with(".uid"):
				files.append("props/" + file)
	return files

## The file's text with the step folder name blanked out, so copies compare equal.
func _step_text(step: String, file: String) -> String:
	return FileAccess.get_file_as_string("res://steps/%s/%s" % [step, file]).replace(step, "STEP")

func test_step_zero_is_tutorial_04() -> Array[String]:
	var failures: Array[String] = []
	var original := ProjectSettings.globalize_path("res://").path_join("../04-keys-and-locked-doors/steps/step_05_locked_feedback").simplify_path()
	if not DirAccess.dir_exists_absolute(original):
		_skip("step_00_start equals tutorial 04's step 5", "tutorial 04 is not next to this project")
		return failures
	var count := 0
	for file in DirAccess.get_files_at(original):
		if file.ends_with(".uid"):
			continue
		count += 1
		# The folder names are the only difference: the step's own, and the project's in one usage comment.
		var theirs := FileAccess.get_file_as_string(original.path_join(file)).replace("step_05_locked_feedback", "STEP").replace("godot/04-keys-and-locked-doors", "godot/PROJECT")
		var ours := FileAccess.get_file_as_string("res://steps/step_00_start/" + file).replace("step_00_start", "STEP").replace("godot/05-room-contents", "godot/PROJECT")
		_expect(failures, theirs == ours, "%s differs from tutorial 04's step 5" % file)
	_expect(failures, count == _step_files("step_00_start").size(), "step_00_start has %d files, tutorial 04's step 5 has %d" % [_step_files("step_00_start").size(), count])
	return failures

#endregion

#region Chain (pure data, no scene)

func test_determinism(chain_script: GDScript) -> Array[String]:
	var failures: Array[String] = []
	var first := _plans(chain_script, 42, 100)
	var second := _plans(chain_script, 42, 100)
	var other := _plans(chain_script, 43, 100)
	_expect(failures, first.size() == 100, "made %d plans, expected 100" % first.size())
	_expect(failures, _same_plans(first, second), "seed 42 twice: the plans differ")
	_expect(failures, not _same_plans(first, other), "seed 43 gives the same plans as seed 42")
	for i in first.size():
		_expect(failures, first[i].index == i, "plan %d has index %d" % [i, first[i].index])
	return failures

func test_no_overlap(chain_script: GDScript, seed_count: int) -> Array[String]:
	var failures: Array[String] = []
	var types_seen := {}
	for chain_seed in range(1, seed_count + 1):
		if chain_seed % 50 == 0:
			await process_frame
		# Goal far away: this checks the ordinary rooms.
		var plans := _plans(chain_script, chain_seed, ROOMS_PER_SEED)
		for plan: Object in plans:
			types_seen[plan.type] = true
		failures.append_array(_chain_problems(plans, "seed %d" % chain_seed))
		if failures.size() > 8:
			break
	_expect(failures, types_seen.size() == chain_script.SCENES.size() - 1, "only %d of %d room types were ever chosen (the goal room is never drawn)" % [types_seen.size(), chain_script.SCENES.size() - 1])
	return failures

## Overlaps with any earlier plan, headings that turn back, and snaps that do not meet.
## `plans` is the history of one chain; the last plan may be a goal room (it has no exit).
func _chain_problems(plans: Array, label: String) -> Array[String]:
	var problems: Array[String] = []
	# Sweep over x: a room can only overlap rooms whose x range reaches it.
	var by_x := plans.duplicate()
	by_x.sort_custom(func(a: Object, b: Object) -> bool: return a.bounds.position.x < b.bounds.position.x)
	for i in by_x.size():
		var a: Object = by_x[i]
		var inner: AABB = (a.bounds as AABB).grow(-Chain.SHRINK)
		for j in range(i + 1, by_x.size()):
			var b: Object = by_x[j]
			if b.bounds.position.x > a.bounds.end.x:
				break
			if inner.intersects(b.bounds) or (b.bounds as AABB).grow(-Chain.SHRINK).intersects(a.bounds):
				problems.append("%s: rooms %d and %d overlap" % [label, a.index, b.index])
	var start: Vector3 = plans[0].transform.origin
	for k in range(1, plans.size() - 1):
		# The next room's entrance has no rotation, so its basis is the heading of this exit.
		var heading: Vector3 = -(plans[k + 1].transform as Transform3D).basis.z
		var to_start := (start - (plans[k].transform as Transform3D).origin).normalized()
		if heading.dot(Chain.START_HEADING) < -Chain.BACK_LIMIT or heading.dot(to_start) > Chain.BACK_LIMIT + 0.001:
			problems.append("%s: room %d heads back (heading %s)" % [label, k, heading.snapped(Vector3.ONE * 0.01)])
	return problems

## A chain of any step's script.
func _new_chain(chain_script: GDScript, chain_seed: int, goal_room: int, chance := 0.0) -> RefCounted:
	return chain_script.new(chain_seed, goal_room, chance)

## The room_chain.gd of a step.
func _chain_script(step: String) -> GDScript:
	return load("res://steps/%s/room_chain.gd" % step) as GDScript

## What the chain's Type enum calls the goal room: 5 up to step 3, 6 from the vault on.
func _goal_type(chain_script: GDScript) -> int:
	return (chain_script.get_script_constant_map()["Type"] as Dictionary)["GOAL"]

## The room types a step has: the ordinary five, and the vault from step 4 on.
func _room_types_of(step: String) -> Array[String]:
	var types := ROOM_TYPES.duplicate()
	if STEPS.find(step) >= STEPS.find("step_04_rare_rooms"):
		types.append("vault")
	return types

## The first `count` plans, the goal room far behind them.
func _plans(chain_script: GDScript, chain_seed: int, count: int, chance := LOCK_CHANCE) -> Array:
	var chain := _new_chain(chain_script, chain_seed, 100000, chance)
	for i in count:
		chain.next_plan()
	return chain.plans

func _same_plans(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if a[i].index != b[i].index or a[i].type != b[i].type or a[i].transform != b[i].transform or a[i].bounds != b[i].bounds:
			return false
		if a[i].get("locked") != b[i].get("locked") or a[i].get("key_spot") != b[i].get("key_spot") or a[i].get("props") != b[i].get("props"):
			return false # plans of the steps before step 1 have no props: both sides read null
	return true

#endregion

#region The goal room in the chain

## All plans of a chain up to and including its goal room (at most `limit` plans).
func _plans_to_goal(chain_script: GDScript, chain_seed: int, goal_room: int, chance := LOCK_CHANCE, limit := 400) -> RefCounted:
	var chain := _new_chain(chain_script, chain_seed, goal_room, chance)
	while chain.plans.size() < limit:
		var plan: Object = chain.next_plan()
		if plan.type == _goal_type(chain_script):
			break
	return chain

func test_goal_placement(chain_script: GDScript) -> Array[String]:
	var failures: Array[String] = []
	var waited := 0
	var max_extra := 0
	for chain_seed in range(1, GOAL_SEEDS + 1):
		if chain_seed % 50 == 0:
			await process_frame
		var chain := _plans_to_goal(chain_script, chain_seed, 20)
		var plans: Array = chain.plans
		var goals: Array[int] = []
		for plan: Object in plans:
			if plan.type == _goal_type(chain_script):
				goals.append(plan.index)
		if goals.size() != 1 or goals[0] != plans.size() - 1:
			failures.append("seed %d: goal rooms at %s of %d plans" % [chain_seed, goals, plans.size()])
			continue
		var extra: int = goals[0] - 20
		max_extra = maxi(max_extra, extra)
		waited += 1 if extra > 0 else 0
		if extra < 0 or extra > MAX_EXTRA_ROOMS:
			failures.append("seed %d: the goal room is plan %d, expected 20 to %d" % [chain_seed, goals[0], 20 + MAX_EXTRA_ROOMS])
		_expect(failures, chain.goal_index == goals[0], "seed %d: goal_index %d but the goal is plan %d" % [chain_seed, chain.goal_index, goals[0]])
		failures.append_array(_chain_problems(plans, "seed %d" % chain_seed))
		if failures.size() > 8:
			break
	print("        goal room: seeds 1-%d, %d needed to wait, the longest wait was %d rooms" % [GOAL_SEEDS, waited, max_extra])
	return failures

func test_goal_other_indices(chain_script: GDScript) -> Array[String]:
	var failures: Array[String] = []
	for goal_room: int in [1, 2, 7, 50, 120]:
		for chain_seed in range(1, 101):
			if chain_seed % 50 == 0:
				await process_frame
			var chain := _plans_to_goal(chain_script, chain_seed, goal_room)
			var plans: Array = chain.plans
			var last: Object = plans[-1]
			_expect(failures, last.type == _goal_type(chain_script), "goal %d seed %d: the chain does not end in a goal room" % [goal_room, chain_seed])
			_expect(failures, last.index >= goal_room and last.index <= goal_room + MAX_EXTRA_ROOMS, "goal %d seed %d: goal room is plan %d" % [goal_room, chain_seed, last.index])
			failures.append_array(_chain_problems(plans, "goal %d seed %d" % [goal_room, chain_seed]))
			if failures.size() > 8:
				return failures
	return failures

## The wait itself. A goal that never fits is faked: the goal's box is blown up to 2 km, so it hits
## the history wherever it is placed. (The test reaches into the chain's private module list; the
## shipped rooms always find a free place, see test_goal_placement.)
func test_goal_waits(chain_script: GDScript) -> Array[String]:
	var failures: Array[String] = []
	for chain_seed: int in [42, 7, 313]:
		var chain := _new_chain(chain_script, chain_seed, 6, 1.0)
		var real_bounds: AABB = chain._modules[_goal_type(chain_script)].bounds
		for i in 6:
			chain.next_plan()
		chain._modules[_goal_type(chain_script)].bounds = AABB(Vector3(-1000.0, -10.0, -1000.0), Vector3(2000.0, 20.0, 2000.0))
		for waited in 3:
			var plan: Object = chain.next_plan()
			_expect(failures, plan.type != _goal_type(chain_script), "seed %d: an unfit goal room was placed as plan %d" % [chain_seed, plan.index])
			_expect(failures, plan.index == 6 + waited and chain.goal_index == 7 + waited, "seed %d: plan %d, goal_index %d after %d waits" % [chain_seed, plan.index, chain.goal_index, waited + 1])
		chain._modules[_goal_type(chain_script)].bounds = real_bounds # free again
		var goal: Object = chain.next_plan()
		_expect(failures, goal.type == _goal_type(chain_script) and goal.index == 9 and chain.goal_index == 9, "seed %d: after the wait the goal is plan %d (goal_index %d), expected 9" % [chain_seed, goal.index, chain.goal_index])
		failures.append_array(_chain_problems(chain.plans, "seed %d after the wait" % chain_seed))
		# The same story twice gives the same plans.
		var again := _new_chain(chain_script, chain_seed, 6, 1.0)
		for i in 6:
			again.next_plan()
		again._modules[_goal_type(chain_script)].bounds = AABB(Vector3(-1000.0, -10.0, -1000.0), Vector3(2000.0, 20.0, 2000.0))
		for i in 3:
			again.next_plan()
		again._modules[_goal_type(chain_script)].bounds = real_bounds
		again.next_plan()
		_expect(failures, _same_plans(chain.plans, again.plans), "seed %d: the waiting chain is not reproducible" % chain_seed)
		if chain_script == Chain: # the rule "the room before the goal is never locked" holds when the goal waits, too
			for plan: Object in chain.plans:
				_expect(failures, not (plan.locked and (plan.index == 0 or plan.index >= 5)), "seed %d: room %d is locked, but room 0 and every room from 5 on (before the waiting goal) stay open" % [chain_seed, plan.index])
	return failures

#endregion

#region Rooms and snapping (scene + physics)

func test_room_module(room_type: String, step: String) -> Array[String]:
	var failures: Array[String] = []
	var room: Node3D = (load("res://steps/%s/room_%s.tscn" % [step, room_type]) as PackedScene).instantiate()
	root.add_child(room)
	# The room puts a closed door in its exit; this test is about the doorway itself.
	(room.get("door") as Node).free()
	await _wait_physics(5)
	var entrance: Marker3D = room.get_node("Entrance")
	var exit_point: Marker3D = room.get_node("Exit")
	var inside_shape: CollisionShape3D = room.get_node("Inside/CollisionShape3D")
	var bounds: AABB = inside_shape.transform * AABB(-(inside_shape.shape as BoxShape3D).size / 2.0, (inside_shape.shape as BoxShape3D).size)
	var centre := bounds.get_center()
	centre.y = 0.0

	_expect(failures, is_zero_approx(entrance.position.y) and is_zero_approx(exit_point.position.y), "markers are not at floor level")
	_expect(failures, (centre - entrance.position).dot(-entrance.global_basis.z) > 1.0, "Entrance -Z does not point into the room")
	_expect(failures, (exit_point.position - centre).dot(-exit_point.global_basis.z) > 1.0, "Exit -Z does not point out of the room")
	_expect(failures, entrance.transform.basis.is_equal_approx(Basis.IDENTITY), "Entrance is rotated")
	# The Inside box covers the footprint including the walls (the CSG shell).
	var floor_box: CSGBox3D = room.get_node("Shell/Floor")
	var floor_aabb := floor_box.transform * AABB(-floor_box.size / 2.0, floor_box.size)
	_expect(failures, bounds.size.x == floor_aabb.size.x and bounds.size.z == floor_aabb.size.z, "Inside box %s does not match the floor %s" % [bounds.size, floor_aabb.size])
	_expect(failures, is_equal_approx(bounds.size.y, WALL_HEIGHT), "Inside box is %.2f m high, walls are 3 m" % bounds.size.y)
	for wall_name: String in ["WallEntrance", "WallFar", "WallLeft", "WallRight"]:
		var wall: CSGBox3D = room.get_node("Shell/" + wall_name)
		_expect(failures, is_equal_approx(wall.size.y, WALL_HEIGHT), "%s is %.2f m high" % [wall_name, wall.size.y])
		_expect(failures, is_equal_approx(minf(wall.size.x, wall.size.z), WALL_THICKNESS), "%s is %.2f m thick" % [wall_name, minf(wall.size.x, wall.size.z)])

	# Doorway: 1.6 m wide, 2.4 m high, in the wall at each marker.
	for point: Marker3D in [entrance, exit_point]:
		var label := point.name
		for sideways: float in [0.0, 0.7, -0.7]:
			_expect(failures, not _ray_hits(room, point, Vector3(sideways, RAY_HEIGHT, 1.0), Vector3(sideways, RAY_HEIGHT, -1.0)), "%s: a ray %.1f m off the middle hits the wall" % [label, sideways])
		for sideways: float in [0.9, -0.9]:
			_expect(failures, _ray_hits(room, point, Vector3(sideways, RAY_HEIGHT, 1.0), Vector3(sideways, RAY_HEIGHT, -1.0)), "%s: a ray %.1f m off the middle passes the wall" % [label, sideways])
		_expect(failures, not _ray_hits(room, point, Vector3(0.0, 2.3, 1.0), Vector3(0.0, 2.3, -1.0)), "%s: the doorway is lower than 2.3 m" % label)
		_expect(failures, _ray_hits(room, point, Vector3(0.0, 2.5, 1.0), Vector3(0.0, 2.5, -1.0)), "%s: the doorway is higher than 2.5 m" % label)
	root.remove_child(room)
	room.free()
	return failures

## Casts a ray in a marker's own space (x sideways, y up, -z the way through the wall).
func _ray_hits(room: Node3D, point: Marker3D, from_local: Vector3, to_local: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(point.global_transform * from_local, point.global_transform * to_local)
	return not room.get_world_3d().direct_space_state.intersect_ray(query).is_empty()

func test_snapping(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step)
	var rooms := _rooms_of(main.get_node("Level"))
	_expect(failures, rooms.size() >= 1, "%d rooms" % rooms.size())
	for i in range(rooms.size() - 1):
		var exit_point: Transform3D = (rooms[i].get("exit") as Marker3D).global_transform
		var entrance: Transform3D = (rooms[i + 1].get("entrance") as Marker3D).global_transform
		_expect(failures, exit_point.origin.distance_to(entrance.origin) < 1e-4, "room %d Entrance is %.5f m from room %d Exit" % [i + 1, exit_point.origin.distance_to(entrance.origin), i])
		_expect(failures, exit_point.basis.is_equal_approx(entrance.basis), "room %d Entrance faces another way than room %d Exit" % [i + 1, i])
	await _unload(main)
	return failures

## All rooms of a level in order: its children that have an Entrance.
func _rooms_of(level: Node3D) -> Array[Node3D]:
	var rooms: Array[Node3D] = []
	for child in level.get_children():
		if child is Node3D and child.get("entrance") != null and not child.is_queued_for_deletion():
			rooms.append(child)
	return rooms

#endregion

#region The goal room module

func test_goal_room(step: String) -> Array[String]:
	var failures: Array[String] = []
	var room := (load("res://steps/%s/room_goal.tscn" % step) as PackedScene).instantiate() as Node3D
	var player := (load("res://steps/%s/player.tscn" % step) as PackedScene).instantiate()
	var capsule := (player.get_node("CollisionShape3D") as CollisionShape3D).shape as CapsuleShape3D
	player.free()
	root.add_child(room)
	await _wait_physics(5)

	# Entrance only: no Exit marker, no doorway in the far wall.
	_expect(failures, room.get_node_or_null("Exit") == null, "the goal room has an Exit")
	_expect(failures, (room.get_node("Shell/WallFar") as Node).get_child_count() == 0, "the far wall of the goal room has a doorway")
	var entrance: Marker3D = room.get_node("Entrance")
	_expect(failures, entrance.transform.origin.is_equal_approx(Vector3(0.0, 0.0, 7.0)) and entrance.transform.basis.is_equal_approx(Basis.IDENTITY), "Entrance is at %s, expected (0, 0, 7) unrotated" % entrance.transform)
	var floor_box := room.get_node("Shell/Floor") as CSGBox3D
	_expect(failures, Vector2(floor_box.size.x, floor_box.size.z).is_equal_approx(Vector2(10.0, 14.0)), "the floor is %.1f x %.1f m, expected 10 x 14" % [floor_box.size.x, floor_box.size.z])
	var inside_shape := room.get_node("Inside/CollisionShape3D") as CollisionShape3D
	_expect(failures, (inside_shape.shape as BoxShape3D).size.is_equal_approx(Vector3(10.0, 3.0, 14.0)), "the Inside box is %s" % (inside_shape.shape as BoxShape3D).size)
	_expect(failures, room.get_node_or_null("Ceiling") != null and room.get_node_or_null("RoomLight") != null and room.get_node_or_null("Fixture") != null, "ceiling, room light or fixture missing")
	# Open at the entrance: a ray through the doorway passes; the far wall is solid everywhere.
	_expect(failures, not _ray_hits(room, entrance, Vector3(0.0, RAY_HEIGHT, 1.0), Vector3(0.0, RAY_HEIGHT, -1.0)), "the entrance doorway is closed")
	var space := room.get_world_3d().direct_space_state
	for sideways: float in [0.0, 1.0, -2.5, 3.0]:
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(sideways, RAY_HEIGHT, -5.0), Vector3(sideways, RAY_HEIGHT, -8.0)))
		_expect(failures, not hit.is_empty(), "a ray through the far wall at x = %.1f passes: there is a doorway" % sideways)

	# The pad: 3 x 3, raised a little (a step the capsule climbs), the gold accent, from the shared materials.
	var pad := room.get_node("Shell/Pad") as CSGBox3D
	_expect(failures, is_equal_approx(pad.size.x, 3.0) and is_equal_approx(pad.size.z, 3.0), "the pad is %.1f x %.1f m, expected 3 x 3" % [pad.size.x, pad.size.z])
	var pad_top := pad.position.y + pad.size.y / 2.0
	_expect(failures, pad.size.y >= 0.05 and pad.size.y <= 0.15 and is_equal_approx(pad_top, pad.size.y), "the pad is %.2f m high (top at %.2f), expected a low step standing on the floor" % [pad.size.y, pad_top])
	_expect(failures, pad.material != null and pad.material.resource_path == MATERIAL_DIR + "goal.tres", "the pad does not use goal.tres")
	var pad_box := AABB(pad.position - pad.size / 2.0, pad.size)
	_expect(failures, AABB(Vector3(-5.0, 0.0, -7.0), Vector3(10.0, 0.2, 14.0)).encloses(pad_box), "the pad does not lie inside the room")
	_expect(failures, pad_box.position.z + pad_box.size.z < -1.0, "the pad is not at the far end, away from the entrance")
	var down := space.intersect_ray(PhysicsRayQueryParameters3D.create(pad.global_position + Vector3(0.0, 1.0, 0.0), pad.global_position + Vector3(0.0, -1.0, 0.0)))
	_expect(failures, not down.is_empty() and absf((down["position"] as Vector3).y - pad_top) < 0.01, "a ray down onto the pad does not hit its top")
	var up := space.intersect_ray(PhysicsRayQueryParameters3D.create(pad.global_position + Vector3(0.0, 1.0, 0.0), pad.global_position + Vector3(0.0, 3.5, 0.0)))
	_expect(failures, not up.is_empty() and absf((up["position"] as Vector3).y - WALL_HEIGHT) < 0.01, "a ray up from the pad does not hit the ceiling")

	# The trigger: the player layer only, over the pad, small enough that the whole capsule is on the pad when it fires.
	var goal_pad := room.get_node("GoalPad") as Area3D
	_expect(failures, goal_pad.collision_layer == 0 and goal_pad.collision_mask == 2, "GoalPad: layer %d mask %d, expected 0 and 2 (the player layer)" % [goal_pad.collision_layer, goal_pad.collision_mask])
	_expect(failures, goal_pad.global_position.is_equal_approx(Vector3(pad.position.x, 0.0, pad.position.z)), "GoalPad is at %s, not at the middle of the pad" % goal_pad.global_position)
	var trigger := goal_pad.get_node("CollisionShape3D") as CollisionShape3D
	var trigger_box := trigger.shape as BoxShape3D
	_expect(failures, trigger_box != null and trigger.position.y - trigger_box.size.y / 2.0 < capsule.height and trigger.position.y + trigger_box.size.y / 2.0 > pad_top, "the trigger does not reach the player's body")
	if trigger_box != null:
		_expect(failures, trigger_box.size.x / 2.0 + capsule.radius <= pad.size.x / 2.0 + 0.001 and trigger_box.size.z / 2.0 + capsule.radius <= pad.size.z / 2.0 + 0.001, "the trigger fires before the capsule is on the pad (half %.2f + radius %.2f > pad half %.2f)" % [trigger_box.size.x / 2.0, capsule.radius, pad.size.x / 2.0])

	# Its own small warm light and a visible fixture over the pad, on the ceiling layer like the room's lamp.
	var light := room.get_node("PadLight") as OmniLight3D
	var fixture := room.get_node("PadFixture") as MeshInstance3D
	var block := fixture.mesh as BoxMesh
	_expect(failures, not light.shadow_enabled, "PadLight casts shadows")
	_expect(failures, light.light_color.r >= light.light_color.g and light.light_color.g >= light.light_color.b and light.light_color.b < 0.95, "PadLight is not warm")
	_expect(failures, light.omni_range < (room.get_node("RoomLight") as OmniLight3D).omni_range and light.omni_range >= Vector3(1.5, 0.0, 1.5).length() and light.omni_range <= 6.0, "PadLight range %.1f is not a small light that covers the pad" % light.omni_range)
	_expect(failures, Vector2(light.position.x - pad.position.x, light.position.z - pad.position.z).length() < 0.01 and light.position.y > 2.2 and light.position.y < WALL_HEIGHT, "PadLight is not over the pad near the ceiling (%s)" % light.position)
	_expect(failures, fixture.layers == CEILING_LAYER, "PadFixture is on layers %d, expected only layer 2" % fixture.layers)
	_expect(failures, block.material != null and block.material.resource_path == MATERIAL_DIR + "fixture.tres", "PadFixture does not use fixture.tres")
	_expect(failures, is_equal_approx(fixture.position.y + block.size.y / 2.0, WALL_HEIGHT) and Vector2(fixture.position.x - light.position.x, fixture.position.z - light.position.z).length() < 0.01, "PadFixture does not hang under the ceiling above the PadLight")
	_expect(failures, block.size.x <= 0.5 and block.size.z <= 0.5, "PadFixture is %.1f x %.1f m: a small light gets a small block" % [block.size.x, block.size.z])
	root.remove_child(room)
	room.free()
	return failures

#endregion

#region Player

func test_walk(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step)
	var player: CharacterBody3D = main.get_node("Level").player
	var start := player.global_position
	_expect(failures, player.is_on_floor(), "player is not on the floor at the start")
	_expect(failures, start.distance_to(Vector3(0.0, 0.0, 3.5)) < 0.05, "player starts at %s, expected 1.5 m inside room 0 at (0, 0, 3.5)" % start)
	_expect(failures, (-player.global_basis.z).is_equal_approx(Vector3.FORWARD), "player does not face the way the chain starts")

	# 45 frames at 5 m/s: 3.75 m, still short of the first door's trigger.
	Input.action_press("move_forward")
	await _wait_physics(45)
	Input.action_release("move_forward")
	var moved := player.global_position - start
	_expect(failures, moved.dot(-player.global_basis.z) > 3.5, "moved only %.2f m forward" % moved.dot(-player.global_basis.z))
	_expect(failures, absf(moved.x) < 0.1, "drifted %.2f m sideways" % moved.x)
	_expect(failures, absf(player.global_position.y) < 0.05, "left the floor (y = %.3f)" % player.global_position.y)

	# Relative to the facing: turned right by a quarter, forward now goes along +x.
	player.rotation.y = -PI / 2.0
	var before := player.global_position
	Input.action_press("move_forward")
	await _wait_physics(30)
	Input.action_release("move_forward")
	var turned := player.global_position - before
	_expect(failures, turned.x > 2.0 and absf(turned.z) < 0.1, "facing right, forward moved %s" % turned)
	await _unload(main)
	return failures

func test_jump(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step)
	var player: CharacterBody3D = main.get_node("Level").player
	var camera: Camera3D = player.get_node("Head/Camera3D")
	var capsule := (player.get_node("CollisionShape3D") as CollisionShape3D).shape as CapsuleShape3D
	var ceiling_bottom := _ceiling_bottom(_rooms_of(main.get_node("Level"))[0])
	Input.action_press("jump")
	await _wait_physics(2)
	Input.action_release("jump")
	var highest := 0.0
	var highest_eye := 0.0
	for i in 30:
		await physics_frame
		highest = maxf(highest, player.global_position.y)
		highest_eye = maxf(highest_eye, camera.global_position.y)
	_expect(failures, highest > 0.8 and highest < 1.2, "highest point %.2f m, expected about 1.03" % highest)
	_expect(failures, highest + capsule.height < ceiling_bottom, "the head reaches %.2f m at the top of the jump, the ceiling is at %.2f m" % [highest + capsule.height, ceiling_bottom])
	_expect(failures, highest_eye < ceiling_bottom - 0.2, "the eye reaches %.2f m at the top of the jump, the ceiling is at %.2f m (0.2 m for the near plane)" % [highest_eye, ceiling_bottom])
	await _wait_physics(60)
	_expect(failures, player.is_on_floor(), "player did not land")
	_expect(failures, absf(player.global_position.y) < 0.05, "landed at y = %.3f" % player.global_position.y)
	await _unload(main)
	return failures

func test_sealed_entrance(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step)
	var player: CharacterBody3D = main.get_node("Level").player
	player.rotation.y = PI # look at the entrance wall
	Input.action_press("move_forward")
	await _wait_physics(90)
	Input.action_release("move_forward")
	# The wall's inner face is at z = 4.8 (0.2 m thick, flush with the footprint) and the capsule radius is 0.4 m.
	_expect(failures, player.global_position.z > 4.2 and player.global_position.z < 4.55, "stopped at z = %.2f, expected about 4.4" % player.global_position.z)
	_expect(failures, absf(player.global_position.y) < 0.05, "left the floor (y = %.3f)" % player.global_position.y)
	await _unload(main)
	return failures

func test_stick_look(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step)
	var player: CharacterBody3D = main.get_node("Level").player
	var head: Node3D = player.get_node("Head")

	# 3 rad/s for one second turns the body by about 3 rad (right is negative yaw).
	Input.action_press("look_right")
	await _wait_physics(60)
	Input.action_release("look_right")
	var turned := wrapf(-player.rotation.y, -PI, PI)
	_expect(failures, absf(turned - 3.0) < 0.15, "the stick turned the body by %.2f rad in 1 s" % turned)
	_expect(failures, is_zero_approx(head.rotation.x), "yaw moved the head pitch")

	Input.action_press("look_down")
	await _wait_physics(60)
	Input.action_release("look_down")
	_expect(failures, is_equal_approx(head.rotation.x, -deg_to_rad(89.0)), "looking down: pitch %.1f deg" % rad_to_deg(head.rotation.x))
	Input.action_press("look_up")
	await _wait_physics(120)
	Input.action_release("look_up")
	_expect(failures, is_equal_approx(head.rotation.x, deg_to_rad(89.0)), "looking up: pitch %.1f deg" % rad_to_deg(head.rotation.x))
	_expect(failures, is_zero_approx(player.rotation.x) and is_zero_approx(player.rotation.z), "pitch tilted the body")
	await _unload(main)
	return failures

func test_mouse_math(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step)
	var player: CharacterBody3D = main.get_node("Level").player
	var head: Node3D = player.get_node("Head")
	var sensitivity: float = player.get("mouse_sensitivity")
	_expect(failures, is_equal_approx(sensitivity, 0.002), "sensitivity is %f rad per pixel" % sensitivity)
	var yaw := player.rotation.y
	player.call("rotate_view", Vector2(100.0, 0.0) * sensitivity)
	_expect(failures, is_equal_approx(player.rotation.y - yaw, -0.2), "100 px right turned the body by %.3f rad, expected -0.2" % (player.rotation.y - yaw))
	_expect(failures, is_zero_approx(head.rotation.x), "yaw moved the head pitch")
	player.call("rotate_view", Vector2(0.0, 100000.0) * sensitivity)
	_expect(failures, is_equal_approx(head.rotation.x, -deg_to_rad(89.0)), "mouse down: pitch %.1f deg" % rad_to_deg(head.rotation.x))
	player.call("rotate_view", Vector2(0.0, -200000.0) * sensitivity)
	_expect(failures, is_equal_approx(head.rotation.x, deg_to_rad(89.0)), "mouse up: pitch %.1f deg" % rad_to_deg(head.rotation.x))
	_expect(failures, is_zero_approx(player.rotation.x), "pitch tilted the body")
	await _unload(main)
	return failures

#endregion

#region Doors

func test_door(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step)
	var level: Node3D = main.get_node("Level")
	var player: CharacterBody3D = level.player
	var room: Node3D = level.rooms[0]
	var door: Node3D = room.get("door")
	_unlock_by_hand(door) # step 2 locks room 0 for the key tests; this test is about the swing
	var door_point := (room.get("exit") as Marker3D).global_transform
	var opened_at: Array[float] = []
	door.connect("opened", func() -> void: opened_at.append(_depth(player, door_point)))

	var slab := door.get_node("Hinge/MeshInstance3D") as MeshInstance3D
	var slab_material := (slab.mesh as BoxMesh).material
	_expect(failures, slab_material != null and slab_material.resource_path == MATERIAL_DIR + "door.tres", "the door panel is not the accent material res://materials/door.tres")
	_expect(failures, not door.get("is_open"), "the door starts open")
	_expect(failures, _door_blocks(level, door_point), "the closed door lets a ray pass")
	await _wait_physics(10)
	_expect(failures, not door.get("is_open"), "the door opened by itself")

	# Walk up to it: it opens while the player is still a few metres away.
	Input.action_press("move_forward")
	for i in 150:
		await physics_frame
		if door.get("is_open"):
			break
	Input.action_release("move_forward")
	_expect(failures, door.get("is_open"), "the door did not open on approach")
	_expect(failures, opened_at.size() == 1, "`opened` was emitted %d times" % opened_at.size())
	if opened_at.size() == 1:
		_expect(failures, opened_at[0] < -2.5 and opened_at[0] > -4.2, "the door opened when the player was %.2f m away" % -opened_at[0])

	# Open: the hinge is turned 90 degrees and a ray passes through the doorway.
	await _wait_physics(40)
	var hinge: Node3D = door.get("hinge")
	_expect(failures, absf(hinge.rotation.y - (-PI / 2.0)) < 0.02, "the open door is at %.1f deg" % rad_to_deg(hinge.rotation.y))
	_expect(failures, not _door_blocks(level, door_point), "the open doorway blocks a ray")
	_expect(failures, not _door_blocks(level, door_point, 0.5), "the open doorway blocks a ray 0.5 m off the middle")

	# Closed again: it blocks the ray and the player.
	door.call("close")
	await _wait_physics(40)
	_expect(failures, not door.get("is_open"), "the door is still open after close()")
	_expect(failures, absf(hinge.rotation.y) < 0.02, "the closed door is at %.1f deg" % rad_to_deg(hinge.rotation.y))
	_expect(failures, _door_blocks(level, door_point), "the closed door lets a ray pass")
	Input.action_press("move_forward")
	await _wait_physics(90)
	Input.action_release("move_forward")
	var depth := _depth(player, door_point)
	_expect(failures, depth < -0.3 and depth > -0.65, "walking into the closed door stopped %.2f m before it" % -depth)
	await _unload(main)
	return failures

## True if a ray through the doorway at the exit is stopped by the door. sideways moves it off the middle.
func _door_blocks(level: Node3D, door_point: Transform3D, sideways := -0.3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(door_point * Vector3(sideways, RAY_HEIGHT, 1.0), door_point * Vector3(sideways, RAY_HEIGHT, -2.0))
	query.exclude = [(level.player as CollisionObject3D).get_rid()]
	return not level.get_world_3d().direct_space_state.intersect_ray(query).is_empty()

## How far the player is in front of the exit plane; negative before it.
func _depth(player: Node3D, door_point: Transform3D) -> float:
	return (player.global_position - door_point.origin).dot(-door_point.basis.z)

func test_door_waits_for_the_swing(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step)
	var level: Node3D = main.get_node("Level")
	var player: CharacterBody3D = level.player
	var room: Node3D = level.rooms[0]
	var door: Node3D = room.get("door")
	_unlock_by_hand(door)
	var door_point := (room.get("exit") as Marker3D).global_transform
	var hinge: Node3D = door.get("hinge")

	# Walk into the doorway, the door opening on the way.
	Input.action_press("move_forward")
	for i in 240:
		await physics_frame
		if _depth(player, door_point) > 0.5:
			break
	Input.action_release("move_forward")
	_expect(failures, _depth(player, door_point) > 0.5, "the player did not get through the doorway")
	await _wait_physics(20)

	# Asked to close while the player is in the swing: nothing happens.
	door.call("close")
	await _wait_physics(45)
	_expect(failures, door.get("is_open") and absf(hinge.rotation.y + PI / 2.0) < 0.02, "the door closed on the player (hinge at %.1f deg)" % rad_to_deg(hinge.rotation.y))

	# Out of the swing: it closes, and the player was not touched.
	Input.action_press("move_forward")
	await _wait_physics(60)
	Input.action_release("move_forward")
	var before := player.global_position
	await _wait_physics(60)
	_expect(failures, not door.get("is_open") and absf(hinge.rotation.y) < 0.02, "the door did not close after the player left (hinge at %.1f deg)" % rad_to_deg(hinge.rotation.y))
	_expect(failures, player.global_position.distance_to(before) < 0.01, "the closing door moved the player by %.3f m" % player.global_position.distance_to(before))
	await _unload(main)
	return failures

## The open leaf stands in the next room, 1.6 m long, right where the way leads on. A player pressed against its face who slides
## past its free end must keep moving. On GodotPhysics3D a capsule whose axis stood a tenth of a millimetre past the end of the
## leaf's box was held in place for good (the box has a blind spot at its end edge, the one contact that is still reported is
## the floor's, and every move has zero travel). The projects run Jolt, which has no such blind spot; this guards the setting.
func test_open_leaf_end(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step)
	var level: Node3D = main.get_node("Level")
	var player: CharacterBody3D = level.player
	var door: Node3D = level.rooms[0].get("door")
	door.call("open")
	await _wait_physics(45) # the swing takes half a second
	door.set_physics_process(false) # the leaf stays open, whatever the probes do
	var hinge: Node3D = door.get("hinge")
	_expect(failures, absf(hinge.rotation.y + PI / 2.0) < 0.02, "the leaf is not open (%.1f deg)" % rad_to_deg(hinge.rotation.y))
	var radius := ((player.get_node("CollisionShape3D") as CollisionShape3D).shape as CapsuleShape3D).radius
	var face_x := 0.8 - 0.05 # the door's frame: the hinge sits at x = 0.8, the leaf is 0.1 thick and runs 1.6 m into the room (-z)
	var end_z := -1.6
	var yaw := atan2(-0.8, 0.6) # facing +x and on into the room, as the autopilot does when the exit is on the right
	var held: Array[String] = []
	var probes := 0
	for beyond_mm: float in [0.0, 0.05, 0.1]: # how far the capsule's axis stands past the end of the leaf
		for apart_mm: float in [0.0, 0.1, 0.2]: # how far its side is from the face
			var spot := Vector3(face_x - radius - apart_mm / 1000.0, 0.0, end_z - beyond_mm / 1000.0)
			player.global_transform = door.global_transform * Transform3D(Basis(Vector3.UP, yaw), spot)
			player.velocity = Vector3.ZERO
			await _wait_physics(2)
			var before := player.global_position
			Input.action_press("move_forward")
			await _wait_physics(10)
			Input.action_release("move_forward")
			probes += 1
			var moved := Vector2(player.global_position.x - before.x, player.global_position.z - before.z).length()
			if moved < 0.3:
				held.append("%.2f mm past the end, %.1f mm from the face: moved %.4f m" % [beyond_mm, apart_mm, moved])
	_expect(failures, held.is_empty(), "the player was held in place in %d of %d probes: %s" % [held.size(), probes, held.slice(0, 3)])
	await _unload(main)
	return failures

## The autopilot walks the finished game from the first door to the goal for seeds 1-200. It has no eyes and never steers around
## anything, so a place where the player can be held for good shows up as a run that stops moving (this is how the end of the open
## door leaf was found: on GodotPhysics3D seeds 83, 90, 189 and 197 stopped there, 17 and 60 with other drivers). A run is about
## 3600 physics ticks, so the seeds are split over SWEEP_WORKERS processes (tools/sweep_seeds.gd), each at 8 times real time (the
## engine's limit of 8 physics steps per frame; faster, Jolt warns about running out of jobs). A seed walks the same way in any of them.
func test_autopilot_seed_sweep() -> Array[String]:
	var failures: Array[String] = []
	DirAccess.make_dir_recursive_absolute(_save_dir)
	var per_worker := ceili(float(SWEEP_SEEDS) / SWEEP_WORKERS)
	var workers: Array[Dictionary] = []
	for index in SWEEP_WORKERS:
		var first := index * per_worker + 1
		var last := mini(first + per_worker - 1, SWEEP_SEEDS)
		if first > last:
			continue
		var out := _save_dir.path_join("sweep_%d.txt" % index)
		DirAccess.remove_absolute(out)
		var arguments := ["--headless", "--quiet", "--path", ProjectSettings.globalize_path("res://"), "-s", "res://tools/sweep_seeds.gd", "--", "--from=%d" % first, "--to=%d" % last, "--out=%s" % out]
		var pid := OS.create_process(OS.get_executable_path(), arguments)
		_expect(failures, pid > 0, "could not start the sweep for seeds %d-%d" % [first, last])
		workers.append({"pid": pid, "out": out, "first": first, "last": last})
	while workers.any(func(worker: Dictionary) -> bool: return worker["pid"] > 0 and OS.is_process_running(worker["pid"])):
		await create_timer(1.0).timeout
	var held: Array[String] = []
	var walked := 0
	var longest := 0
	for worker in workers:
		var text := FileAccess.get_file_as_string(worker["out"])
		var lines := text.strip_edges().split("\n", false)
		_expect(failures, lines.size() > 0 and lines[-1] == "done", "the sweep for seeds %d-%d did not finish (%d lines in %s)" % [worker["first"], worker["last"], lines.size(), worker["out"]])
		for line in lines:
			var parts := line.split(" ")
			if parts[0] == "ok":
				walked += 1
				longest = maxi(longest, int(parts[2]))
			elif parts[0] == "held":
				walked += 1
				held.append("seed %s: held in room %s at %s after %s ticks" % [parts[1], parts[2], " ".join(parts.slice(3, parts.size() - 1)), parts[-1]])
		DirAccess.remove_absolute(worker["out"])
	_expect(failures, walked == SWEEP_SEEDS, "%d of %d seeds were walked" % [walked, SWEEP_SEEDS])
	_expect(failures, held.is_empty(), "%d of %d seeds did not reach the goal: %s" % [held.size(), SWEEP_SEEDS, held.slice(0, 4)])
	print("        seeds 1-%d: the longest run took %d ticks (%.1f s of game time)" % [SWEEP_SEEDS, longest, longest / 60.0])
	return failures

#endregion

#region Streaming with the real player

## Per-frame checks while the autopilot walks through the chain.
class Watcher extends RefCounted:
	var level: Node3D
	var pilot: RefCounted
	var failures: Array[String] = []
	var frame := 0
	var max_live := 0
	var max_step := 0.0
	var passed := {} ## Door index -> true once the player crossed its plane.
	var clear_since := {} ## Door index -> frame when the player was clear of the swing.
	var verified_closed := {} ## Door index -> true once checked closed and blocking.
	var checked_current := 0
	var current_since := 0 ## Frame when the player entered the room the player is in.
	var _last_position := Vector3.ZERO

	func _init(watched_level: Node3D, watched_pilot: RefCounted) -> void:
		level = watched_level
		pilot = watched_pilot
		_last_position = (watched_level.player as Node3D).global_position

	func fail(message: String) -> void:
		if failures.size() < 12:
			failures.append("frame %d: %s" % [frame, message])

	func check() -> void:
		frame += 1
		var player: CharacterBody3D = level.player
		var rooms: Dictionary = level.rooms
		var plans: Array = level.chain.plans ## Plans of the step under test, a class of its own.
		max_live = maxi(max_live, rooms.size())
		if rooms.size() > 3:
			fail("%d live rooms" % rooms.size())
		if plans.size() > int(level.current) + 2:
			fail("%d plans made while the player is in room %d" % [plans.size(), level.current])

		# Never pushed through a wall: always inside a live room, on the floor, no jumps in position.
		var inside := false
		for index: int in rooms.keys():
			if plans[index].bounds.grow(0.2).has_point(player.global_position):
				inside = true
		if not inside:
			fail("player at %s is outside every live room" % player.global_position)
		if player.global_position.y < -0.1 or player.global_position.y > 0.3:
			fail("player at height %.2f" % player.global_position.y)
		var step := player.global_position.distance_to(_last_position)
		max_step = maxf(max_step, step)
		if step > 0.2:
			fail("the player moved %.2f m in one physics frame, from %s to %s" % [step, _last_position, player.global_position])
		_last_position = player.global_position

		# The next room exists, and the door is open, before the player passes the door.
		var target: int = pilot.door_index
		if pilot.depth_at(target) >= 0.0 and not passed.has(target):
			passed[target] = true
			if not rooms.has(target + 1):
				fail("room %d did not exist when the player passed door %d" % [target + 1, target])
			elif not rooms[target].door.is_open:
				fail("door %d was closed when the player passed it" % target)

		# The door behind closes once the player is clear of the swing, and then it blocks.
		for index: int in rooms.keys():
			if index >= level.current or verified_closed.has(index):
				continue
			var depth: float = pilot.depth_at(index)
			if depth > 2.6 and not clear_since.has(index):
				clear_since[index] = frame
			if clear_since.has(index) and frame - int(clear_since[index]) > 45:
				verified_closed[index] = true
				var door: Node3D = rooms[index].door
				var door_point := (rooms[index].exit as Marker3D).global_transform
				if door.is_open or absf(door.hinge.rotation.y) > 0.02:
					fail("door %d is still open %d frames after the player cleared it" % [index, frame - int(clear_since[index])])
				var query := PhysicsRayQueryParameters3D.create(door_point * Vector3(-0.3, 1.2, -1.0), door_point * Vector3(-0.3, 1.2, 1.0))
				query.exclude = [player.get_rid()]
				if level.get_world_3d().direct_space_state.intersect_ray(query).is_empty():
					fail("door %d is closed but a ray passes it" % index)

		# Rooms behind the previous one are gone: from the dictionary, and, three frames on, from the tree.
		if level.current != checked_current:
			checked_current = level.current
			current_since = frame
		for index: int in rooms.keys():
			if index < level.current - 1:
				fail("room %d still exists while the player is in room %d" % [index, level.current])
		if frame - current_since == 3:
			var in_tree := 0
			for child in level.get_children():
				if child.get("entrance") != null:
					in_tree += 1
			if in_tree != rooms.size():
				fail("%d room nodes in the tree for %d live rooms" % [in_tree, rooms.size()])

func test_streaming(step: String) -> Array[String]:
	var main := await _load_step(step)
	var level: Node3D = main.get_node("Level")
	var pilot := Autopilot.new(level)
	var watcher := Watcher.new(level, pilot)
	_fast_forward(true)

	_expect(watcher.failures, level.rooms.size() == 1, "%d rooms before the player moved" % level.rooms.size())
	var arrived := await _walk(level, pilot, STREAM_ROOMS, 0, watcher.check)
	_expect(watcher.failures, arrived, "the player did not reach room %d (stuck in room %d after %d frames)" % [STREAM_ROOMS, level.current, watcher.frame])
	# Keep walking so the last door can close behind the player.
	var frames_left := [150]
	await _drive(func() -> bool:
		pilot.physics_step()
		watcher.check()
		frames_left[0] -= 1
		return frames_left[0] <= 0)
	pilot.release()
	_fast_forward(false)

	_expect(watcher.failures, watcher.max_live == 3, "at most %d rooms were live at once, expected 3" % watcher.max_live)
	_expect(watcher.failures, watcher.max_step < 0.2, "the player moved %.2f m in one physics frame" % watcher.max_step)
	_expect(watcher.failures, watcher.passed.size() >= STREAM_ROOMS - 1, "the player passed only %d doors" % watcher.passed.size())
	_expect(watcher.failures, watcher.verified_closed.size() >= STREAM_ROOMS - 2, "only %d doors were seen closing behind the player" % watcher.verified_closed.size())
	var live: Array[Node3D] = _rooms_of(level)
	_expect(watcher.failures, live.size() == level.rooms.size() and live.size() <= 3, "%d room nodes in the tree for %d live rooms" % [live.size(), level.rooms.size()])
	for i in range(live.size() - 1):
		var exit_point: Transform3D = (live[i].get("exit") as Marker3D).global_transform
		var entrance: Transform3D = (live[i + 1].get("entrance") as Marker3D).global_transform
		_expect(watcher.failures, exit_point.origin.distance_to(entrance.origin) < 1e-4 and exit_point.basis.is_equal_approx(entrance.basis), "live rooms %d and %d are not snapped" % [i, i + 1])
	# Walking back builds nothing: the door behind is shut and the plans stay as they are.
	var plan_count: int = level.chain.plans.size()
	var seed_plans := _level_plans(step, level.chain_seed, plan_count, level)
	_expect(watcher.failures, _same_plans(level.chain.plans, seed_plans), "the streamed plans differ from the pure-data chain")
	Input.action_press("move_back")
	await _wait_physics(120)
	Input.action_release("move_back")
	_expect(watcher.failures, level.chain.plans.size() == plan_count, "walking back made %d new plans" % (level.chain.plans.size() - plan_count))
	await _unload(main)
	return watcher.failures

## The pure-data chain of a step, with the level's goal room and lock chance.
func _level_plans(step: String, chain_seed: int, count: int, level: Node3D) -> Array:
	var chain: RefCounted = _chain_script(step).new(chain_seed, level.get("goal_room"), level.get("lock_chance"))
	for i in count:
		chain.next_plan()
	return chain.plans

## Calls its callback once per physics tick, before the player's own tick.
class Driver extends Node:
	signal finished
	var tick: Callable

	func _physics_process(_delta: float) -> void:
		if tick.is_valid() and tick.call():
			tick = Callable()
			finished.emit()

## Runs tick once per physics tick until it returns true. (With Engine.time_scale above 1
## several ticks happen per frame, and `await physics_frame` would only see one of them.)
func _drive(tick: Callable) -> void:
	var driver := Driver.new()
	driver.process_priority = -100
	driver.tick = tick
	root.add_child(driver)
	await driver.finished
	root.remove_child(driver)
	driver.queue_free()

## Walks until the player is in room `goal`. dawdle: ticks of standing still at the start and at every new door.
func _walk(level: Node3D, pilot: RefCounted, goal: int, dawdle: int, on_tick: Callable) -> bool:
	var state := {"budget": 1500 * goal, "wait": dawdle, "target": pilot.door_index}
	await _drive(func() -> bool:
		if state["wait"] > 0:
			state["wait"] -= 1
		else:
			pilot.physics_step()
			if pilot.door_index != state["target"]:
				state["target"] = pilot.door_index
				state["wait"] = dawdle
				pilot.release()
		if on_tick.is_valid():
			on_tick.call()
		state["budget"] -= 1
		return level.current >= goal or state["budget"] <= 0)
	pilot.release()
	return level.current >= goal

## Walks until the run is FINISHED (the player stands on the goal pad). dawdle: ticks of standing
## still at every new door after the first, which makes the run slower. Returns true if it finished.
func _walk_to_finish(level: Node3D, pilot: RefCounted, dawdle := 0, budget := 40000, on_tick := Callable()) -> bool:
	var state := {"budget": budget, "wait": 0, "target": pilot.door_index}
	await _drive(func() -> bool:
		if state["wait"] > 0:
			state["wait"] -= 1
		else:
			pilot.physics_step()
			if pilot.door_index != state["target"]:
				state["target"] = pilot.door_index
				state["wait"] = dawdle
				pilot.release()
		if on_tick.is_valid():
			on_tick.call()
		state["budget"] -= 1
		return level.state == STATE_FINISHED or state["budget"] <= 0)
	pilot.release()
	return level.state == STATE_FINISHED

func test_timing_independence(step: String) -> Array[String]:
	var failures: Array[String] = []
	_fast_forward(true)
	for dawdle: int in [0, 30, 200]:
		var main := await _load_step(step)
		var level: Node3D = main.get_node("Level")
		var pilot := Autopilot.new(level)
		var arrived := await _walk(level, pilot, 7, dawdle, Callable())
		_expect(failures, arrived, "dawdle %d: did not reach room 7" % dawdle)
		var made: Array = level.chain.plans
		_expect(failures, made.size() >= 8, "dawdle %d: only %d plans" % [dawdle, made.size()])
		_expect(failures, _same_plans(made, _level_plans(step, level.chain_seed, made.size(), level)), "dawdle %d: the streamed plans differ from the pure-data chain" % dawdle)
		await _unload(main)
	_fast_forward(false)
	return failures

#endregion

#region Debug map

func test_toggle_map(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step)
	var map: Control = main.get_node("HUD/DebugMap")
	_expect(failures, map.get_parent() is CanvasLayer, "the map is not under a CanvasLayer")
	_expect(failures, map.visible, "the map does not start visible")
	_expect(failures, map.mouse_filter == Control.MOUSE_FILTER_IGNORE, "the map takes mouse input")
	_expect(failures, map.position.is_equal_approx(Vector2(16.0, 16.0)) and map.size.is_equal_approx(Vector2(300.0, 300.0)), "the map is %s at %s, expected 300x300 at the top left" % [map.size, map.position])
	await _action("toggle_debug")
	_expect(failures, not map.visible, "Tab did not hide the map")
	await _action("toggle_debug")
	_expect(failures, map.visible, "Tab did not show the map again")
	await _unload(main)
	return failures

func test_map_reads_data_only(step: String) -> Array[String]:
	var failures: Array[String] = []
	var source := FileAccess.get_file_as_string("res://steps/%s/debug_map.gd" % step)
	for forbidden: String in ["get_node", "get_tree", "find_child", "get_children", "$", "Physics"]:
		_expect(failures, not source.contains(forbidden), "debug_map.gd uses `%s`" % forbidden)
	_expect(failures, source.contains("level.chain.plans") and source.contains("level.rooms"), "debug_map.gd does not draw the plan history")
	return failures

#endregion

#region Step 1: the room counter

func test_counter(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step)
	var level: Node3D = main.get_node("Level")
	var label: Label = main.get_node("HUD/Stats/RoomLabel")
	_expect(failures, label.text == "Room 0 / 20", "the counter reads \"%s\" at the start, expected \"Room 0 / 20\"" % label.text)
	_expect(failures, level.get("goal_room") == 20, "goal_room is %s, expected 20" % level.get("goal_room"))

	# Every room the player enters: the signal comes with the index, and the label has the new text at once.
	var entered: Array[int] = []
	var texts: Array[String] = []
	level.connect("room_entered", func(index: int) -> void:
		entered.append(index)
		texts.append(label.text))
	_fast_forward(true)
	var pilot := Autopilot.new(level)
	var arrived := await _walk(level, pilot, 4, 0, Callable())
	_fast_forward(false)
	_expect(failures, arrived, "the player did not reach room 4")
	_expect(failures, entered == [1, 2, 3, 4], "room_entered was sent for %s, expected [1, 2, 3, 4]" % [entered])
	_expect(failures, texts == ["Room 1 / 20", "Room 2 / 20", "Room 3 / 20", "Room 4 / 20"], "the counter read %s" % [texts])
	_expect(failures, label.text == "Room 4 / 20", "the counter reads \"%s\" in room 4" % label.text)

	await _unload(main)

	# Readable at 1080p and at the project's 720p, inside the screen, clear of the map, on the right.
	main = await _load_step(step)
	for screen_size: Vector2i in [Vector2i(1920, 1080), Vector2i(1280, 720)]:
		await _set_screen(screen_size)
		var stats: Control = main.get_node("HUD/Stats")
		var map: Control = main.get_node("HUD/DebugMap")
		label = main.get_node("HUD/Stats/RoomLabel")
		label.text = "Room 20 / 20" # the widest text the counter shows
		await process_frame
		var screen := Rect2(Vector2.ZERO, Vector2(screen_size))
		var where := "at %dx%d" % [screen_size.x, screen_size.y]
		_expect(failures, label.get_theme_font_size("font_size") >= 32, "the counter font is %d px, too small for 1080p" % label.get_theme_font_size("font_size"))
		_expect(failures, label.get_theme_constant("outline_size") >= 4, "the counter has no outline: it can vanish on a bright wall")
		_expect(failures, screen.encloses(stats.get_global_rect()), "%s: the counter %s is not inside the screen" % [where, stats.get_global_rect()])
		_expect(failures, stats.get_global_rect().end.x <= screen.end.x - 8.0 and stats.get_global_rect().position.y >= 8.0, "%s: the counter is closer than 8 px to the screen corner" % where)
		_expect(failures, stats.get_global_rect().position.x > screen.size.x / 2.0, "%s: the counter is not on the right" % where)
		_expect(failures, not stats.get_global_rect().intersects(map.get_global_rect()), "%s: the counter overlaps the map" % where)
		_expect(failures, label.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT, "the counter is not right aligned")
		_expect(failures, label.get_minimum_size().x <= stats.size.x, "\"Room 20 / 20\" needs %.0f px, the box is %.0f px wide" % [label.get_minimum_size().x, stats.size.x])
	await _unload(main)
	return failures

#endregion

#region Step 2: the goal room in the level

## Goal room 3: the autopilot walks into it and onto the pad.
func test_goal_in_level(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step, true, {"goal_room": SHORT_GOAL})
	var level: Node3D = main.get_node("Level")
	var pilot := Autopilot.new(level)
	_fast_forward(true)
	var arrived := await _walk(level, pilot, SHORT_GOAL, 0, Callable())
	_expect(failures, arrived, "the player did not reach the goal room %d" % SHORT_GOAL)
	var plans: Array = level.chain.plans
	_expect(failures, plans.size() == SHORT_GOAL + 1 and plans[SHORT_GOAL].type == _goal_type(_chain_script(step)), "%d plans, the last is type %d" % [plans.size(), plans[-1].type])
	var room: Node3D = level.rooms[SHORT_GOAL]
	_expect(failures, room.scene_file_path.ends_with("room_goal.tscn"), "room %d is %s" % [SHORT_GOAL, room.scene_file_path])
	_expect(failures, room.get("door") == null and room.get("exit") == null, "the goal room has a door or an exit")
	_expect(failures, level.rooms.size() == 2 and level.rooms.has(SHORT_GOAL - 1), "%d rooms live in the goal room" % level.rooms.size())
	_expect(failures, level.get("goal_room") == SHORT_GOAL and level.chain.goal_index == SHORT_GOAL, "goal_room %s, goal_index %d" % [level.get("goal_room"), level.chain.goal_index])
	_expect(failures, room.get("goal_pad") != null and room.get("goal_pad") == room.get_node("GoalPad"), "the room does not point at its goal pad")

	# On: walk onto the pad. The player steps up onto it and stands inside its edges.
	var pad := room.get_node("GoalPad") as Node3D
	var player: CharacterBody3D = level.player
	var budget := [1200]
	await _drive(func() -> bool:
		pilot.physics_step()
		budget[0] -= 1
		var to_pad := Vector2(player.global_position.x - pad.global_position.x, player.global_position.z - pad.global_position.z)
		return to_pad.length() < 0.4 or level.get("state") == STATE_FINISHED or budget[0] <= 0)
	pilot.release()
	await _wait_physics(10)
	_fast_forward(false)
	var on_pad := Vector2(player.global_position.x - pad.global_position.x, player.global_position.z - pad.global_position.z).abs()
	_expect(failures, on_pad.x < 1.5 and on_pad.y < 1.5, "the player is %s from the middle of the pad" % on_pad)
	_expect(failures, absf(player.global_position.y - 0.12) < 0.02, "the player stands at y = %.3f, the pad top is 0.12" % player.global_position.y)
	await _unload(main)
	return failures

#endregion

#region Step 3: game states

func test_state_enum() -> Array[String]:
	var failures: Array[String] = []
	for step in STEPS:
		var constants := (load("res://steps/%s/level.gd" % step) as GDScript).get_script_constant_map()
		var states: Dictionary = constants.get("State", {})
		_expect(failures, states.get("READY") == STATE_READY and states.get("RUNNING") == STATE_RUNNING and states.get("FINISHED") == STATE_FINISHED and states.size() == 3, "%s: State is %s" % [step, states])
	return failures

func test_states(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step, true, {"goal_room": SHORT_GOAL})
	var level: Node3D = main.get_node("Level")
	var player: CharacterBody3D = level.player
	var changes: Array[int] = []
	level.connect("state_changed", func(new_state: int) -> void: changes.append(new_state))
	var door: Node3D = level.rooms[0].get("door")
	_unlock_by_hand(door) # step 2 locks room 0 for the key tests; the first door is meant to open here
	var state_when_opened: Array[int] = []
	door.connect("opened", func() -> void: state_when_opened.append(level.state))

	# READY in room 0, also while the player walks towards the door.
	_expect(failures, level.state == STATE_READY, "state %d at the start, expected READY" % level.state)
	Input.action_press("move_forward")
	await _wait_physics(30)
	Input.action_release("move_forward")
	_expect(failures, level.state == STATE_READY and changes.is_empty(), "walking in room 0 changed the state to %d" % level.state)

	# RUNNING the moment the first door opens.
	Input.action_press("move_forward")
	for i in 150:
		await physics_frame
		if door.get("is_open"):
			break
	Input.action_release("move_forward")
	_expect(failures, door.get("is_open") and level.state == STATE_RUNNING, "the first door is open, the state is %d" % level.state)
	_expect(failures, state_when_opened == [STATE_RUNNING], "the state was %s when `opened` reached the listeners" % [state_when_opened])
	_expect(failures, changes == [STATE_RUNNING], "state changes %s, expected [RUNNING]" % [changes])
	_expect(failures, not player.get("frozen"), "the player is frozen while running")

	# Standing on the pad before the run is on is nothing: only RUNNING can finish. (Called by hand, state READY.)
	level.set("state", STATE_READY)
	level.call("_on_goal_reached", player)
	_expect(failures, level.state == STATE_READY, "the goal pad finished a run that was not RUNNING")
	level.set("state", STATE_RUNNING)

	# FINISHED when the player steps onto the pad. The other doors on the way do not start anything again.
	_fast_forward(true)
	var pilot := Autopilot.new(level)
	var finished := await _walk_to_finish(level, pilot)
	_fast_forward(false)
	_expect(failures, finished, "the run did not finish (state %d, room %d)" % [level.state, level.current])
	_expect(failures, changes == [STATE_RUNNING, STATE_FINISHED], "state changes %s, expected [RUNNING, FINISHED]" % [changes])
	_expect(failures, level.current == SHORT_GOAL, "finished in room %d, expected %d" % [level.current, SHORT_GOAL])

	# The player stops: frozen, no velocity, and nothing a person can press moves it or turns it.
	await _wait_physics(20)
	_expect(failures, player.get("frozen") == true, "the player is not frozen after the finish")
	_expect(failures, player.velocity == Vector3.ZERO, "the player moves with %s after the finish" % player.velocity)
	var position := player.global_position
	var yaw := player.rotation.y
	var pitch := (player.get_node("Head") as Node3D).rotation.x
	for action: String in ["move_forward", "move_left", "jump", "look_right", "look_down"]:
		Input.action_press(action)
	await _wait_physics(60)
	for action: String in ["move_forward", "move_left", "jump", "look_right", "look_down"]:
		Input.action_release(action)
	_expect(failures, player.global_position.distance_to(position) < 0.001, "the player moved %.3f m after the finish" % player.global_position.distance_to(position))
	_expect(failures, player.rotation.y == yaw and (player.get_node("Head") as Node3D).rotation.x == pitch, "the view turned after the finish")
	_expect(failures, player.velocity == Vector3.ZERO, "the player has velocity %s" % player.velocity)
	_expect(failures, changes.size() == 2, "state changes %s after the finish" % [changes])

	# A player who is in the air at the finish comes down instead of hanging there.
	player.global_position.y += 1.0
	await _wait_physics(60)
	_expect(failures, player.is_on_floor() and player.global_position.y < 0.2, "the frozen player stays in the air (y = %.2f)" % player.global_position.y)

	# The panel: visible at the finish, saying "Finished!".
	var panel: Control = main.get_node("HUD/FinishPanel")
	_expect(failures, panel.visible, "the finish panel is not visible")
	_expect(failures, (main.get_node("HUD/FinishPanel/Rows/FinishTitle") as Label).text == "Finished!", "the panel says \"%s\"" % (main.get_node("HUD/FinishPanel/Rows/FinishTitle") as Label).text)
	await _unload(main)
	return failures

func test_finish_panel(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step, true, {"goal_room": SHORT_GOAL})
	var level: Node3D = main.get_node("Level")
	var panel: Control = main.get_node("HUD/FinishPanel")
	_expect(failures, not panel.visible, "the finish panel is visible before the finish")
	_expect(failures, panel.get_parent() == main.get_node("HUD") and main.get_node("HUD") is CanvasLayer, "the panel is not on the HUD layer")
	_expect(failures, panel.mouse_filter == Control.MOUSE_FILTER_IGNORE, "the panel takes mouse input")

	_fast_forward(true)
	var finished := await _walk_to_finish(level, Autopilot.new(level))
	_fast_forward(false)
	_expect(failures, finished, "the run did not finish")
	_expect(failures, panel.visible, "the panel is hidden after the finish")
	var title: Label = main.get_node("HUD/FinishPanel/Rows/FinishTitle")
	_expect(failures, title.get_theme_font_size("font_size") >= 48, "the title is %d px" % title.get_theme_font_size("font_size"))
	for screen_size: Vector2i in [Vector2i(1920, 1080), Vector2i(1280, 720)]:
		await _set_screen(screen_size)
		var screen := Vector2(screen_size)
		var centre := panel.get_global_rect().get_center()
		_expect(failures, centre.distance_to(screen / 2.0) < 2.0, "%dx%d: the panel is centred at %s, the screen centre is %s" % [screen_size.x, screen_size.y, centre, screen / 2.0])
		_expect(failures, Rect2(Vector2.ZERO, screen).encloses(panel.get_global_rect()), "%dx%d: the panel %s does not fit the screen" % [screen_size.x, screen_size.y, panel.get_global_rect()])
	await _unload(main)
	return failures

#endregion

#region Step 4: the run timer

func test_format_time() -> Array[String]:
	var failures: Array[String] = []
	var cases: Dictionary[float, String] = {
		0.0: "0:00.0",
		0.04: "0:00.0",
		0.1: "0:00.1",
		5.0: "0:05.0",
		42.37: "0:42.3",
		59.96: "0:59.9",
		60.0: "1:00.0",
		125.04: "2:05.0",
		599.99: "9:59.9",
		3600.0: "60:00.0",
	}
	for step in STEPS:
		var hud := load("res://steps/%s/hud.gd" % step) as GDScript
		for seconds in cases:
			var text: String = hud.call("format_time", seconds)
			_expect(failures, text == cases[seconds], "%s: format_time(%s) is \"%s\", expected \"%s\"" % [step, seconds, text, cases[seconds]])
	return failures

func test_timer(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step, true, {"goal_room": SHORT_GOAL})
	var level: Node3D = main.get_node("Level")
	var time_label: Label = main.get_node("HUD/Stats/TimeLabel")
	_expect(failures, level.run_time == 0.0 and time_label.text == "0:00.0", "run_time %s, label \"%s\" at the start" % [level.run_time, time_label.text])
	_expect(failures, time_label.get_theme_font_size("font_size") >= 32, "the timer font is too small for 1080p")

	# READY: the clock does not move, however long the player stands there.
	await _wait_physics(60)
	_expect(failures, level.run_time == 0.0, "the clock moved to %s in READY" % level.run_time)

	# RUNNING: exactly the sum of the physics deltas, whatever the wall clock does. The driver runs before
	# the level on every tick and also stalls the real clock by 25 ms on every fifth tick.
	var door: Node3D = level.rooms[0].get("door")
	door.call("open")
	_expect(failures, level.state == STATE_RUNNING, "opening the door did not start the run")
	var ticks := {"count": 0, "sum": 0.0, "mismatch": 0, "start": 0.0, "wall_start": Time.get_ticks_msec()}
	await _drive(func() -> bool:
		# Before its own tick the level has added every delta that came before this one. (The level
		# had one tick of its own between open() and the driver's first tick: that is the start value.)
		if ticks["count"] == 0:
			ticks["start"] = level.run_time
		if absf(level.run_time - ticks["start"] - ticks["sum"]) > 1e-9:
			ticks["mismatch"] += 1
		ticks["sum"] += _tick_delta()
		ticks["count"] += 1
		if ticks["count"] % 5 == 0:
			OS.delay_msec(25)
		return ticks["count"] >= 121)
	var wall_ms := Time.get_ticks_msec() - int(ticks["wall_start"])
	_expect(failures, ticks["mismatch"] == 0, "the clock differed from the sum of the physics deltas on %d ticks" % ticks["mismatch"])
	_expect(failures, ticks["start"] <= _tick_delta() * 1.5, "the clock was already at %s when the driver started" % ticks["start"])
	_expect(failures, absf(level.run_time - ticks["start"] - 120.0 / 60.0) < 1e-6, "120 physics ticks gave %.6f s, expected 2.0" % (level.run_time - ticks["start"]))
	_expect(failures, wall_ms >= 500, "the test did not stall the wall clock (%d ms)" % wall_ms)

	# The label shows the clock.
	await _wait_physics(2)
	_expect(failures, time_label.text == str(load("res://steps/%s/hud.gd" % step).call("format_time", level.run_time)), "the label says \"%s\" for %.3f s" % [time_label.text, level.run_time])

	# The clock stops at the finish; the panel shows the final time.
	_fast_forward(true)
	var finished := await _walk_to_finish(level, Autopilot.new(level))
	_fast_forward(false)
	_expect(failures, finished, "the run did not finish")
	var at_finish: float = level.run_time
	await _wait_physics(90)
	_expect(failures, level.run_time == at_finish, "the clock kept running after the finish (%.3f to %.3f)" % [at_finish, level.run_time])
	var expected: String = load("res://steps/%s/hud.gd" % step).call("format_time", at_finish)
	_expect(failures, (main.get_node("HUD/FinishPanel/Rows/FinishTime") as Label).text == expected, "the panel shows \"%s\", expected \"%s\"" % [(main.get_node("HUD/FinishPanel/Rows/FinishTime") as Label).text, expected])
	_expect(failures, time_label.text == expected, "the corner shows \"%s\", expected \"%s\"" % [time_label.text, expected])
	await _unload(main)
	return failures

## The delta every node gets in a physics tick: the engine's tick length times the time scale.
func _tick_delta() -> float:
	return Engine.time_scale / float(Engine.physics_ticks_per_second)

#endregion

#region Restart

## R is the same seed again, N is seed + 1 (tutorial 03's steps 5 and 6, here every step). Both reset everything through start().
func test_restart(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step, true, {"goal_room": SHORT_GOAL})
	var level: Node3D = main.get_node("Level")
	var player: CharacterBody3D = level.player
	var room_label: Label = main.get_node("HUD/Stats/RoomLabel")
	var time_label: Label = main.get_node("HUD/Stats/TimeLabel")
	var panel: Control = main.get_node("HUD/FinishPanel")
	_expect(failures, InputMap.has_action("next_seed"), "no next_seed action in the input map")
	var keys: Array[String] = []
	var buttons: Array[int] = []
	for event in InputMap.action_get_events("next_seed"):
		if event is InputEventKey:
			keys.append(OS.get_keycode_string((event as InputEventKey).physical_keycode))
		elif event is InputEventJoypadButton:
			buttons.append((event as InputEventJoypadButton).button_index)
	_expect(failures, keys == ["N"] and buttons == [JOY_BUTTON_RIGHT_SHOULDER], "next_seed is %s and %s, expected N and the right shoulder" % [keys, buttons])

	# A run in progress: two rooms in, the clock running.
	_fast_forward(true)
	var pilot := Autopilot.new(level)
	var arrived := await _walk(level, pilot, 2, 0, Callable())
	_fast_forward(false)
	await _wait_physics(10)
	_expect(failures, arrived and level.state == STATE_RUNNING and level.run_time > 1.5, "the run did not get going (state %d, %.1f s)" % [level.state, level.run_time])
	var first_run: Array = level.chain.plans.duplicate()

	# R: the same seed, a fresh run.
	await _action("regenerate")
	await _wait_physics(10)
	_expect(failures, level.chain_seed == 42, "seed is %d after R, expected 42" % level.chain_seed)
	failures.append_array(_fresh_run_problems(step, main, 42))
	_expect(failures, _same_plans(level.chain.plans, first_run.slice(0, 1)), "the first plan after R is not the same room 0")

	# The same seed, the same run: walk it again, the plans are the ones of the first run.
	_fast_forward(true)
	pilot = Autopilot.new(level)
	arrived = await _walk(level, pilot, 2, 0, Callable())
	_fast_forward(false)
	_expect(failures, arrived, "the second run did not reach room 2")
	var second_run: Array = level.chain.plans
	var shared := mini(first_run.size(), second_run.size())
	_expect(failures, shared >= 3 and _same_plans(first_run.slice(0, shared), second_run.slice(0, shared)), "R did not give the same rooms")

	# N: seed + 1.
	await _action("next_seed")
	await _wait_physics(10)
	_expect(failures, level.chain_seed == 43, "seed is %d after N, expected 43" % level.chain_seed)
	failures.append_array(_fresh_run_problems(step, main, 43))
	await _action("next_seed")
	await _wait_physics(10)
	_expect(failures, level.chain_seed == 44, "second N: seed is %d, expected 44" % level.chain_seed)
	failures.append_array(_fresh_run_problems(step, main, 44))
	await _action("regenerate")
	await _wait_physics(10)
	_expect(failures, level.chain_seed == 44, "R after N: seed is %d, expected 44" % level.chain_seed)

	# After a finish: R and N both give the player back.
	_fast_forward(true)
	pilot = Autopilot.new(level)
	var finished := await _walk_to_finish(level, pilot)
	_fast_forward(false)
	_expect(failures, finished and panel.visible and player.get("frozen") == true, "the run did not finish before the restart")
	await _action("regenerate")
	await _wait_physics(10)
	failures.append_array(_fresh_run_problems(step, main, 44))
	_fast_forward(true)
	finished = await _walk_to_finish(level, Autopilot.new(level))
	_fast_forward(false)
	_expect(failures, finished, "the second run did not finish")
	await _action("next_seed")
	await _wait_physics(10)
	failures.append_array(_fresh_run_problems(step, main, 45))
	# And the new run plays: input works again.
	var before := player.global_position
	Input.action_press("move_forward")
	await _wait_physics(20)
	Input.action_release("move_forward")
	_expect(failures, player.global_position.distance_to(before) > 1.0, "the player does not move after the restart")
	_expect(failures, room_label.text == "Room 0 / %d" % SHORT_GOAL and time_label.text == "0:00.0", "the HUD reads \"%s\" and \"%s\" after the restart" % [room_label.text, time_label.text])
	await _unload(main)
	return failures

## What a fresh run looks like, from any earlier state: seed, plans, rooms, counter, clock, state, player, panel.
func _fresh_run_problems(step: String, main: Node, expected_seed: int) -> Array[String]:
	var problems: Array[String] = []
	var level: Node3D = main.get_node("Level")
	var player: CharacterBody3D = level.player
	var label := "%s seed %d" % [step, expected_seed]
	_expect(problems, level.chain_seed == expected_seed, "%s: seed is %d" % [label, level.chain_seed])
	_expect(problems, _same_plans(level.chain.plans, _level_plans(step, expected_seed, 1, level)), "%s: room 0 is not the pure-data chain's" % label)
	_expect(problems, level.rooms.size() == 1 and level.rooms.has(0) and level.current == 0, "%s: %d live rooms, current %d" % [label, level.rooms.size(), level.current])
	_expect(problems, _rooms_of(level).size() == 1, "%s: %d room nodes in the tree" % [label, _rooms_of(level).size()])
	_expect(problems, level.state == STATE_READY and level.run_time == 0.0, "%s: state %d, clock %s" % [label, level.state, level.run_time])
	_expect(problems, not level.rooms[0].door.is_open, "%s: door 0 is open" % label)
	_expect(problems, player.global_position.distance_to(Vector3(0.0, 0.0, 3.5)) < 0.05 and player.is_on_floor(), "%s: the player is at %s" % [label, player.global_position])
	_expect(problems, player.get("frozen") == false and player.velocity == Vector3.ZERO, "%s: the player is frozen or moving" % label)
	_expect(problems, (main.get_node("HUD/Stats/RoomLabel") as Label).text == "Room 0 / %d" % level.goal_room, "%s: the counter reads \"%s\"" % [label, (main.get_node("HUD/Stats/RoomLabel") as Label).text])
	_expect(problems, (main.get_node("HUD/Stats/TimeLabel") as Label).text == "0:00.0", "%s: the clock reads \"%s\"" % [label, (main.get_node("HUD/Stats/TimeLabel") as Label).text])
	_expect(problems, not (main.get_node("HUD/FinishPanel") as Control).visible, "%s: the finish panel is still up" % label)
	if level.get("new_best") != null:
		_expect(problems, level.get("new_best") == false, "%s: new_best is still set" % label)
	if level.get("keys") != null:
		_expect(problems, level.keys == 0 and (main.get_node("HUD/Stats/KeysLabel") as Label).text == "Keys 0", "%s: keys %d, label \"%s\"" % [label, level.keys, (main.get_node("HUD/Stats/KeysLabel") as Label).text])
		_expect(problems, _keys_in(level.rooms[0]).is_empty(), "%s: %d keys in room 0" % [label, _keys_in(level.rooms[0]).size()])
	return problems

## A restart pressed with the player standing in the first door's trigger. Under Jolt a teleported player is
## still at the old place for the physics step right after the teleport: a trigger that is awake in that step reports the
## player, and the new room 0 opens its door at once (room 1 is built, the clock runs). The restart is delivered the way a
## key press is: buffered, and handled at the start of the next frame.
func test_restart_at_the_door(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step, true, {"goal_room": SHORT_GOAL})
	var level: Node3D = main.get_node("Level")
	var player: CharacterBody3D = level.player
	var source := FileAccess.get_file_as_string("res://steps/%s/level.gd" % step)
	for action: StringName in [&"regenerate", &"next_seed"]:
		if not source.contains("\"%s\"" % action):
			continue # every step has N
		Input.action_press("move_forward")
		await _wait_physics(100)
		Input.action_release("move_forward")
		await _wait_physics(5)
		var old_trigger: Area3D = level.rooms[0].door.get_node("Trigger")
		_expect(failures, old_trigger.overlaps_body(player), "%s: the player is not in the first door's trigger (at %s)" % [action, player.global_position])
		await _press(action)
		var door: Node3D = level.rooms[0].door
		var reports: Array[int] = [0]
		(door.get_node("Trigger") as Area3D).body_entered.connect(func(_body: Node3D) -> void: reports[0] += 1)
		var woke := false
		for i in 6:
			await physics_frame
			woke = woke or reports[0] > 0 or door.is_open or level.rooms.size() > 1 or level.get("state") not in [null, STATE_READY]
		_expect(failures, not woke, "%s: the new room 0 saw the player at the old place: %d trigger reports, door open %s, %d rooms, state %s" % [action, reports[0], door.is_open, level.rooms.size(), level.get("state")])
		await _wait_physics(5)
	await _unload(main)
	return failures

## The reset has one home. Every statement that undoes a run is in start(), and only there.
func test_reset_in_one_place() -> Array[String]:
	var failures: Array[String] = []
	for step in STEPS:
		var source := FileAccess.get_file_as_string("res://steps/%s/level.gd" % step)
		var start_at := source.find("func start() -> void:")
		var start_end := source.find("\nfunc ", start_at + 1)
		var start_body := source.substr(start_at, start_end - start_at)
		var statements: Array[String] = ["rooms.clear()", "current = 0", "run_time = 0.0", "chain = Chain.new(", "_set_state(State.READY)"]
		statements.append("new_best = false")
		statements.append("keys = 0")
		for statement in statements:
			_expect(failures, start_body.contains(statement), "%s: start() does not contain `%s`" % [step, statement])
			_expect(failures, source.count(statement) == 1, "%s: `%s` appears %d times in level.gd, expected once (in start())" % [step, statement, source.count(statement)])
		_expect(failures, start_body.contains("room_entered.emit(current)"), "%s: start() does not announce room 0" % step)
		_expect(failures, start_body.contains("keys_changed.emit(keys)"), "%s: start() does not announce the keys" % step)
		# The input only picks the seed and calls start().
		var input_at := source.find("func _unhandled_input(")
		var input_end := source.find("\nfunc ", input_at + 1)
		var input_body := source.substr(input_at, input_end - input_at)
		_expect(failures, input_body.count("start()") == 2 and input_body.count("chain_seed += 1") == 1, "%s: _unhandled_input does more than pick a seed and call start()" % step)
		for statement: String in ["rooms.clear()", "run_time", "player.", "current = ", "_set_state"]:
			_expect(failures, not input_body.contains(statement), "%s: _unhandled_input touches `%s`" % [step, statement])
	return failures

#endregion

#region Step 6: best times

func test_best_round_trip() -> Array[String]:
	var failures: Array[String] = []
	var path := _fresh_save_path()
	var times := BestTimes.new(path)
	_expect(failures, times.best(42) == BestTimes.NO_TIME, "a new list has a time for seed 42")
	_expect(failures, times.submit(42, 39.8167), "the first time of a seed is a best")
	_expect(failures, FileAccess.file_exists(path), "no file after the first submit")
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	_expect(failures, data is Dictionary, "the file is not a JSON object")
	if data is Dictionary:
		_expect(failures, (data as Dictionary).get("formatVersion") == 1.0, "formatVersion is %s" % (data as Dictionary).get("formatVersion"))
		var best_times: Dictionary = (data as Dictionary).get("bestTimes", {})
		_expect(failures, best_times == {"42": 39.817}, "bestTimes is %s, expected {\"42\": 39.817}" % [best_times])
	var again := BestTimes.new(path)
	_expect(failures, again.best(42) == 39.817, "reloaded: %s" % again.best(42))
	_expect(failures, again.best(43) == BestTimes.NO_TIME, "seed 43 has a time")
	_expect(failures, times.submit(-5, 12.0) and BestTimes.new(path).best(-5) == 12.0, "a negative seed does not round trip")
	_expect(failures, BestTimes.new(path).best(42) == 39.817, "seed 42 was lost when seed -5 was saved")
	return failures

func test_best_only_faster() -> Array[String]:
	var failures: Array[String] = []
	var path := _fresh_save_path()
	var times := BestTimes.new(path)
	times.submit(42, 50.0)
	_expect(failures, not times.submit(42, 60.0), "a slower time counted as a best")
	_expect(failures, not times.submit(42, 50.0), "an equal time counted as a best")
	_expect(failures, not times.submit(42, 50.0004), "a time that rounds to the same millisecond counted as a best")
	_expect(failures, times.best(42) == 50.0, "the best changed to %s" % times.best(42))
	_expect(failures, BestTimes.new(path).best(42) == 50.0, "the file changed with a slower time")
	_expect(failures, times.submit(42, 49.999), "a faster time did not count")
	_expect(failures, times.best(42) == 49.999 and BestTimes.new(path).best(42) == 49.999, "the faster time was not kept")
	_expect(failures, times.submit(43, 90.0) and times.best(43) == 90.0 and times.best(42) == 49.999, "seeds are not independent")
	_expect(failures, BestTimes.new(path).best(43) == 90.0 and BestTimes.new(path).best(42) == 49.999, "the file lost a seed")
	return failures

func test_best_missing_file() -> Array[String]:
	var failures: Array[String] = []
	var path := _fresh_save_path()
	var times := BestTimes.new(path)
	_expect(failures, times.best(1) == BestTimes.NO_TIME and times.best(42) == BestTimes.NO_TIME, "an empty list has times")
	_expect(failures, not FileAccess.file_exists(path) and not FileAccess.file_exists(path + ".bad") and not FileAccess.file_exists(path + ".tmp"), "loading a missing file wrote something")
	return failures

func test_best_damaged_file() -> Array[String]:
	var failures: Array[String] = []
	var damaged: Array[String] = [
		"{\"formatVersion\": 1, \"bestTimes\": {\"42\": 39.", # cut off in the middle of a write
		"", # empty
		"[1, 2, 3]", # valid JSON, not an object
		"\"just text\"",
		"42",
		"not json at all <<<",
		"{\"formatVersion\": 1, \"bestTimes\": [1, 2]}", # an object, but the list is not one
		"{\"formatVersion\": 1, \"bestTimes\": \"x\"}",
	]
	for text in damaged:
		var path := _fresh_save_path()
		_write_file(path, text)
		var times := BestTimes.new(path) # must not crash
		_expect(failures, times.best(42) == BestTimes.NO_TIME, "damaged %s: a time was invented" % [text])
		_expect(failures, FileAccess.file_exists(path + ".bad") and FileAccess.get_file_as_string(path + ".bad") == text, "damaged %s: not kept as .bad, unchanged" % [text])
		_expect(failures, not FileAccess.file_exists(path), "damaged %s: the damaged file is still in place" % [text])
		# The list works again, and the damaged copy stays as it was.
		_expect(failures, times.submit(42, 41.5) and BestTimes.new(path).best(42) == 41.5, "damaged %s: a new time was not saved" % [text])
		_expect(failures, FileAccess.get_file_as_string(path + ".bad") == text, "damaged %s: .bad changed when the new list was saved" % [text])
	return failures

func test_best_unknown_keys() -> Array[String]:
	var failures: Array[String] = []
	var path := _fresh_save_path()
	_write_file(path, JSON.stringify({
		"formatVersion": 3,
		"writtenBy": "9.9.9",
		"settings": {"volume": 0.5, "names": ["a", "b"]},
		"bestTimes": {"7": 12.5, "42": 50, "legacy": "n/a", "8": null, "9": "fast", "10": [1], "11": true},
	}))
	var times := BestTimes.new(path)
	_expect(failures, times.best(7) == 12.5 and times.best(42) == 50.0, "known times: %s and %s" % [times.best(7), times.best(42)])
	_expect(failures, times.best(8) == BestTimes.NO_TIME and times.best(9) == BestTimes.NO_TIME and times.best(10) == BestTimes.NO_TIME and times.best(11) == BestTimes.NO_TIME, "an odd entry counted as a time")
	_expect(failures, not times.submit(42, 51.0), "a slower time replaced an int time")
	_expect(failures, times.submit(42, 40.0), "a faster time did not replace an int time")
	_expect(failures, times.submit(9, 30.0), "a time for a seed with an odd entry was not stored")
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	_expect(failures, data.get("writtenBy") == "9.9.9", "writtenBy is gone")
	_expect(failures, data.get("settings") == {"volume": 0.5, "names": ["a", "b"]}, "settings is %s" % [data.get("settings")])
	_expect(failures, data.get("formatVersion") == 3.0, "the format version went from 3 to %s" % data.get("formatVersion"))
	var best: Dictionary = data.get("bestTimes", {})
	_expect(failures, best.get("7") == 12.5 and best.get("42") == 40.0 and best.get("9") == 30.0, "bestTimes is %s" % [best])
	_expect(failures, best.get("legacy") == "n/a" and best.has("8") and best.get("8") == null and best.get("10") == [1.0] and best.get("11") == true, "odd entries did not survive: %s" % [best])
	_expect(failures, best.size() == 7, "bestTimes has %d entries, expected 7" % best.size())
	# A file without a version gets the version of this writer.
	var plain := _fresh_save_path()
	_write_file(plain, "{\"bestTimes\": {\"1\": 5.0}}")
	var plain_times := BestTimes.new(plain)
	plain_times.submit(2, 6.0)
	var plain_data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(plain))
	_expect(failures, plain_data.get("formatVersion") == 1.0 and (plain_data.get("bestTimes") as Dictionary).size() == 2, "a file without a version: %s" % [plain_data])
	return failures

func test_best_atomic_write() -> Array[String]:
	var failures: Array[String] = []
	var path := _fresh_save_path()
	# A temp file left behind by a crash does no harm.
	_write_file(path + ".tmp", "{\"half written")
	var times := BestTimes.new(path)
	_expect(failures, times.best(42) == BestTimes.NO_TIME, "a stale temp file was read")
	_expect(failures, times.submit(42, 33.0), "the save failed with a stale temp file")
	_expect(failures, not FileAccess.file_exists(path + ".tmp"), "the temp file is still there after the save")
	_expect(failures, BestTimes.new(path).best(42) == 33.0, "the saved file does not load")
	# The old file is replaced whole: a second save still leaves a loadable file and no temp file.
	times.submit(42, 32.0)
	_expect(failures, not FileAccess.file_exists(path + ".tmp") and BestTimes.new(path).best(42) == 32.0, "the second save left a broken state")
	# The source goes temp file first, then rename (not delete then move, not a write in place).
	var source := FileAccess.get_file_as_string("res://steps/step_05_clear_paths/best_times.gd")
	_expect(failures, source.contains("\".tmp\"") and source.contains("rename_absolute") and source.contains("flush()"), "best_times.gd does not write a temp file, flush it and rename it")
	_expect(failures, not source.contains("remove_absolute") and not source.contains("DirAccess.remove"), "best_times.gd deletes a file")
	return failures

func test_best_write_failure() -> Array[String]:
	var failures: Array[String] = []
	var path := _save_dir.path_join("no-such-folder").path_join("best_times.json")
	var times := BestTimes.new(path)
	_expect(failures, times.submit(42, 40.0), "a failed save lost the time")
	_expect(failures, times.best(42) == 40.0, "the time is not kept in memory after a failed save")
	_expect(failures, not FileAccess.file_exists(path), "a file appeared in a folder that does not exist")
	return failures

## The label in the corner for the current seed, and how N changes it.
func test_best_label() -> Array[String]:
	var failures: Array[String] = []
	var path := _fresh_save_path()
	_write_file(path, JSON.stringify({"formatVersion": 1, "bestTimes": {"42": 39.8, "43": 70.25}}))
	var main := await _load_step(FINAL_STEP, true, {"save_path": path})
	var level: Node3D = main.get_node("Level")
	var label: Label = main.get_node("HUD/Stats/BestLabel")
	_expect(failures, label.text == "Best 0:39.8", "the label reads \"%s\" for seed 42" % label.text)
	_expect(failures, label.get_theme_font_size("font_size") >= 32 and label.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT, "the best label is not like the other labels")
	await _action("next_seed")
	await _wait_physics(5)
	_expect(failures, level.chain_seed == 43 and label.text == "Best 1:10.2", "seed %d: the label reads \"%s\", expected \"Best 1:10.2\"" % [level.chain_seed, label.text])
	await _action("next_seed")
	await _wait_physics(5)
	_expect(failures, level.chain_seed == 44 and label.text == "Best -:--.-", "seed %d: the label reads \"%s\", expected \"Best -:--.-\"" % [level.chain_seed, label.text])
	await _action("regenerate")
	await _wait_physics(5)
	_expect(failures, level.chain_seed == 44 and label.text == "Best -:--.-", "R changed the label to \"%s\"" % label.text)
	# All three labels fit the right side of the screen without touching the map.
	for screen_size: Vector2i in [Vector2i(1920, 1080), Vector2i(1280, 720)]:
		await _set_screen(screen_size)
		var stats: Control = main.get_node("HUD/Stats")
		var screen := Rect2(Vector2.ZERO, Vector2(screen_size))
		_expect(failures, screen.encloses(stats.get_global_rect()) and not stats.get_global_rect().intersects((main.get_node("HUD/DebugMap") as Control).get_global_rect()), "%dx%d: the stats box %s does not fit" % [screen_size.x, screen_size.y, stats.get_global_rect()])
	await _unload(main)
	return failures

func test_best_in_level() -> Array[String]:
	var failures: Array[String] = []

	# 1. Slower than the saved time: no "New best!", the file is untouched.
	var path := _fresh_save_path()
	var before := JSON.stringify({"formatVersion": 1, "settings": {"x": 1}, "bestTimes": {"42": 0.5}}, "\t")
	_write_file(path, before)
	var main := await _load_step(FINAL_STEP, true, {"save_path": path, "goal_room": SHORT_GOAL})
	var level: Node3D = main.get_node("Level")
	var new_best: Label = main.get_node("HUD/FinishPanel/Rows/NewBest")
	_expect(failures, not new_best.visible, "\"New best!\" is visible before the finish")
	_fast_forward(true)
	var finished := await _walk_to_finish(level, Autopilot.new(level))
	_fast_forward(false)
	_expect(failures, finished, "run 1 did not finish")
	_expect(failures, level.new_best == false and not new_best.visible, "a slower run says \"New best!\"")
	_expect(failures, FileAccess.get_file_as_string(path) == before, "a slower run changed the file")
	_expect(failures, (main.get_node("HUD/Stats/BestLabel") as Label).text == "Best 0:00.5", "the label reads \"%s\"" % (main.get_node("HUD/Stats/BestLabel") as Label).text)
	await _unload(main)

	# 2. Faster than the saved time: "New best!", saved, unknown keys kept.
	path = _fresh_save_path()
	_write_file(path, JSON.stringify({"formatVersion": 1, "settings": {"x": 1}, "bestTimes": {"42": 999.0, "7": 5.5}}))
	main = await _load_step(FINAL_STEP, true, {"save_path": path, "goal_room": SHORT_GOAL})
	level = main.get_node("Level")
	new_best = main.get_node("HUD/FinishPanel/Rows/NewBest")
	_fast_forward(true)
	finished = await _walk_to_finish(level, Autopilot.new(level))
	_fast_forward(false)
	_expect(failures, finished, "run 2 did not finish")
	var run_time: float = level.run_time
	_expect(failures, level.new_best == true and new_best.visible and new_best.text == "New best!", "a faster run does not say \"New best!\"")
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	_expect(failures, absf((saved.bestTimes as Dictionary).get("42", 0.0) - run_time) < 0.0006, "saved %s, the run took %.4f s" % [(saved.bestTimes as Dictionary).get("42"), run_time])
	_expect(failures, (saved.bestTimes as Dictionary).get("7") == 5.5 and saved.get("settings") == {"x": 1.0}, "other entries did not survive: %s" % [saved])
	var best_text := "Best " + str(load("res://steps/step_05_clear_paths/hud.gd").call("format_time", BestTimes.new(path).best(42)))
	_expect(failures, (main.get_node("HUD/Stats/BestLabel") as Label).text == best_text, "the label reads \"%s\", expected \"%s\"" % [(main.get_node("HUD/Stats/BestLabel") as Label).text, best_text])
	var first_best := BestTimes.new(path).best(42)

	# 3. Restart, the same seed again but slower (the player waits at every door): not a best, the file stays.
	await _action("regenerate")
	await _wait_physics(10)
	_expect(failures, not new_best.visible and level.new_best == false, "\"New best!\" is still up after R")
	_fast_forward(true)
	finished = await _walk_to_finish(level, Autopilot.new(level), 90)
	_fast_forward(false)
	_expect(failures, finished, "run 3 did not finish")
	_expect(failures, level.run_time > run_time + 2.0, "the slow run took %.1f s, the first %.1f s" % [level.run_time, run_time])
	_expect(failures, level.new_best == false and not new_best.visible, "a slower second run says \"New best!\"")
	_expect(failures, BestTimes.new(path).best(42) == first_best, "the slower run replaced the best")

	# 4. Another seed has its own list: its first run is a best, and seed 42 is not touched.
	await _action("next_seed")
	await _wait_physics(10)
	_expect(failures, level.chain_seed == 43 and (main.get_node("HUD/Stats/BestLabel") as Label).text == "Best -:--.-", "seed 43 starts with a best time")
	_fast_forward(true)
	finished = await _walk_to_finish(level, Autopilot.new(level))
	_fast_forward(false)
	_expect(failures, finished and level.new_best == true and new_best.visible, "the first run of seed 43 is not a new best")
	_expect(failures, BestTimes.new(path).best(43) > 0.0 and BestTimes.new(path).best(42) == first_best, "seed 43 or seed 42 is wrong in the file")
	await _unload(main)
	return failures

#endregion

#region Full run

func test_full_run() -> Array[String]:
	var failures: Array[String] = []
	var path := _fresh_save_path()
	var main := await _load_step(FINAL_STEP, true, {"save_path": path})
	var level: Node3D = main.get_node("Level")
	var pilot := Autopilot.new(level)
	var changes: Array[int] = []
	level.connect("state_changed", func(new_state: int) -> void: changes.append(new_state))
	var key_counts: Array[int] = []
	level.connect("keys_changed", func(count: int) -> void: key_counts.append(count))
	var blocked := [0]
	level.connect("door_blocked", func() -> void: blocked[0] += 1)
	var built := [_props_in(level.rooms[0]).size()] # the props the rooms were built with, room 0 first
	level.connect("room_entered", func(index: int) -> void: built[0] += _props_in(level.rooms[index]).size())
	var vault_height := [0.0] # the highest the player stood in a vault: over the platform
	var on_tick := func() -> void:
		if level.chain.plans[level.current].type == Chain.Type.VAULT:
			vault_height[0] = maxf(vault_height[0], level.player.global_position.y)
	_expect(failures, level.chain_seed == 42 and level.goal_room == 20, "seed %d, goal room %d, expected 42 and 20" % [level.chain_seed, level.goal_room])
	_fast_forward(true)
	var started := Time.get_ticks_msec()
	var finished := await _walk_to_finish(level, pilot, 0, 60 * 60 * 5, on_tick)
	_fast_forward(false)
	var wall := (Time.get_ticks_msec() - started) / 1000.0
	_expect(failures, finished, "the run did not finish (state %d, room %d, %.1f s)" % [level.state, level.current, level.run_time])
	_expect(failures, changes == [STATE_RUNNING, STATE_FINISHED], "state changes %s" % [changes])
	_expect(failures, level.current == 20 and level.chain.goal_index == 20 and level.chain.plans.size() == 21, "finished in room %d with %d plans (goal_index %d)" % [level.current, level.chain.plans.size(), level.chain.goal_index])
	var run_time: float = level.run_time
	# 20 rooms of 10 to 18 m at 5 m/s, three of them with a detour for the key: well under two minutes for the autopilot, a person takes longer.
	_expect(failures, run_time > 30.0 and run_time < 120.0, "the run took %.1f s" % run_time)
	var locked: Array[int] = []
	var vaults: Array[int] = []
	for plan: Object in level.chain.plans:
		if plan.locked:
			locked.append(plan.index)
		if plan.type == Chain.Type.VAULT:
			vaults.append(plan.index)
	_expect(failures, locked == SEED_42_LOCKS, "seed 42 locks rooms %s, expected %s" % [locked, SEED_42_LOCKS])
	_expect(failures, vaults == SEED_42_VAULTS, "seed 42 has vaults %s, expected %s" % [vaults, SEED_42_VAULTS])
	_expect(failures, key_counts == [1, 0, 1, 0, 1, 0] and level.keys == 0, "the keys went %s: every locked room needs its key picked up (1) and used up (0)" % [key_counts])
	_expect(failures, blocked[0] == 0, "the autopilot was refused at %d doors: it should fetch the key first" % blocked[0])
	_expect(failures, built[0] >= 40, "only %d props were built on the way: the rooms are bare" % built[0])
	_expect(failures, vault_height[0] > 0.1, "the player never climbed the vault's platform (highest %.3f m)" % vault_height[0])
	print("        full run, seed 42: %.2f s of game time (%d physics ticks), %.1f s of wall time at %dx, %d props in the rooms on the way, vaults %s, locks %s" % [run_time, roundi(run_time * 60.0), wall, SPEED_UP, built[0], vaults, locked])

	var panel: Control = main.get_node("HUD/FinishPanel")
	var format_time: GDScript = load("res://steps/step_05_clear_paths/hud.gd")
	_expect(failures, panel.visible and (main.get_node("HUD/FinishPanel/Rows/FinishTitle") as Label).text == "Finished!", "the finish panel is not up")
	_expect(failures, (main.get_node("HUD/FinishPanel/Rows/FinishTime") as Label).text == str(format_time.call("format_time", run_time)), "the panel time is \"%s\"" % (main.get_node("HUD/FinishPanel/Rows/FinishTime") as Label).text)
	_expect(failures, (main.get_node("HUD/FinishPanel/Rows/NewBest") as Label).visible and level.new_best == true, "no \"New best!\" for the first run")
	_expect(failures, (main.get_node("HUD/Stats/RoomLabel") as Label).text == "Room 20 / 20", "the counter reads \"%s\"" % (main.get_node("HUD/Stats/RoomLabel") as Label).text)
	_expect(failures, (main.get_node("HUD/Stats/BestLabel") as Label).text == "Best " + str(format_time.call("format_time", run_time)), "the best label reads \"%s\"" % (main.get_node("HUD/Stats/BestLabel") as Label).text)
	_expect(failures, level.player.get("frozen") == true and level.player.velocity == Vector3.ZERO, "the player is not stopped")
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	_expect(failures, saved is Dictionary and ((saved as Dictionary).get("bestTimes", {}) as Dictionary).has("42"), "no time saved for seed 42: %s" % [saved])
	if saved is Dictionary:
		_expect(failures, absf(((saved as Dictionary).bestTimes as Dictionary).get("42", 0.0) - run_time) < 0.0006, "saved %s, the run took %.4f s" % [((saved as Dictionary).bestTimes as Dictionary).get("42"), run_time])
	_expect(failures, not level.rooms.is_empty() and level.rooms.size() <= 2, "%d rooms live at the finish" % level.rooms.size())

	# R: the same seed, same rooms again; the saved time is still there.
	await _action("regenerate")
	await _wait_physics(10)
	_expect(failures, level.chain_seed == 42 and level.state == STATE_READY and level.run_time == 0.0 and not panel.visible, "R after the finish did not start a clean run")
	_expect(failures, (main.get_node("HUD/Stats/BestLabel") as Label).text == "Best " + str(format_time.call("format_time", run_time)), "the best time is gone after R: \"%s\"" % (main.get_node("HUD/Stats/BestLabel") as Label).text)
	await _unload(main)
	return failures

#endregion

#region Graybox standard: closed rooms, materials, lighting

func test_materials() -> Array[String]:
	var failures: Array[String] = []
	var grid := load(MATERIAL_DIR + "grid_1m.png") as Texture2D
	_expect(failures, grid != null and grid.get_size() == Vector2(256.0, 256.0), "grid_1m.png is not a 256x256 texture")
	if grid == null:
		return failures

	# One tile is 1 m: a dark line on the tile border, a fainter one at 0.5 m, the same on both axes.
	var image := grid.get_image()
	var fill := image.get_pixel(100, 100)
	var half_line := image.get_pixel(127, 100)
	var tile_line := image.get_pixel(0, 100)
	_expect(failures, tile_line.r < half_line.r and half_line.r < fill.r, "grid lines: tile %.2f, half %.2f, fill %.2f" % [tile_line.r, half_line.r, fill.r])
	_expect(failures, image.get_pixel(255, 100) == tile_line and image.get_pixel(100, 0) == tile_line and image.get_pixel(100, 255) == tile_line, "the tile border line is not centred on the border")
	_expect(failures, image.get_pixel(100, 127) == half_line and image.get_pixel(100, 128) == half_line and image.get_pixel(128, 100) == half_line, "the 0.5 m line is not the same on both axes")
	_expect(failures, image.has_mipmaps(), "the grid is imported without mipmaps: it would shimmer at a distance")

	# Neutral gray floor, walls and ceiling in the midtone range (50-100 percent), floor lighter than walls.
	var targets: Dictionary[String, float] = {"floor": 0.70, "wall": 0.55, "ceiling": 0.60}
	var fills: Dictionary[String, Color] = {}
	for material_name: String in targets:
		var material := load(MATERIAL_DIR + material_name + ".tres") as StandardMaterial3D
		_expect(failures, material != null, "%s.tres is not a StandardMaterial3D" % material_name)
		if material == null:
			continue
		var shown := (material.albedo_color.srgb_to_linear() * fill.srgb_to_linear()).linear_to_srgb()
		fills[material_name] = shown
		_expect(failures, material.albedo_texture != null and material.albedo_texture.resource_path == grid.resource_path, "%s.tres does not use the shared grid" % material_name)
		_expect(failures, material.uv1_triplanar and material.uv1_world_triplanar, "%s.tres is not world triplanar" % material_name)
		_expect(failures, material.uv1_scale.is_equal_approx(Vector3.ONE), "%s.tres: uv1_scale %s, one tile must be 1 m (scale 1)" % [material_name, material.uv1_scale])
		_expect(failures, material.shading_mode == BaseMaterial3D.SHADING_MODE_PER_PIXEL, "%s.tres is unlit" % material_name)
		_expect(failures, material.texture_filter == BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC, "%s.tres: texture_filter %d" % [material_name, material.texture_filter])
		_expect(failures, shown.r >= 0.5 and shown.r <= 1.0, "%s.tres: albedo %.2f is outside 50-100 percent" % [material_name, shown.r])
		_expect(failures, absf(shown.r - targets[material_name]) < 0.02, "%s.tres: albedo %.3f, expected about %.2f" % [material_name, shown.r, targets[material_name]])
		_expect(failures, absf(shown.r - shown.g) < 0.01 and absf(shown.r - shown.b) < 0.01, "%s.tres is not neutral gray" % material_name)
	if fills.size() == 3:
		_expect(failures, fills["floor"].r > fills["wall"].r + 0.1, "the floor must be clearly lighter than the walls (%.2f vs %.2f)" % [fills["floor"].r, fills["wall"].r])

	# The door and the goal are the warm accents, and brighter than the gray room around them (squint test).
	var wall_light := 0.0
	if fills.has("wall"):
		wall_light = (load(MATERIAL_DIR + "wall.tres") as StandardMaterial3D).albedo_color.srgb_to_linear().get_luminance() * fill.srgb_to_linear().r
	for accent: String in ["door", "goal", "key"]:
		var material := load(MATERIAL_DIR + accent + ".tres") as StandardMaterial3D
		_expect(failures, material != null, "%s.tres is not a StandardMaterial3D" % accent)
		if material == null:
			continue
		_expect(failures, material.shading_mode == BaseMaterial3D.SHADING_MODE_PER_PIXEL, "%s.tres is unlit" % accent)
		_expect(failures, material.albedo_texture == null, "%s.tres has a texture: the accent is a flat colour" % accent)
		_expect(failures, material.albedo_color.h > 0.04 and material.albedo_color.h < 0.16 and material.albedo_color.s > 0.7 and material.albedo_color.v > 0.9, "%s.tres %s is not a saturated warm colour" % [accent, material.albedo_color])
		var light := material.albedo_color.srgb_to_linear().get_luminance()
		_expect(failures, light > 1.5 * wall_light, "%s luminance %.3f is only %.2fx the wall's %.3f" % [accent, light, light / wall_light, wall_light])
	var door := load(MATERIAL_DIR + "door.tres") as StandardMaterial3D
	var goal := load(MATERIAL_DIR + "goal.tres") as StandardMaterial3D
	if door != null and goal != null:
		_expect(failures, goal.albedo_color.h > door.albedo_color.h and goal.albedo_color.srgb_to_linear().get_luminance() > door.albedo_color.srgb_to_linear().get_luminance(), "the goal gold is not the brighter, yellower step from the door's orange")
		_expect(failures, goal.emission_enabled and goal.emission_energy_multiplier <= 1.0, "the goal does not glow softly")

	# The key is a glowing gold-orange accent, yellower than the door (a pickup, not a passage).
	var key_material := load(MATERIAL_DIR + "key.tres") as StandardMaterial3D
	if door != null and key_material != null:
		_expect(failures, key_material.emission_enabled and key_material.emission_energy_multiplier >= 0.5, "the key does not glow")
		_expect(failures, key_material.albedo_color.h > door.albedo_color.h, "the key (hue %.3f) is not yellower than the door (%.3f)" % [key_material.albedo_color.h, door.albedo_color.h])

	# The lock: dark warm iron on the door's orange. It sits ON the door, so it has to read by value against the
	# door (squint test), not against the wall; it glows only while it flashes after a refused try.
	var lock_material := load(MATERIAL_DIR + "lock.tres") as StandardMaterial3D
	_expect(failures, lock_material != null, "lock.tres is not a StandardMaterial3D")
	if lock_material != null and door != null and key_material != null:
		var lock_color := lock_material.albedo_color
		_expect(failures, lock_material.shading_mode == BaseMaterial3D.SHADING_MODE_PER_PIXEL and lock_material.albedo_texture == null, "lock.tres is unlit or textured: the accent is a flat colour")
		_expect(failures, lock_color.r >= lock_color.g and lock_color.g >= lock_color.b and lock_color.s < 0.6, "lock.tres %s is not a dark warm iron (no hazard red)" % lock_color)
		var lock_seen := lock_color.srgb_to_linear().get_luminance() + lock_material.emission.srgb_to_linear().get_luminance() * lock_material.emission_energy_multiplier
		var door_seen := door.albedo_color.srgb_to_linear().get_luminance()
		_expect(failures, lock_seen < 0.25 * door_seen, "the lock (%.3f) does not stand out darkly against the door (%.3f)" % [lock_seen, door_seen])
		_expect(failures, lock_material.emission_enabled and lock_material.emission_energy_multiplier == 0.0, "the lock glows at rest or cannot flash")

	# The props are not interactive: neutral gray, the room's grid, but darker than the walls (about 42 percent),
	# so a crate against a wall reads in the squint test, and no accent colour: nothing that is not a door,
	# a key or the goal looks like something to use.
	var prop_material := load(MATERIAL_DIR + "prop.tres") as StandardMaterial3D
	_expect(failures, prop_material != null, "prop.tres is not a StandardMaterial3D")
	if prop_material != null and fills.has("wall"):
		var shown_prop := (prop_material.albedo_color.srgb_to_linear() * fill.srgb_to_linear()).linear_to_srgb()
		_expect(failures, prop_material.albedo_texture != null and prop_material.albedo_texture.resource_path == grid.resource_path, "prop.tres does not use the shared grid")
		_expect(failures, prop_material.uv1_triplanar and prop_material.uv1_world_triplanar and prop_material.uv1_scale.is_equal_approx(Vector3.ONE), "prop.tres is not world triplanar at one tile per metre")
		_expect(failures, prop_material.shading_mode == BaseMaterial3D.SHADING_MODE_PER_PIXEL and prop_material.texture_filter == BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC, "prop.tres is unlit or filtered differently from the room")
		_expect(failures, shown_prop.r >= 0.40 and shown_prop.r <= 0.45, "prop.tres shows %.3f, expected 40 to 45 percent" % shown_prop.r)
		_expect(failures, absf(shown_prop.r - shown_prop.g) < 0.01 and absf(shown_prop.r - shown_prop.b) < 0.01, "prop.tres is not neutral gray")
		_expect(failures, fills["wall"].r - shown_prop.r >= 0.08 and fills["floor"].r - shown_prop.r >= 0.2, "the prop (%.2f) is not clearly darker than the wall (%.2f) and the floor (%.2f)" % [shown_prop.r, fills["wall"].r, fills["floor"].r])
		_expect(failures, not prop_material.emission_enabled, "prop.tres glows: only the key, the goal and the fixtures do")

	# The lamp block glows but is still a lit material.
	var fixture := load(MATERIAL_DIR + "fixture.tres") as StandardMaterial3D
	_expect(failures, fixture != null and fixture.emission_enabled and fixture.emission_energy_multiplier >= 1.0, "fixture.tres is not emissive")
	_expect(failures, fixture != null and fixture.shading_mode == BaseMaterial3D.SHADING_MODE_PER_PIXEL, "fixture.tres is unlit")

	# No scene brings its own material: floors, walls, ceilings, lamps, doors and the pad all come from res://materials.
	var scenes := 0
	for step in STEPS:
		for file in _step_files(step):
			if file.ends_with(".tscn"):
				scenes += 1
				var text := FileAccess.get_file_as_string("res://steps/%s/%s" % [step, file])
				_expect(failures, not text.contains('[sub_resource type="StandardMaterial3D"') and not text.contains("albedo_color"), "%s/%s defines a material of its own" % [step, file])
	_expect(failures, scenes >= 80, "found only %d scenes" % scenes)
	return failures

func test_graybox_rooms(step: String) -> Array[String]:
	var failures: Array[String] = []
	var files: Array[String] = []
	for file in DirAccess.get_files_at("res://steps/" + step):
		if file.begins_with("room_") and file.ends_with(".tscn"):
			files.append(file)
	files.sort()
	var expected := _room_types_of(step).size() + 1 # the rooms and the goal room
	_expect(failures, files.size() == expected, "%d room scenes, expected %d" % [files.size(), expected])

	# Far apart, so that a ray only ever sees the room it starts in.
	var holder := Node3D.new()
	root.add_child(holder)
	for i in files.size():
		var room := (load("res://steps/%s/%s" % [step, files[i]]) as PackedScene).instantiate() as Node3D
		room.position = Vector3(i * 40.0, 0.0, 0.0)
		holder.add_child(room)
	await _wait_physics(5) # the CSG shapes build their collision
	for room in holder.get_children():
		failures.append_array(_graybox_problems(room as Node3D, step))
	root.remove_child(holder)
	holder.free()
	return failures

## Everything the graybox standard asks of one room module, as problems (empty = fine).
func _graybox_problems(room: Node3D, step: String) -> Array[String]:
	var problems: Array[String] = []
	var label := room.scene_file_path.trim_prefix("res://steps/")
	var player := (load("res://steps/%s/player.tscn" % step) as PackedScene).instantiate()
	var capsule := (player.get_node("CollisionShape3D") as CollisionShape3D).shape as CapsuleShape3D
	player.free()

	# Floor: 0.2 m thick, its top at y = 0.
	var floor_box := room.get_node("Shell/Floor") as CSGBox3D
	var footprint := Vector2(floor_box.size.x, floor_box.size.z)
	_expect(problems, is_equal_approx(floor_box.size.y, SLAB_THICKNESS) and is_zero_approx(floor_box.position.y + floor_box.size.y / 2.0), "%s: the floor is %.2f m thick with its top at y = %.2f" % [label, floor_box.size.y, floor_box.position.y + floor_box.size.y / 2.0])
	_expect(problems, floor_box.material != null and floor_box.material.resource_path == MATERIAL_DIR + "floor.tres", "%s: the floor does not use floor.tres" % label)

	# Walls: 0.2 x 3.0 m, standing on the floor, flush with the footprint edge; cutters 1.6 x 2.4 m and deeper than the wall.
	for wall_name: String in ["WallEntrance", "WallFar", "WallLeft", "WallRight"]:
		var wall := room.get_node("Shell/" + wall_name) as CSGBox3D
		var along_z := wall_name.begins_with("WallE") or wall_name == "WallFar"
		var thickness := wall.size.z if along_z else wall.size.x
		var centre := absf(wall.position.z) if along_z else absf(wall.position.x)
		var half := footprint.y / 2.0 if along_z else footprint.x / 2.0
		_expect(problems, is_equal_approx(thickness, WALL_THICKNESS) and is_equal_approx(wall.size.y, WALL_HEIGHT), "%s: %s is %.2f m thick and %.2f m high" % [label, wall_name, thickness, wall.size.y])
		_expect(problems, is_zero_approx(wall.position.y - wall.size.y / 2.0), "%s: %s does not stand on the floor" % [label, wall_name])
		_expect(problems, is_equal_approx(centre + thickness / 2.0, half), "%s: %s is not flush with the footprint edge" % [label, wall_name])
		_expect(problems, wall.material != null and wall.material.resource_path == MATERIAL_DIR + "wall.tres", "%s: %s does not use wall.tres" % [label, wall_name])
		for cutter in wall.get_children():
			var hole := cutter as CSGBox3D
			var width := maxf(hole.size.x, hole.size.z)
			var depth := minf(hole.size.x, hole.size.z)
			_expect(problems, hole.operation == CSGShape3D.OPERATION_SUBTRACTION, "%s: %s/%s does not subtract" % [label, wall_name, hole.name])
			_expect(problems, is_equal_approx(width, DOORWAY_WIDTH) and is_equal_approx(hole.size.y, DOORWAY_HEIGHT), "%s: %s is %.2f x %.2f m, expected 1.6 x 2.4" % [label, hole.name, width, hole.size.y])
			_expect(problems, depth >= thickness + 0.1, "%s: %s is only %.2f m deep for a %.2f m wall" % [label, hole.name, depth, thickness])
			_expect(problems, is_zero_approx(wall.position.y + hole.position.y - hole.size.y / 2.0), "%s: %s does not start at the floor" % [label, hole.name])
			_expect(problems, hole.material != null and hole.material.resource_path == MATERIAL_DIR + "wall.tres", "%s: %s does not use wall.tres" % [label, hole.name])
			_expect(problems, width >= 2.0 * capsule.radius * 2.0 and hole.size.y >= capsule.height + 0.6, "%s: %s is too small for the player (2x width, 0.6 m head room)" % [label, hole.name])

	# Ceiling: its own CSG shape beside the Shell, 0.2 m thick on top of the walls, collision, layer 2 only.
	var ceiling := room.get_node("Ceiling") as CSGBox3D
	_expect(problems, ceiling.get_parent() == room and not ceiling.is_class("CSGCombiner3D"), "%s: the Ceiling is not a direct child of the room" % label)
	_expect(problems, ceiling.use_collision, "%s: the Ceiling has no collision" % label)
	_expect(problems, ceiling.layers == CEILING_LAYER, "%s: the Ceiling is on layers %d, expected only layer 2" % [label, ceiling.layers])
	_expect(problems, is_equal_approx(ceiling.size.y, SLAB_THICKNESS) and is_equal_approx(ceiling.position.y - ceiling.size.y / 2.0, WALL_HEIGHT), "%s: the Ceiling is %.2f m thick with its bottom at y = %.2f, expected 0.2 m at 3.0" % [label, ceiling.size.y, ceiling.position.y - ceiling.size.y / 2.0])
	_expect(problems, is_equal_approx(ceiling.size.x, footprint.x) and is_equal_approx(ceiling.size.z, footprint.y), "%s: the Ceiling does not cover the footprint" % label)
	_expect(problems, ceiling.material != null and ceiling.material.resource_path == MATERIAL_DIR + "ceiling.tres", "%s: the Ceiling does not use ceiling.tres" % label)

	# The lamp: one warm omni light near the ceiling centre without shadows, range over the whole room, paired with a visible block on layer 2.
	var light := room.get_node("RoomLight") as OmniLight3D
	var farthest := Vector3(footprint.x / 2.0, light.position.y, footprint.y / 2.0).length()
	_expect(problems, not light.shadow_enabled, "%s: RoomLight casts shadows" % label)
	_expect(problems, light.light_color.r >= light.light_color.g and light.light_color.g >= light.light_color.b and light.light_color.b < 0.95, "%s: RoomLight is not warm white" % label)
	_expect(problems, light.omni_range >= farthest, "%s: RoomLight range %.1f does not reach the far corner (%.1f m)" % [label, light.omni_range, farthest])
	_expect(problems, light.position.y > 2.2 and light.position.y < WALL_HEIGHT and absf(light.position.x) < 0.01 and absf(light.position.z) < 0.01, "%s: RoomLight is not near the ceiling centre (%s)" % [label, light.position])
	var fixture := room.get_node("Fixture") as MeshInstance3D
	var block := (fixture.mesh as BoxMesh)
	_expect(problems, fixture.layers == CEILING_LAYER, "%s: the Fixture is on layers %d, expected only layer 2" % [label, fixture.layers])
	_expect(problems, block.material != null and block.material.resource_path == MATERIAL_DIR + "fixture.tres", "%s: the Fixture does not use fixture.tres" % label)
	_expect(problems, is_equal_approx(fixture.position.y + block.size.y / 2.0, WALL_HEIGHT) and Vector2(fixture.position.x - light.position.x, fixture.position.z - light.position.z).length() < 0.01, "%s: the Fixture does not hang under the ceiling above the light" % label)

	# Closed: straight up from anywhere in the room hits the ceiling at 3.0 m, straight down the floor.
	var space := room.get_world_3d().direct_space_state
	var spots: Array[Vector2] = [Vector2.ZERO, footprint / 4.0, footprint * Vector2(-0.25, 0.25), footprint * Vector2(0.25, -0.25), -footprint / 4.0]
	for spot in spots:
		var from := room.global_position + Vector3(spot.x, 1.0, spot.y)
		var up := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + Vector3(0.0, 2.5, 0.0)))
		if up.is_empty():
			problems.append("%s: a ray straight up from (%.1f, 1, %.1f) does not hit the ceiling" % [label, spot.x, spot.y])
		else:
			var hit_y: float = up["position"].y
			_expect(problems, absf(hit_y - WALL_HEIGHT) < 0.01, "%s: the ray up from (%.1f, 1, %.1f) hits at y = %.2f, expected 3.0" % [label, spot.x, spot.y, hit_y])
			_expect(problems, up["collider"] == ceiling, "%s: the ray up hit %s, not the Ceiling" % [label, up["collider"]])
		var down := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + Vector3(0.0, -2.0, 0.0)))
		var floor_y := VAULT_PLATFORM_HEIGHT if label.ends_with("room_vault.tscn") and spot.length() < 0.01 else 0.0 # the vault's middle is the platform
		_expect(problems, not down.is_empty() and absf((down["position"] as Vector3).y - floor_y) < 0.01, "%s: a ray straight down from (%.1f, 1, %.1f) misses the floor" % [label, spot.x, spot.y])
	return problems

func test_lighting(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step, false)
	var environment := (main.get_node("WorldEnvironment") as WorldEnvironment).environment
	_expect(failures, environment.background_mode == Environment.BG_SKY and environment.sky != null and environment.sky.sky_material is ProceduralSkyMaterial, "the ProceduralSky is gone")
	_expect(failures, environment.ambient_light_source == Environment.AMBIENT_SOURCE_COLOR or environment.ambient_light_source == Environment.AMBIENT_SOURCE_SKY, "ambient light source %d: the closed rooms get no fill" % environment.ambient_light_source)
	# Ambient light alone must not leave the darkest surface (the walls) black: at least 0.35 displayed.
	var fill := environment.ambient_light_energy * environment.ambient_light_color.srgb_to_linear().get_luminance()
	if environment.ambient_light_source == Environment.AMBIENT_SOURCE_SKY:
		fill = environment.ambient_light_energy * 0.3 ## The darkest part of the procedural sky.
	var wall := load(MATERIAL_DIR + "wall.tres") as StandardMaterial3D
	var wall_albedo := wall.albedo_color.srgb_to_linear().r * (load(MATERIAL_DIR + "grid_1m.png") as Texture2D).get_image().get_pixel(100, 100).srgb_to_linear().r
	var shown := (wall_albedo * fill)
	var shown_srgb := Color(shown, shown, shown).linear_to_srgb().r
	_expect(failures, shown_srgb >= 0.35, "ambient fill %.2f lights the walls to only %.2f (displayed); unlit corners must not be black" % [fill, shown_srgb])
	var sun := main.get_node("DirectionalLight3D") as DirectionalLight3D
	_expect(failures, sun.shadow_enabled, "the sun has no shadows: it would light the rooms through the ceilings")
	await _unload(main)
	return failures

func test_player_camera(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step, false)
	var player: CharacterBody3D = main.get_node("Level").player
	var camera: Camera3D = player.get_node("Head/Camera3D")
	_expect(failures, camera.cull_mask == ALL_LAYERS, "the player's cull_mask is %d, expected all %d layers" % [camera.cull_mask, ALL_LAYERS])
	_expect(failures, (camera.cull_mask & CEILING_LAYER) != 0, "the player's camera does not draw layer 2: no ceiling, no lamp")
	_expect(failures, main.find_child("OverviewCamera", true, false) == null, "a cutaway camera is left in a player step")
	await _unload(main)
	return failures

## The underside of a room's ceiling, in world space.
func _ceiling_bottom(room: Node3D) -> float:
	var ceiling := room.get_node("Ceiling") as CSGBox3D
	return ceiling.global_position.y - ceiling.size.y / 2.0

#endregion

func test_scene_runs(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step, false)
	for i in 30:
		await process_frame
	_expect(failures, is_instance_valid(main) and main.is_inside_tree(), "scene left the tree")
	await _unload(main)
	return failures

#region Tutorial 04 (checked again): source rules

## Who knows what: the door never knows what a key is, the key never knows the level, the level never rolls dice.
func test_key_rules() -> Array[String]:
	var failures: Array[String] = []
	var keys_word := RegEx.create_from_string("\\bkeys?\\b")
	for step in STEPS:
		for line in _code_lines("res://steps/%s/door.gd" % step):
			_expect(failures, keys_word.search(line) == null, "%s/door.gd talks about keys: %s" % [step, line])
			_expect(failures, not line.contains("Level") and not line.contains("get_parent") and not line.contains("owner"), "%s/door.gd reaches for the level: %s" % [step, line])
	for step in STEPS:
		for line in _code_lines("res://steps/%s/key.gd" % step):
			_expect(failures, not line.contains("keys") and not line.contains("Level") and not line.contains("get_parent") and not line.contains("level"), "%s/key.gd reaches for the level: %s" % [step, line])
		var key_source := FileAccess.get_file_as_string("res://steps/%s/key.gd" % step)
		var process_at := key_source.find("func _process(")
		var process_end := key_source.find("\nfunc ", process_at + 1)
		var process_body := key_source.substr(process_at, process_end - process_at)
		_expect(failures, not process_body.contains("picked_up") and not process_body.contains("queue_free") and not process_body.contains("collision") and not process_body.contains("monitoring"), "%s/key.gd: _process does more than move the model" % step)
		_expect(failures, key_source.contains("model.rotation.y") and key_source.contains("model.position.y"), "%s/key.gd: the model does not spin and bob" % step)
		for forbidden: String in ["RandomNumberGenerator", "Time."]:
			_expect(failures, not key_source.contains(forbidden), "%s/key.gd uses %s" % [step, forbidden])
	# The level, the door and the room never roll dice: only the chain does.
	for step in STEPS:
		for file: String in ["level.gd", "door.gd", "room.gd", "hud.gd"]:
			_expect(failures, not FileAccess.get_file_as_string("res://steps/%s/%s" % [step, file]).contains("RandomNumberGenerator"), "%s/%s has a random generator" % [step, file])
	# The chain has three streams: _rng picks the rooms, _content_rng the locks, _prop_rng the props, each in one place.
	for step in STEPS:
		var source := FileAccess.get_file_as_string("res://steps/%s/room_chain.gd" % step)
		var contents := _function_body(source, "func _decide_contents(")
		var rooms := _function_body(source, "func _shuffled_types(" if STEPS.find(step) < STEPS.find("step_03_weighted_rooms") else "func _weighted_types(")
		_expect(failures, source.contains("_content_rng.seed = hash([chain_seed, \"content\"])"), "%s: the content generator is not seeded from the chain seed" % step)
		_expect(failures, source.count("_content_rng.rand") == 2 and contents.count("_content_rng.rand") == 2, "%s: _content_rng is used outside _decide_contents (%d uses)" % [step, source.count("_content_rng.rand")])
		var own_draws := RegEx.create_from_string("(?<![_a-z])_rng\\.rand")
		_expect(failures, own_draws.search_all(source).size() == 1 and own_draws.search_all(rooms).size() == 1, "%s: _rng is used outside the room order" % step)
		_expect(failures, not rooms.contains("_content_rng") and not rooms.contains("_prop_rng"), "%s: the generators are mixed up" % step)
		if STEPS.find(step) >= STEPS.find("step_01_prop_spots"):
			var props := _function_body(source, "func _decide_props(")
			_expect(failures, source.count("_prop_rng.") == props.count("_prop_rng.") and props.count("_prop_rng.rand") >= 1, "%s: _prop_rng is used outside _decide_props" % step)
			_expect(failures, props.contains("_prop_rng.seed = hash([_chain_seed, \"props\", plan.index])"), "%s: the props of a room are not seeded from the chain seed and the room's index" % step)
			_expect(failures, not props.contains("_rng.rand") or props.count("_rng.rand") == props.count("_prop_rng.rand"), "%s: _decide_props draws from another generator" % step)
		else:
			_expect(failures, not source.contains("_prop_rng"), "%s has props before step 1" % step)
	return failures

## The lines of a script without comments, trailing ## comments cut off.
func _code_lines(path: String) -> Array[String]:
	var lines: Array[String] = []
	for line in FileAccess.get_file_as_string(path).split("\n"):
		var code := line.split("##")[0].strip_edges()
		if not code.is_empty() and not code.begins_with("#"):
			lines.append(code)
	return lines

## The text of one function: from its signature to the next top-level func.
func _function_body(source: String, signature: String) -> String:
	var start := source.find(signature)
	if start < 0:
		return ""
	var end := source.find("\nfunc ", start + 1)
	return source.substr(start, (end if end >= 0 else source.length()) - start)

#endregion

#region Locks and keys, step by step (tutorial 04's generator, checked in every step)

## Locks never move a room: with any lock chance the rooms of a seed are the rooms without locks. In every step.
func test_locks_keep_rooms() -> Array[String]:
	var failures: Array[String] = []
	for step in STEPS:
		var chain_script := _chain_script(step)
		for chain_seed in range(1, CONTENT_SEEDS + 1):
			if chain_seed % 25 == 0:
				await process_frame
			var plain: Array = _plans_to_goal(chain_script, chain_seed, 20, 0.0).plans
			for chance: float in [LOCK_CHANCE, 1.0]:
				var first: Array = _plans_to_goal(chain_script, chain_seed, 20, chance).plans
				var second: Array = _plans_to_goal(chain_script, chain_seed, 20, chance).plans
				_expect(failures, _same_plans(first, second), "%s seed %d, chance %.1f: the same seed gives other locks, key spots or props" % [step, chain_seed, chance])
				var same_rooms := first.size() == plain.size()
				for i in mini(first.size(), plain.size()):
					if first[i].type != plain[i].type or first[i].transform != plain[i].transform or first[i].bounds != plain[i].bounds:
						same_rooms = false
				_expect(failures, same_rooms, "%s seed %d, chance %.1f: the locks moved a room" % [step, chain_seed, chance])
			if failures.size() > 8:
				return failures
	return failures

## Raising the chance only adds locks: the dice are rolled for every room, so a room that stays locked keeps its key spot.
## And a room keeps its roll whatever the goal room does further on.
func test_contents_second_stream() -> Array[String]:
	var failures: Array[String] = []
	for chain_script: GDScript in [Chain00, Chain]:
		for chain_seed in range(1, CONTENT_SEEDS + 1):
			if chain_seed % 25 == 0:
				await process_frame
			var previous: Array = []
			for chance: float in [0.1, 0.3, 0.5, 0.8, 1.0]:
				var plans: Array = _plans_to_goal(chain_script, chain_seed, 20, chance).plans
				for i in previous.size():
					if previous[i].locked:
						_expect(failures, plans[i].locked and plans[i].key_spot == previous[i].key_spot, "seed %d room %d: locked at a lower chance, but not the same at %.1f" % [chain_seed, i, chance])
				previous = plans
			var near: Array = _plans_to_goal(chain_script, chain_seed, 12, 0.5).plans
			var far: Array = _plans_to_goal(chain_script, chain_seed, 20, 0.5).plans
			for i in 11: # room 11 is the one before the near goal: always open there
				_expect(failures, near[i].locked == far[i].locked and near[i].key_spot == far[i].key_spot, "seed %d room %d: the goal room changed the roll of another room" % [chain_seed, i])
			if failures.size() > 8:
				return failures
	return failures

func test_contents_rules() -> Array[String]:
	var failures: Array[String] = []
	for chain_script: GDScript in [Chain00, Chain]:
		for goal_room: int in [1, 2, 3, 7, 20]:
			for chain_seed in range(1, 301):
				if chain_seed % 50 == 0:
					await process_frame
				var chain := _plans_to_goal(chain_script, chain_seed, goal_room, 1.0)
				var plans: Array = chain.plans
				var label := "goal %d seed %d" % [goal_room, chain_seed]
				_expect(failures, plans[-1].type == _goal_type(chain_script) and chain.goal_index == plans.size() - 1, "%s: no goal room at the end" % label)
				for plan: Object in plans:
					var forced_open: bool = plan.index == 0 or plan.index == chain.goal_index - 1 or plan.type == _goal_type(chain_script)
					if forced_open:
						_expect(failures, not plan.locked and plan.key_spot == -1, "%s: room %d (room 0, before the goal or the goal) is locked or holds a key" % [label, plan.index])
					else:
						_expect(failures, plan.locked, "%s: room %d is not locked at chance 1" % [label, plan.index])
					_expect(failures, plan.locked == (plan.key_spot >= 0), "%s: room %d: locked %s, key spot %d" % [label, plan.index, plan.locked, plan.key_spot])
					_expect(failures, plan.key_spot < chain.key_spot_count(plan.type), "%s: room %d: key spot %d of %d" % [label, plan.index, plan.key_spot, chain.key_spot_count(plan.type)])
				for plan: Object in _plans_to_goal(chain_script, chain_seed, goal_room, 0.0).plans:
					_expect(failures, not plan.locked and plan.key_spot == -1, "%s: room %d is locked at chance 0" % [label, plan.index])
				if failures.size() > 8:
					return failures
	return failures

func test_contents_statistics() -> Array[String]:
	var failures: Array[String] = []
	for step in STEPS:
		var chain_script := _chain_script(step)
		var chain := _plans_to_goal(chain_script, 42, 20)
		var locked: Array[int] = []
		var detail := ""
		for plan: Object in chain.plans:
			if plan.locked:
				locked.append(plan.index)
				detail += " room %d (%s, spot %d)" % [plan.index, _room_name(chain_script, plan.type), plan.key_spot]
		_expect(failures, locked == SEED_42_LOCKS, "%s: seed 42 locks rooms %s, expected %s: has the engine's hash([seed, \"content\"]) changed?" % [step, locked, SEED_42_LOCKS])
		if step == STEPS[0] or step == FINAL_STEP:
			print("        %s: seed 42, goal room 20, lock chance %.1f: %d locked rooms:%s" % [step, LOCK_CHANCE, locked.size(), detail])

	var locked_total := 0
	var eligible_total := 0
	var spot_use := [0, 0, 0]
	for chain_seed in range(1, SEED_COUNT + 1):
		if chain_seed % 50 == 0:
			await process_frame
		var plans: Array = _plans_to_goal(Chain, chain_seed, 20).plans
		for plan: Object in plans:
			var eligible: bool = plan.index >= 1 and plan.index <= 18 # room 0 and 19 are always open, so is the goal
			eligible_total += 1 if eligible else 0
			if plan.locked:
				locked_total += 1
				spot_use[plan.key_spot] += 1
	var rate := float(locked_total) / float(eligible_total)
	print("        seeds 1-%d (finished chain): %d of %d eligible rooms locked (%.3f), key spots used %s" % [SEED_COUNT, locked_total, eligible_total, rate, spot_use])
	_expect(failures, absf(rate - LOCK_CHANCE) < 0.02, "%.3f of the eligible rooms are locked, the chance is %.1f" % [rate, LOCK_CHANCE])
	for spot in 3:
		_expect(failures, spot_use[spot] > locked_total / 4.0, "key spot %d is used in only %d of %d locked rooms" % [spot, spot_use[spot], locked_total])
	return failures

## The name of a room type in a step's Type enum ("STRAIGHT", "VAULT", "GOAL").
func _room_name(chain_script: GDScript, type: int) -> String:
	return str((chain_script.get_script_constant_map()["Type"] as Dictionary).find_key(type)).to_lower()

#endregion

#region Tutorial 04 (checked again): solvable, check_solvable.gd of step 0 and step 5

func test_solvable_seeds() -> Array[String]:
	var failures: Array[String] = []
	var locked_total := 0
	for chance: float in [LOCK_CHANCE, 1.0]:
		for chain_seed in range(1, SEED_COUNT + 1):
			if chain_seed % 50 == 0:
				await process_frame
			var chain := Solvable.build(chain_seed, 20, chance)
			for plan in chain.plans:
				locked_total += 1 if plan.locked else 0
			for problem in Solvable.problems_of(chain, Solvable.build(chain_seed, 20, 0.0)):
				failures.append("seed %d, chance %.1f: %s" % [chain_seed, chance, problem])
			if failures.size() > 8:
				return failures
	# Other goal rooms, too: close ones, and the goal room right after room 0.
	for goal_room: int in [1, 2, 3, 5, 12]:
		for chance: float in [LOCK_CHANCE, 1.0]:
			for chain_seed in range(1, CONTENT_SEEDS + 1):
				if chain_seed % 50 == 0:
					await process_frame
				for problem in Solvable.problems_of(Solvable.build(chain_seed, goal_room, chance), Solvable.build(chain_seed, goal_room, 0.0)):
					failures.append("goal %d, seed %d, chance %.1f: %s" % [goal_room, chain_seed, chance, problem])
				if failures.size() > 8:
					return failures
	print("        seeds 1-%d at lock chance %.1f and 1.0: %d locked rooms, none stuck" % [SEED_COUNT, LOCK_CHANCE, locked_total])
	return failures

## A check that never fails is worth nothing: break the plans of a good chain in each way the generator could
## go wrong, and see that the check names it.
func test_solvable_finds_faults() -> Array[String]:
	var failures: Array[String] = []
	var all_locked := Solvable.build(42, 20, 1.0)
	var plain := Solvable.build(42, 20, 0.0)
	_expect(failures, Solvable.problems_of(all_locked, plain).is_empty(), "the check complains about a good chain: %s" % [Solvable.problems_of(all_locked, plain)])
	var default_chain := Solvable.build(42, 20, LOCK_CHANCE)
	_expect(failures, Solvable.problems_of(default_chain, plain).is_empty(), "the check complains about the default chain: %s" % [Solvable.problems_of(default_chain, plain)])

	var faults: Array[Dictionary] = [
		{kind = "no_key", name = "a locked room without a key", expect = "locked and has no key"},
		{kind = "stray_key", name = "a key in a room that is not locked", expect = "not locked but holds a key"},
		{kind = "bad_spot", name = "a key spot the room does not have", expect = "does not exist"},
		{kind = "locked_goal", name = "a locked goal room", expect = "never are"},
		{kind = "locked_before_goal", name = "a locked room before the goal", expect = "never are"},
		{kind = "locked_room_zero", name = "a locked room 0", expect = "never are"},
		{kind = "moved_room", name = "a lock that moves a room", expect = "not the room it is without locks"},
		{kind = "lost_room", name = "a lost room", expect = "rooms with locks"},
		{kind = "second_goal", name = "a second goal room", expect = "goal rooms"},
		{kind = "no_goal", name = "no goal room", expect = "goal rooms"},
		{kind = "late_key", name = "a key one room too late", expect = "stuck"},
	]
	for fault in faults:
		# Every lockable room locked, so that room 5 is one; the late key needs an open room after a locked one: the default chain.
		var chain := Solvable.build(42, 20, LOCK_CHANCE if fault.kind == "late_key" else 1.0)
		_sabotage(chain, fault.kind)
		var problems := Solvable.problems_of(chain, plain)
		var named := false
		for problem in problems:
			named = named or problem.contains(fault.expect)
		_expect(failures, named, "the check does not find %s (expected \"%s\", got %s)" % [fault.name, fault.expect, problems.slice(0, 3)])
	return failures

## Breaks the plans of a chain the way a buggy generator could.
func _sabotage(chain: Chain, kind: String) -> void:
	match kind:
		"no_key":
			chain.plans[5].key_spot = -1
		"stray_key":
			chain.plans[5].locked = false
		"bad_spot":
			chain.plans[5].key_spot = chain.key_spot_count(chain.plans[5].type)
		"locked_goal":
			chain.plans[-1].locked = true
		"locked_before_goal":
			chain.plans[chain.goal_index - 1].locked = true
			chain.plans[chain.goal_index - 1].key_spot = 0
		"locked_room_zero":
			chain.plans[0].locked = true
			chain.plans[0].key_spot = 0
		"moved_room":
			chain.plans[7].type = (chain.plans[7].type + 1) % 5
		"lost_room":
			chain.plans.remove_at(10)
		"second_goal":
			chain.plans[3].type = Chain.Type.GOAL
		"no_goal":
			chain.plans[-1].type = Chain.Type.STRAIGHT
		"late_key":
			# The first locked room whose next room is an open ordinary room: its key moves into that room.
			for plan in chain.plans:
				var next := chain.plans[plan.index + 1]
				if plan.locked and not next.locked and next.type != Chain.Type.GOAL:
					next.key_spot = plan.key_spot
					plan.key_spot = -1
					return

## The way a viewer runs it, and the way a build server would: a separate Godot process, exit code 0.
func test_solvable_command() -> Array[String]:
	var failures: Array[String] = []
	var executable := OS.get_executable_path()
	if executable.is_empty():
		_skip("check_solvable.gd from the command line", "no executable path")
		return failures
	for step: String in [STEPS[0], FINAL_STEP]:
		var output: Array = []
		var code := OS.execute(executable, ["--headless", "--path", ProjectSettings.globalize_path("res://"), "-s", "res://steps/%s/check_solvable.gd" % step, "--", "--seeds=40"], output, true)
		var text := ""
		for chunk: String in output:
			text += str(chunk)
		_expect(failures, code == 0 and text.contains("SOLVABLE OK") and text.contains("seeds 1-40, lock chance 0.4") and text.contains("seeds 1-40, lock chance 1.0"), "%s: exit code %d, output: %s" % [step, code, text.substr(0, 300)])
	return failures

#endregion

#region Tutorial 04 (checked again): key scene, key spots, pickup

func test_key_scene(step: String) -> Array[String]:
	var failures: Array[String] = []
	var key := (load("res://steps/%s/key.tscn" % step) as PackedScene).instantiate() as Area3D
	_expect(failures, key != null and key.has_signal("picked_up"), "key.tscn is not an Area3D with a picked_up signal")
	_expect(failures, key.collision_layer == 0 and key.collision_mask == 2, "Key: layer %d mask %d, expected 0 and 2 (it only looks at the player layer)" % [key.collision_layer, key.collision_mask])
	var shape := key.get_node("CollisionShape3D") as CollisionShape3D
	var sphere := shape.shape as SphereShape3D
	_expect(failures, sphere != null and sphere.radius >= 0.4 and sphere.radius <= 0.7, "the key's reach is not a sphere of about half a metre")
	_expect(failures, shape.position.y > 0.5 and shape.position.y < 1.3, "the reach is at y = %.2f: it has to meet a capsule of 1.8 m" % shape.position.y)

	# A graybox key: ring, shaft and two teeth, the key material, about half a metre long, hovering over the floor.
	var model := key.get_node("Model") as Node3D
	var box := AABB()
	var first := true
	for part_name: String in ["Ring", "Shaft", "ToothUpper", "ToothLower"]:
		var part := model.get_node(part_name) as MeshInstance3D
		_expect(failures, part != null and part.mesh is PrimitiveMesh, "Key/Model/%s is not a primitive mesh" % part_name)
		if part == null:
			continue
		var material := (part.mesh as PrimitiveMesh).material
		_expect(failures, material != null and material.resource_path == MATERIAL_DIR + "key.tres", "%s does not use key.tres" % part_name)
		var part_box := part.transform * part.mesh.get_aabb()
		box = part_box if first else box.merge(part_box)
		first = false
	_expect(failures, box.size.y >= 0.4 and box.size.y <= 0.9 and box.size.x <= 0.5, "the key model is %s: not about half a metre" % box.size)
	_expect(failures, model.position.y - 0.5 * box.size.y > 0.3, "the key hangs too low (model at %.2f)" % model.position.y)

	# Spinning and bobbing is for the eye: the model moves, the reach does not. The test calls _process by hand,
	# 0.1 s at a time, so it does not depend on how fast the headless loop runs.
	_expect(failures, not key.monitoring, "the key's reach is awake from the start: a player the level has just placed would be counted at the old place")
	root.add_child(key)
	await process_frame
	_expect(failures, key.is_processing(), "the key does not run _process")
	await _wait_physics(3)
	_expect(failures, key.monitoring, "the key's reach did not wake up after its first physics step")
	var reach_before := shape.global_transform
	var low := INF
	var high := -INF
	var yaw_first := model.rotation.y
	for i in 70: # 7 s: two bobs
		key.call("_process", 0.1)
		low = minf(low, model.position.y)
		high = maxf(high, model.position.y)
	_expect(failures, absf((high - low) - 0.16) < 0.01, "the key bobs by %.3f m, expected 0.16 (0.08 up and down)" % (high - low))
	_expect(failures, high - low < 0.2, "the key bobs by more than 0.2 m")
	key.call("_process", 0.5)
	_expect(failures, not is_equal_approx(model.rotation.y, yaw_first), "the key does not spin")
	_expect(failures, shape.global_transform == reach_before and key.global_transform == Transform3D.IDENTITY, "the reach moved with the model")
	root.remove_child(key)
	key.free()
	return failures

## Every room type's key spots, read from the scene: on the floor, off the walking line, clear of the door, in view.
func test_key_spots(step: String) -> Array[String]:
	var failures: Array[String] = []
	await _set_screen(Vector2i(1280, 720)) # the project's window: the view of a player at the entrance is wider than tall
	var camera := Camera3D.new()
	camera.current = false
	for room_type in _room_types_of(step):
		var room := (load("res://steps/%s/room_%s.tscn" % [step, room_type]) as PackedScene).instantiate() as Node3D
		root.add_child(room)
		await _wait_physics(4) # the shells build their collision
		var spots: Array[Marker3D] = []
		var container := room.get_node_or_null("KeySpots")
		_expect(failures, container != null, "room_%s has no KeySpots" % room_type)
		if container != null:
			for child in container.get_children():
				_expect(failures, child is Marker3D and not child.name.is_empty(), "room_%s/KeySpots/%s is not a Marker3D" % [room_type, child.name])
				spots.append(child as Marker3D)
			_expect(failures, spots.size() >= 2 and spots.size() <= 3, "room_%s has %d key spots, expected 2 or 3" % [room_type, spots.size()])
		failures.append_array(_key_spot_problems(room, room_type, spots, camera))
		root.remove_child(room)
		room.free()
	# The goal room has no door and no key.
	var goal := (load("res://steps/%s/room_goal.tscn" % step) as PackedScene).instantiate() as Node3D
	_expect(failures, goal.get_node_or_null("KeySpots") == null and goal.get_node_or_null("KeySpot") == null and goal.get_node_or_null("PropSpots") == null, "the goal room has key or prop spots")
	goal.free()
	camera.free()
	return failures

func _key_spot_problems(room: Node3D, label: String, spots: Array[Marker3D], camera: Camera3D) -> Array[String]:
	var problems: Array[String] = []
	var entrance := room.get_node("Entrance") as Marker3D
	var exit_point := room.get_node("Exit") as Marker3D
	var door := room.get("door") as Node3D
	var floor_box := room.get_node("Shell/Floor") as CSGBox3D
	var floor_rect := Rect2(Vector2(floor_box.position.x, floor_box.position.z) - Vector2(floor_box.size.x, floor_box.size.z) / 2.0, Vector2(floor_box.size.x, floor_box.size.z))
	var trigger_rect := _area_rect(door, "Trigger")
	var swing_rect := _area_rect(door, "Swing")
	var line_from := Vector2(entrance.position.x, entrance.position.z)
	var line_to := Vector2(exit_point.position.x, exit_point.position.z)

	# A player at the entrance, eye 1.6 m up, looking straight into the room.
	room.add_child(camera)
	camera.transform = entrance.transform.translated_local(Vector3(0.0, 1.6, 0.0))
	camera.fov = 75.0
	for i in spots.size():
		var spot := spots[i]
		var name := "%s %s" % [label, spot.name]
		var at := Vector2(spot.position.x, spot.position.z)
		_expect(problems, is_zero_approx(spot.position.y), "%s is %.2f m above the floor" % [name, spot.position.y])
		_expect(problems, floor_rect.grow(-0.9).has_point(at), "%s (%s) is less than 0.9 m from a wall: the key's reach and the player's body need room" % [name, at])
		_expect(problems, _distance_to_rect(at, trigger_rect) >= 1.5, "%s is %.2f m from the door's trigger: picking the key up must not set the door off (key reach 0.5 + body 0.4 + margin)" % [name, _distance_to_rect(at, trigger_rect)])
		_expect(problems, _distance_to_rect(at, swing_rect) >= 1.5, "%s is %.2f m from the door's swing" % [name, _distance_to_rect(at, swing_rect)])
		var way_to_trigger := _segment_distance_to_rect(line_from, at, trigger_rect)
		var way_to_swing := _segment_distance_to_rect(line_from, at, swing_rect)
		_expect(problems, way_to_trigger >= 0.9 and way_to_swing >= 0.9, "%s: walking straight from the entrance to the key passes %.2f m from the door's trigger and %.2f m from its swing (body 0.4 + margin): the player would knock on the door on the way" % [name, way_to_trigger, way_to_swing])
		var line_distance := Geometry2D.get_closest_point_to_segment(at, line_from, line_to).distance_to(at)
		_expect(problems, line_distance >= 1.5, "%s is %.2f m from the walking line between entrance and exit: a player walking through would pick it up by accident" % [name, line_distance])
		var centre := room.global_transform * (spot.position + Vector3(0.0, 0.9, 0.0))
		_expect(problems, camera.is_position_in_frustum(centre), "%s is out of view for a player standing at the entrance" % name)
		var query := PhysicsRayQueryParameters3D.create(camera.global_position, centre)
		var hit := room.get_world_3d().direct_space_state.intersect_ray(query)
		_expect(problems, hit.is_empty(), "%s is hidden from the entrance: a ray hits %s" % [name, hit.get("collider")])
		for j in range(i + 1, spots.size()):
			_expect(problems, spot.position.distance_to(spots[j].position) >= 2.0, "%s and %s are less than 2 m apart" % [name, spots[j].name])
	room.remove_child(camera)
	return problems

## An area of a door as a rectangle on the floor plane of the room (the door sits in the room, turned by multiples of 90 degrees).
func _area_rect(door: Node3D, area_name: String) -> Rect2:
	var area := door.get_node(area_name) as Area3D
	var shape := area.get_node("CollisionShape3D") as CollisionShape3D
	var half := (shape.shape as BoxShape3D).size / 2.0
	var to_room := door.transform * area.transform * shape.transform
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for x: float in [-half.x, half.x]:
		for z: float in [-half.z, half.z]:
			var corner := to_room * Vector3(x, 0.0, z)
			low = low.min(Vector2(corner.x, corner.z))
			high = high.max(Vector2(corner.x, corner.z))
	return Rect2(low, high - low)

## How close a straight walk from a to b comes to a rectangle.
func _segment_distance_to_rect(from: Vector2, to: Vector2, rect: Rect2) -> float:
	var closest := INF
	for i in 101:
		closest = minf(closest, _distance_to_rect(from.lerp(to, i / 100.0), rect))
	return closest

func _distance_to_rect(point: Vector2, rect: Rect2) -> float:
	var outside := Vector2(maxf(maxf(rect.position.x - point.x, 0.0), point.x - rect.end.x), maxf(maxf(rect.position.y - point.y, 0.0), point.y - rect.end.y))
	return outside.length()

#endregion

#region Helpers for levels with a key and a lock

## Removes the lock of a door without opening it. Step 2 locks room 0 by hand; tests about the swing want a plain door.
func _unlock_by_hand(door: Node) -> void:
	if door.get("locked") == true:
		door.call("unlock")

## The keys lying in a room: children with a picked_up signal that are not on their way out.
func _keys_in(room: Node3D) -> Array[Node3D]:
	var found: Array[Node3D] = []
	for child in room.get_children():
		if child.has_signal("picked_up") and not child.is_queued_for_deletion():
			found.append(child)
	return found

const KEY_ROOM := 1 ## The room with the key and the locked door in a test level (lock chance 1 locks it; room 0 is never locked).

## A level with a key to fetch: lock_chance 1 locks every room but room 0 and the one before the goal, so room 1 is
## locked; the autopilot brings the player into it, the key still lies there.
func _load_with_key(step: String, extra := {}) -> Node:
	var settings := {"goal_room": 6, "lock_chance": 1.0}
	settings.merge(extra, true)
	var main := await _load_step(step, true, settings)
	var level: Node3D = main.get_node("Level")
	_fast_forward(true)
	var pilot := Autopilot.new(level)
	await _walk(level, pilot, KEY_ROOM, 0, Callable())
	_fast_forward(false)
	await _wait_physics(5)
	return main

## Puts the player `metres` in front of the room's exit, looking at the door.
func _stand_before_door(level: Node3D, room: Node3D, metres: float) -> void:
	var door_point := (room.get("exit") as Marker3D).global_transform
	var forward := -door_point.basis.z
	var player: CharacterBody3D = level.player
	player.global_position = door_point.origin - forward * metres
	player.rotation.y = atan2(-forward.x, -forward.z)
	(player.get_node("Head") as Node3D).rotation.x = 0.0
	player.velocity = Vector3.ZERO
	await _wait_physics(3)

## Walks the player at a key from 2.5 m away, from the side of the entrance (away from the door), until the key is gone.
func _walk_into(level: Node3D, room: Node3D, key: Node3D) -> bool:
	var player: CharacterBody3D = level.player
	var entrance := (room.get("entrance") as Marker3D).global_position
	var towards_entrance := Vector3(entrance.x - key.global_position.x, 0.0, entrance.z - key.global_position.z).normalized()
	player.global_position = key.global_position + towards_entrance * 2.5
	var direction := key.global_position - player.global_position
	player.rotation.y = atan2(-direction.x, -direction.z)
	player.velocity = Vector3.ZERO
	await _wait_physics(3)
	return await _walk_forward_until(func() -> bool: return not is_instance_valid(key) or key.is_queued_for_deletion(), 180)

## Holds move_forward until the condition is true (checked once per physics frame) or the ticks run out.
func _walk_forward_until(condition: Callable, max_ticks: int) -> bool:
	Input.action_press("move_forward")
	var reached := false
	for i in max_ticks:
		await physics_frame
		if condition.call():
			reached = true
			break
	Input.action_release("move_forward")
	return reached

func _label_text(main: Node, path: String) -> String:
	var label := main.get_node_or_null(path) as Label
	return label.text if label != null else ""

#endregion

#region Tutorial 04 (checked again): picking up, locking, unlocking

func test_pickup(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_with_key(step)
	var level: Node3D = main.get_node("Level")
	var room: Node3D = level.rooms[KEY_ROOM]
	var found := _keys_in(room)
	_expect(failures, found.size() == 1, "%d keys in the room, expected 1" % found.size())
	if found.size() != 1:
		await _unload(main)
		return failures
	var key := found[0]
	_expect(failures, level.keys == 0 and _label_text(main, "HUD/Stats/KeysLabel") == "Keys 0", "keys %s, label \"%s\" before the pickup" % [level.keys, _label_text(main, "HUD/Stats/KeysLabel")])
	var counts: Array[int] = []
	level.connect("keys_changed", func(count: int) -> void: counts.append(count))

	# Not touched: standing 2.5 m away, or walking past at the wall, picks nothing up.
	var player: CharacterBody3D = level.player
	await _wait_physics(30)
	_expect(failures, counts.is_empty() and is_instance_valid(key), "the key was picked up without being touched")

	var key_position := key.global_position
	var reached := await _walk_into(level, room, key)
	await _wait_physics(3)
	_expect(failures, reached, "walking into the key did not pick it up")
	_expect(failures, counts == [1], "keys_changed was sent with %s, expected [1] (counted exactly once)" % [counts])
	_expect(failures, level.keys == 1 and _label_text(main, "HUD/Stats/KeysLabel") == "Keys 1", "keys %s, label \"%s\" after the pickup" % [level.keys, _label_text(main, "HUD/Stats/KeysLabel")])
	_expect(failures, not is_instance_valid(key) and _keys_in(room).is_empty(), "the key is still in the room after the pickup")

	# Nothing left to pick up at the same place.
	player.global_position = key_position
	player.velocity = Vector3.ZERO
	await _wait_physics(30)
	_expect(failures, counts == [1] and level.keys == 1, "walking over the empty spot counted again: %s" % [counts])

	# R takes the key out of the player's hands.
	await _action("regenerate")
	await _wait_physics(10)
	_expect(failures, level.keys == 0 and _label_text(main, "HUD/Stats/KeysLabel") == "Keys 0" and counts.back() == 0, "R left keys %s, label \"%s\"" % [level.keys, _label_text(main, "HUD/Stats/KeysLabel")])
	await _unload(main)
	return failures

func test_keys_label(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step)
	var level: Node3D = main.get_node("Level")
	var label: Label = main.get_node("HUD/Stats/KeysLabel")
	var room_label: Label = main.get_node("HUD/Stats/RoomLabel")
	_expect(failures, label.text == "Keys 0", "the keys label reads \"%s\" at the start" % label.text)
	_expect(failures, label.get_parent() == room_label.get_parent() and label.get_index() == room_label.get_index() + 1, "the keys label is not right under the room counter")
	_expect(failures, label.get_theme_font_size("font_size") == room_label.get_theme_font_size("font_size") and label.get_theme_constant("outline_size") == room_label.get_theme_constant("outline_size") and label.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT, "the keys label does not look like the room counter")
	level.keys_changed.emit(7)
	_expect(failures, label.text == "Keys 7", "the label reads \"%s\" after keys_changed(7)" % label.text)
	level.keys_changed.emit(0)
	for screen_size: Vector2i in [Vector2i(1920, 1080), Vector2i(1280, 720)]:
		await _set_screen(screen_size)
		label.text = "Keys 20" # the widest it gets
		await process_frame
		var stats: Control = main.get_node("HUD/Stats")
		var screen := Rect2(Vector2.ZERO, Vector2(screen_size))
		var where := "at %dx%d" % [screen_size.x, screen_size.y]
		_expect(failures, screen.encloses(stats.get_global_rect()) and stats.get_global_rect().end.x <= screen.end.x - 8.0, "%s: the stats box %s does not fit the screen" % [where, stats.get_global_rect()])
		_expect(failures, not stats.get_global_rect().intersects((main.get_node("HUD/DebugMap") as Control).get_global_rect()), "%s: the stats box overlaps the map" % where)
		_expect(failures, label.get_minimum_size().x <= stats.size.x, "%s: \"Keys 20\" needs %.0f px, the box is %.0f px wide" % [where, label.get_minimum_size().x, stats.size.x])
		_expect(failures, label.get_global_rect().position.y > room_label.get_global_rect().position.y and label.get_global_rect().end.y <= stats.get_global_rect().end.y + 0.5, "%s: the keys label is not inside the box under the counter" % where)
	await _unload(main)
	return failures

func test_locked_door(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_with_key(step)
	var level: Node3D = main.get_node("Level")
	var player: CharacterBody3D = level.player
	var room: Node3D = level.rooms[KEY_ROOM]
	var door: Node3D = room.get("door")
	var hinge: Node3D = door.get("hinge")
	var lock_block: Node3D = door.get("lock_block")
	var label := "%s room %d" % [step, KEY_ROOM]

	# The lock is on the door: a red-orange bar and plate, from lock.tres, in front of the panel.
	_expect(failures, door.get("locked") == true and lock_block.visible and not door.get("is_open"), "%s: the door is not locked and shut with its lock showing" % label)
	for part_name: String in ["Bar", "Plate"]:
		var part := lock_block.get_node(part_name) as MeshInstance3D
		var material := (part.mesh as PrimitiveMesh).material
		_expect(failures, material != null and material.resource_path == MATERIAL_DIR + "lock.tres", "%s: the lock's %s does not use lock.tres" % [label, part_name])
		_expect(failures, part.position.z + (part.mesh as BoxMesh).size.z / 2.0 > 0.05 and lock_block.global_position.distance_to(door.global_position) < 3.0, "%s: the lock's %s does not stand out of the panel" % [label, part_name])
	var asked := [0]
	var opened := [0]
	var counts: Array[int] = []
	door.connect("unlock_requested", func() -> void: asked[0] += 1)
	door.connect("opened", func() -> void: opened[0] += 1)
	level.connect("keys_changed", func(count: int) -> void: counts.append(count))
	var key := _keys_in(room)[0]

	# 1. No key: the player walks up, the door asks the level, the answer is no. The door stays shut, however long the
	# player pushes. The refusal rattles the door (tutorial 04's feedback).
	var asked_at := [-1]
	var peak_angle := [0.0]
	door.connect("unlock_requested", func() -> void: asked_at[0] = Engine.get_physics_frames())
	await _stand_before_door(level, room, 5.0)
	Input.action_press("move_forward")
	var sampler := func() -> bool:
		peak_angle[0] = maxf(peak_angle[0], absf(hinge.rotation.y))
		return asked_at[0] >= 0 and Engine.get_physics_frames() > int(asked_at[0]) + 150
	await _drive(sampler)
	Input.action_release("move_forward")
	_expect(failures, asked[0] == 1, "%s: the locked door was asked %d times when the player walked up" % [label, asked[0]])
	_expect(failures, peak_angle[0] > deg_to_rad(3.0), "%s: the refused door did not rattle" % label)
	_expect(failures, not door.get("is_open") and opened[0] == 0 and absf(hinge.rotation.y) < 0.01, "%s: the locked door opened without a key (open %s, hinge %.3f rad)" % [label, door.get("is_open"), hinge.rotation.y])
	_expect(failures, level.keys == 0 and counts.is_empty() and door.get("locked") == true and lock_block.visible, "%s: keys %d, locked %s after the refusal" % [label, level.keys, door.get("locked")])
	var door_point := (room.get("exit") as Marker3D).global_transform
	_expect(failures, _depth(player, door_point) < -0.3, "%s: the player got through the locked door (depth %.2f)" % [label, _depth(player, door_point)])

	# 2. Fetch the key: one pickup, the HUD says so.
	var picked := await _walk_into(level, room, key)
	await _wait_physics(3)
	_expect(failures, picked and level.keys == 1 and counts == [1] and _label_text(main, "HUD/Stats/KeysLabel") == "Keys 1", "%s: keys %d, label \"%s\" after the pickup" % [label, level.keys, _label_text(main, "HUD/Stats/KeysLabel")])
	_expect(failures, not door.get("is_open") and door.get("locked") == true, "%s: picking up the key opened the door by itself" % label)

	# 3. With the key: the door asks again, the answer is yes, the key is used up, the door opens by itself.
	await _stand_before_door(level, room, 5.0)
	var asked_before: int = asked[0]
	var reached := await _walk_forward_until(func() -> bool: return door.get("is_open") == true, 240)
	await _wait_physics(5)
	_expect(failures, reached and door.get("is_open") == true, "%s: the door did not open for a player with a key" % label)
	_expect(failures, asked[0] == asked_before + 1 and opened[0] == 1, "%s: asked %d times, opened %d times with the key" % [label, asked[0] - asked_before, opened[0]])
	_expect(failures, level.keys == 0 and counts == [1, 0] and _label_text(main, "HUD/Stats/KeysLabel") == "Keys 0", "%s: keys %d, changes %s, label \"%s\": the key was not used up exactly once" % [label, level.keys, counts, _label_text(main, "HUD/Stats/KeysLabel")])
	_expect(failures, door.get("locked") == false, "%s: the door is still locked after the key" % label)
	await _wait_physics(60) # the swing (0.5 s) and the lock's fall
	_expect(failures, absf(hinge.rotation.y - (-PI / 2.0)) < 0.03 and not lock_block.visible, "%s: the door is at %.1f deg, lock visible %s" % [label, rad_to_deg(hinge.rotation.y), lock_block.visible])
	Input.action_press("move_forward")
	await _wait_physics(120)
	Input.action_release("move_forward")
	_expect(failures, _depth(player, door_point) > 0.5, "%s: the player cannot walk through the opened door (depth %.2f)" % [label, _depth(player, door_point)])
	# The door is a plain door now: nobody asks again.
	_expect(failures, asked[0] == asked_before + 1, "%s: the unlocked door asked again" % label)
	await _unload(main)
	return failures

#endregion

#region Tutorial 04 (checked again): what the level builds from the plans

## Every room the player passes holds what its plan says: a lock on the door, one key at the planned spot, in the same room.
## (Props are checked by test_props_in_level.)
func test_locks_in_level() -> Array[String]:
	var failures: Array[String] = []
	for step in STEPS:
		var main := await _load_step(step, true, {"goal_room": 20})
		var level: Node3D = main.get_node("Level")
		var checked := {}
		var seen_locked := [0]
		var pilot := Autopilot.new(level)
		var on_tick := func() -> void:
			for index: int in level.rooms.keys():
				if checked.has(index):
					continue
				checked[index] = true
				var room: Node3D = level.rooms[index]
				var plan: Object = level.chain.plans[index]
				var door: Node3D = room.get("door")
				var keys := _keys_in(room)
				var where := "%s room %d" % [step, index]
				if plan.locked:
					seen_locked[0] += 1
				_expect(failures, (door == null) or (door.get("locked") == plan.locked and door.get("lock_block").visible == plan.locked), "%s: the door's lock does not match the plan (locked %s)" % [where, plan.locked])
				_expect(failures, keys.size() == (1 if plan.key_spot >= 0 else 0), "%s: %d keys, the plan has key spot %d" % [where, keys.size(), plan.key_spot])
				if keys.size() == 1 and plan.key_spot >= 0:
					var spot: Marker3D = room.get("key_spots")[plan.key_spot]
					_expect(failures, keys[0].get_parent() == room and keys[0].global_position.distance_to(spot.global_position) < 1e-4, "%s: the key is not at key spot %d" % [where, plan.key_spot])
					_expect(failures, (plan.bounds as AABB).has_point(keys[0].global_position + Vector3(0.0, 0.5, 0.0)), "%s: the key is outside its room" % where)
		_fast_forward(true)
		var arrived := await _walk(level, pilot, 8, 0, on_tick)
		_fast_forward(false)
		_expect(failures, arrived, "%s: the player did not reach room 8" % step)
		_expect(failures, seen_locked[0] >= 2, "%s: only %d locked rooms among the first 9 (seed 42 locks 3 and 4)" % [step, seen_locked[0]])
		await _unload(main)
	return failures

#endregion

#region Tutorial 04 (checked again): feedback for a refused door

func test_feedback(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_with_key(step)
	var level: Node3D = main.get_node("Level")
	var room: Node3D = level.rooms[1]
	var door: Node3D = room.get("door")
	var hinge: Node3D = door.get("hinge")
	var message: Label = main.get_node("HUD/MessageLabel")
	var timer: Timer = main.get_node("HUD/MessageTimer")
	var meshes: Array[MeshInstance3D] = [door.get_node("Hinge/Lock/Bar"), door.get_node("Hinge/Lock/Plate")]
	var shared := load(MATERIAL_DIR + "lock.tres") as StandardMaterial3D
	var rest_energy := shared.emission_energy_multiplier

	# The message label: its words, its place, its time. Hidden until a door says no.
	_expect(failures, message.text == "Locked: find the key" and not message.visible, "the message reads \"%s\", visible %s at the start" % [message.text, message.visible])
	_expect(failures, is_equal_approx(timer.wait_time, 1.5) and timer.one_shot, "the message timer is %.2f s, one shot %s" % [timer.wait_time, timer.one_shot])
	_expect(failures, message.get_theme_font_size("font_size") >= 40 and message.get_theme_constant("outline_size") >= 6 and message.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER, "the message is too small or has no outline")
	message.show()
	for screen_size: Vector2i in [Vector2i(1920, 1080), Vector2i(1280, 720)]:
		await _set_screen(screen_size)
		var screen := Rect2(Vector2.ZERO, Vector2(screen_size))
		var rect := message.get_global_rect()
		var where := "at %dx%d" % [screen_size.x, screen_size.y]
		_expect(failures, screen.encloses(rect), "%s: the message %s is not inside the screen" % [where, rect])
		_expect(failures, absf(rect.get_center().x - screen.size.x / 2.0) < 2.0, "%s: the message is not centred (%s)" % [where, rect.get_center()])
		_expect(failures, rect.get_center().y > screen.size.y * 0.6 and rect.get_center().y < screen.size.y * 0.85, "%s: the message is at %.0f percent of the height, expected the lower third" % [where, rect.get_center().y / screen.size.y * 100.0])
		_expect(failures, not rect.intersects((main.get_node("HUD/Stats") as Control).get_global_rect()) and not rect.intersects((main.get_node("HUD/DebugMap") as Control).get_global_rect()), "%s: the message overlaps the stats or the map" % where)
		_expect(failures, message.get_minimum_size().x <= message.size.x, "%s: the text needs %.0f px, the label is %.0f px wide" % [where, message.get_minimum_size().x, message.size.x])
	message.hide()

	# The knock: a player without a key walks up. Sample every physics frame from the moment of the question.
	var knock := {"asked": -1, "blocked": -1, "message_at_signal": false, "override_at_signal": false, "energy_at_signal": 0.0}
	door.connect("unlock_requested", func() -> void: knock["asked"] = Engine.get_physics_frames())
	level.connect("door_blocked", func() -> void:
		knock["blocked"] = Engine.get_physics_frames()
		knock["message_at_signal"] = message.visible
		knock["override_at_signal"] = meshes[0].material_override != null and meshes[1].material_override != null
		knock["energy_at_signal"] = (meshes[0].material_override as StandardMaterial3D).emission_energy_multiplier if meshes[0].material_override != null else 0.0)
	var samples: Array[Dictionary] = []
	await _stand_before_door(level, room, 5.0)
	Input.action_press("move_forward")
	var sampler := func() -> bool:
		samples.append({frame = Engine.get_physics_frames(), angle = hinge.rotation.y, message = message.visible, override = meshes[0].material_override != null})
		return (int(knock["asked"]) >= 0 and Engine.get_physics_frames() > int(knock["asked"]) + 150) or samples.size() > 600
	await _drive(sampler)
	Input.action_release("move_forward")
	_expect(failures, int(knock["asked"]) >= 0 and knock["blocked"] == knock["asked"], "the door asked in frame %s, the level said no in frame %s" % [knock["asked"], knock["blocked"]])
	var asked_at: int = knock["asked"]

	# The door rattles: it starts within one physics frame, gives a few degrees away from the player, never towards, and is still again.
	var onset := -1
	var peak := 0.0
	var toward := 0.0
	for sample in samples:
		if sample.frame < asked_at:
			continue
		if onset < 0 and absf(sample.angle) > 0.001:
			onset = sample.frame - asked_at
		peak = minf(peak, sample.angle)
		toward = maxf(toward, sample.angle)
	_expect(failures, onset >= 0 and onset <= 1, "the rattle started %d physics frames after the door was asked, expected at most 1" % onset)
	_expect(failures, peak < deg_to_rad(-3.0) and peak > deg_to_rad(-4.6), "the door gave %.1f deg at most, expected about 4" % rad_to_deg(peak))
	_expect(failures, toward < 0.0001, "the door swung %.2f deg towards the player" % rad_to_deg(toward))
	var settled := 0
	var still := true
	for sample in samples:
		if sample.frame >= asked_at + 30:
			settled += 1
			still = still and absf(sample.angle) < 0.002
	_expect(failures, settled > 60 and still, "the door does not come to rest within half a second")
	_expect(failures, not door.get("is_open") and door.get("locked") == true and level.keys == 0, "the refused door opened or lost its lock")

	# The lock flashes on the same frame, from a private copy; the shared material is never touched.
	_expect(failures, knock["override_at_signal"] and float(knock["energy_at_signal"]) >= 4.0, "the lock did not light up at once (override %s, energy %s)" % [knock["override_at_signal"], knock["energy_at_signal"]])
	_expect(failures, shared.emission_energy_multiplier == rest_energy and (meshes[0].mesh as PrimitiveMesh).material == shared, "the flash changed the shared lock.tres (emission %s, was %s)" % [shared.emission_energy_multiplier, rest_energy])
	var flash_ended := -1
	for sample in samples:
		if sample.frame >= asked_at and not sample.override:
			flash_ended = sample.frame - asked_at
			break
	_expect(failures, flash_ended > 12 and flash_ended <= 45, "the flash lasted %d physics frames, expected about 24" % flash_ended)

	# The words: on screen in the same frame, there for 1.5 s, then gone.
	_expect(failures, knock["message_at_signal"] == true, "the message was not up in the frame of the refusal")
	var last_visible := -1
	for sample in samples:
		if sample.frame >= asked_at and sample.message:
			last_visible = sample.frame - asked_at
	_expect(failures, last_visible >= 80 and last_visible <= 105, "the message stayed for %d physics frames (%.2f s), expected 90 (1.5 s)" % [last_visible, last_visible / 60.0])
	_expect(failures, not message.visible, "the message is still up after 2.5 s")
	print("        refusal: rattle starts %d physics frame(s) after the question, peak %.1f deg away from the player, lock flash %d frames, words up for %d frames (%.2f s)" % [onset, rad_to_deg(peak), flash_ended, last_visible, last_visible / 60.0])

	# Another refusal while the words are up starts the 1.5 s again (it does not cut the second one short).
	level.emit_signal("door_blocked")
	await _wait_physics(70)
	level.emit_signal("door_blocked")
	await _wait_physics(70)
	_expect(failures, message.visible, "the second refusal did not restart the time")
	await _wait_physics(40)
	_expect(failures, not message.visible, "the message did not go away after the second refusal")

	# A new run starts without the old words.
	level.emit_signal("door_blocked")
	await _action("regenerate")
	await _wait_physics(5)
	_expect(failures, not message.visible, "R left the message up")
	await _unload(main)
	return failures

## With a key: no rattle, no words, the lock falls off the door and fades, the door opens.
func test_unlock_animation(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_with_key(step)
	var level: Node3D = main.get_node("Level")
	var room: Node3D = level.rooms[1]
	var door: Node3D = room.get("door")
	var hinge: Node3D = door.get("hinge")
	var lock_block: Node3D = door.get("lock_block")
	var meshes: Array[MeshInstance3D] = [door.get_node("Hinge/Lock/Bar"), door.get_node("Hinge/Lock/Plate")]
	var message: Label = main.get_node("HUD/MessageLabel")
	var blocked := [0]
	level.connect("door_blocked", func() -> void: blocked[0] += 1)
	_expect(failures, await _walk_into(level, room, _keys_in(room)[0]), "the key was not picked up")
	await _stand_before_door(level, room, 5.0)
	var rest_y := lock_block.position.y
	var samples: Array[Dictionary] = []
	var asked := [-1]
	door.connect("unlock_requested", func() -> void: asked[0] = Engine.get_physics_frames())
	Input.action_press("move_forward")
	var sampler := func() -> bool:
		samples.append({frame = Engine.get_physics_frames(), y = lock_block.position.y, visible = lock_block.visible, fade = meshes[0].transparency, open = door.get("is_open"), angle = hinge.rotation.y, message = message.visible, override = meshes[0].material_override != null})
		return asked[0] >= 0 and Engine.get_physics_frames() > int(asked[0]) + 80
	await _drive(sampler)
	Input.action_release("move_forward")
	_expect(failures, asked[0] >= 0 and blocked[0] == 0, "asked %s, door_blocked %d times with a key" % [asked[0], blocked[0]])
	var after: Array[Dictionary] = []
	for sample in samples:
		if sample.frame >= asked[0]:
			after.append(sample)
	_expect(failures, after.size() > 60, "only %d samples after the question" % after.size())
	if after.size() > 60:
		_expect(failures, after[1].open == true or after[0].open == true, "the door is not open one frame after the question")
		var mid := after[10] # a sixth of a second in: the lock is falling and fading, still on the door
		_expect(failures, mid.visible and mid.y < rest_y - 0.02 and mid.y > rest_y - DOOR_DROP and mid.fade > 0.02 and mid.fade < 1.0, "10 frames in the lock is at %.2f (rest %.2f), faded %.2f, visible %s: not falling and fading" % [mid.y, rest_y, mid.fade, mid.visible])
		var late := after[40]
		_expect(failures, not late.visible and late.fade >= 0.999 and late.y <= rest_y - DOOR_DROP + 0.01, "40 frames in the lock is visible %s at %.2f, faded %.2f" % [late.visible, late.y, late.fade])
		var open_wide := after[36] # 0.6 s: the swing (0.5 s) is done, the player is not through yet, so the door behind has not been told to close
		_expect(failures, absf(open_wide.angle - (-PI / 2.0)) < 0.03, "the door is at %.1f deg 0.6 s after the unlock" % rad_to_deg(open_wide.angle))
		var rattled := false
		for sample in after:
			rattled = rattled or sample.override or sample.message
		_expect(failures, not rattled, "an unlocked door flashed or showed the message")
		var toward := 0.0
		for sample in after:
			toward = maxf(toward, sample.angle)
		_expect(failures, toward < 0.0001, "the door swung towards the player")
	await _unload(main)
	return failures

const DOOR_DROP := 0.6 ## door.gd's DROP_DISTANCE, the lock's fall in metres.

#endregion

#region Runs that fetch keys

## Runs the autopilot from room 0 to the goal pad. Returns what happened.
func _full_run(chain_seed: int, goal_room: int, chance: float) -> Dictionary:
	var path := _fresh_save_path()
	var main := await _load_step(FINAL_STEP, true, {"save_path": path, "goal_room": goal_room, "chain_seed": chain_seed, "lock_chance": chance})
	var level: Node3D = main.get_node("Level")
	var key_counts: Array[int] = []
	level.connect("keys_changed", func(count: int) -> void: key_counts.append(count))
	var blocked := [0]
	level.connect("door_blocked", func() -> void: blocked[0] += 1)
	var built := [_props_in(level.rooms[0]).size()]
	level.connect("room_entered", func(index: int) -> void: built[0] += _props_in(level.rooms[index]).size())
	var vault_height := [0.0]
	var on_tick := func() -> void:
		if level.chain.plans[level.current].type == Chain.Type.VAULT:
			vault_height[0] = maxf(vault_height[0], level.player.global_position.y)
	_fast_forward(true)
	var finished := await _walk_to_finish(level, Autopilot.new(level), 0, 60 * 60 * 6, on_tick)
	_fast_forward(false)
	var locked: Array[int] = []
	var vaults: Array[int] = []
	var locked_vaults := 0
	for plan: Object in level.chain.plans:
		if plan.locked:
			locked.append(plan.index)
			locked_vaults += 1 if plan.type == Chain.Type.VAULT and plan.index <= level.current else 0
		if plan.type == Chain.Type.VAULT and plan.index <= level.current:
			vaults.append(plan.index)
	var result := {finished = finished, time = level.run_time, key_counts = key_counts, locked = locked, blocked = blocked[0], room = level.current, goal = level.chain.goal_index, keys = level.keys, props = built[0], vaults = vaults, locked_vaults = locked_vaults, vault_height = vault_height[0], position = level.player.global_position}
	await _unload(main)
	return result

func test_more_full_runs() -> Array[String]:
	var failures: Array[String] = []
	# A seed with an early vault at lock chance 1: the vault is locked, its key is fetched, the platform is crossed.
	var vault_seed := 0
	for chain_seed in range(1, 300):
		var plans: Array = _plans_to_goal(Chain, chain_seed, 8, 1.0).plans
		if plans.any(func(plan: Object) -> bool: return plan.type == Chain.Type.VAULT and plan.index <= 5):
			vault_seed = chain_seed
			break
	_expect(failures, vault_seed > 0, "no seed with an early vault in 300")
	var runs: Array[Dictionary] = [
		{chain_seed = 43, goal_room = 20, chance = LOCK_CHANCE},
		{chain_seed = 7, goal_room = 20, chance = LOCK_CHANCE},
		{chain_seed = 3, goal_room = 20, chance = LOCK_CHANCE},
		{chain_seed = 42, goal_room = 8, chance = 1.0},
		{chain_seed = vault_seed, goal_room = 8, chance = 1.0},
	]
	for spec in runs:
		var result := await _full_run(spec.chain_seed, spec.goal_room, spec.chance)
		var label := "seed %d, goal room %d, lock chance %.1f" % [spec.chain_seed, spec.goal_room, spec.chance]
		var expected: Array[int] = []
		var locked_count: int = result.locked.size()
		for i in locked_count:
			expected.append_array([1, 0])
		_expect(failures, result.finished and result.room == result.goal and result.keys == 0, "%s: did not finish (room %d of %d, keys %d, stopped at %s)" % [label, result.room, result.goal, result.keys, result.position])
		_expect(failures, result.key_counts == expected, "%s: key counts %s for locked rooms %s: every lock needs its key picked up and used up once" % [label, result.key_counts, result.locked])
		_expect(failures, result.blocked == 0, "%s: the autopilot, which fetches the key first, was refused %d times" % [label, result.blocked])
		_expect(failures, result.vaults.is_empty() or result.vault_height > 0.1, "%s: vaults %s, but the player never climbed a platform (highest %.3f)" % [label, result.vaults, result.vault_height])
		print("        %s: %d locked rooms %s, vaults %s (%d locked), %d props built, finished in %.1f s of game time" % [label, result.locked.size(), result.locked, result.vaults, result.locked_vaults, result.props, result.time])
	return failures

## The worst case for "props never block the way": every prop spot holds the biggest prop its room type has. The rules say
## this cannot block a path; here the real player walks it. The sets are put back afterwards.
func test_full_runs_all_spots_filled() -> Array[String]:
	var failures: Array[String] = []
	var saved_weights: Array[Array] = []
	var saved_empty: Array[float] = []
	for prop_set in Chain.PROP_SETS:
		saved_weights.append(prop_set.weights.duplicate())
		saved_empty.append(prop_set.empty_weight)
		var biggest := 0
		var area := 0.0
		for i in prop_set.scenes.size():
			var foot := Contents.footprint(prop_set.scenes[i], Transform3D.IDENTITY)
			if foot.get_area() > area:
				area = foot.get_area()
				biggest = i
		var weights: Array[float] = prop_set.weights.duplicate()
		for i in weights.size():
			weights[i] = 1.0 if i == biggest else 0.0
		prop_set.weights = weights
		prop_set.empty_weight = 0.0
	for spec: Dictionary in [{chain_seed = 42, goal_room = 20}, {chain_seed = 3, goal_room = 20}, {chain_seed = 7, goal_room = 20}]:
		var result := await _full_run(spec.chain_seed, spec.goal_room, LOCK_CHANCE)
		var label := "seed %d with every spot filled" % spec.chain_seed
		_expect(failures, result.finished and result.room == result.goal and result.keys == 0, "%s: did not finish (room %d of %d, stopped at %s)" % [label, result.room, result.goal, result.position])
		_expect(failures, result.props >= 80, "%s: only %d props were built" % [label, result.props])
		print("        %s: %d props built, %d locked rooms, vaults %s, finished in %.1f s of game time" % [label, result.props, result.locked.size(), result.vaults, result.time])
	for type in Chain.PROP_SETS.size():
		Chain.PROP_SETS[type].weights = saved_weights[type]
		Chain.PROP_SETS[type].empty_weight = saved_empty[type]
	return failures

#endregion

#region Tutorial 05: source rules for data

## Props and room weights are data: a Resource script with exports, .tres files, and a chain that only rolls and walks.
func test_data_rules() -> Array[String]:
	var failures: Array[String] = []
	for step in _steps_from("step_02_prop_sets"):
		var set_source := FileAccess.get_file_as_string("res://steps/%s/prop_set.gd" % step)
		_expect(failures, set_source.contains("extends Resource") and set_source.count("@export var") == 3 and not set_source.contains("func "), "%s/prop_set.gd is not a plain data Resource with its three exports" % step)
		for export_name: String in ["scenes", "weights", "empty_weight"]:
			_expect(failures, set_source.contains("@export var %s" % export_name), "%s/prop_set.gd has no export %s" % [step, export_name])
		var chain_source := FileAccess.get_file_as_string("res://steps/%s/room_chain.gd" % step)
		_expect(failures, not chain_source.contains("PROP_CHANCE") and not chain_source.contains("PROP_SCENES"), "%s: the chain still has step 1's fixed chance or prop list" % step)
		_expect(failures, chain_source.contains("static func weighted_pick(weights: Array[float], roll: float) -> int:"), "%s: no weighted_pick(weights, roll)" % step)
		var pick := _function_body(chain_source, "static func weighted_pick(")
		_expect(failures, not pick.contains("rand") and not pick.contains("PROP") and not pick.contains("ROOM"), "%s: weighted_pick rolls dice or knows the data: it only sums, compares and walks" % step)
		for file in DirAccess.get_files_at("res://steps/%s/props" % step):
			if file.ends_with(".tres"):
				var text := FileAccess.get_file_as_string("res://steps/%s/props/%s" % [step, file])
				_expect(failures, text.begins_with("[gd_resource type=\"Resource\"") and text.contains("res://steps/%s/prop_set.gd" % step) and text.contains("scenes = Array[PackedScene]") and text.contains("weights = Array[float]"), "%s/props/%s is not a prop set resource of its own step" % [step, file])
	for step in _steps_from("step_03_weighted_rooms"):
		var weights_source := FileAccess.get_file_as_string("res://steps/%s/room_weights.gd" % step)
		_expect(failures, weights_source.contains("extends Resource") and weights_source.count("func ") == 1 and weights_source.contains("func weight_of(type: int) -> float:"), "%s/room_weights.gd is not a data Resource with one lookup" % step)
		var text := FileAccess.get_file_as_string("res://steps/%s/room_weights.tres" % step)
		_expect(failures, text.contains("res://steps/%s/room_weights.gd" % step), "%s/room_weights.tres does not use its own step's script" % step)
		var chain_source := FileAccess.get_file_as_string("res://steps/%s/room_chain.gd" % step)
		var chain_code := "\n".join(_code_lines("res://steps/%s/room_chain.gd" % step))
		_expect(failures, not chain_code.contains("_shuffled_types") and not chain_code.contains(".shuffle(") and chain_code.contains("func _weighted_types() -> Array[int]:"), "%s: the chain still shuffles the room types" % step)
		_expect(failures, chain_source.contains("ROOM_WEIGHTS.weight_of(type)"), "%s: the chain does not read its room weights from the Resource" % step)
	return failures

#endregion

#region Tutorial 05: props, scenes and spots

func _prop_scene(step: String, prop_name: String) -> PackedScene:
	return load("res://steps/%s/props/%s.tscn" % [step, prop_name]) as PackedScene

## The top of a prop's collision shapes, in metres above the floor.
func _prop_height(prop: Node) -> float:
	var top := 0.0
	for child in prop.get_children():
		var shape_node := child as CollisionShape3D
		if shape_node == null:
			continue
		var half_height := 0.0
		if shape_node.shape is BoxShape3D:
			half_height = (shape_node.shape as BoxShape3D).size.y / 2.0
		elif shape_node.shape is CylinderShape3D:
			half_height = (shape_node.shape as CylinderShape3D).height / 2.0
		top = maxf(top, shape_node.position.y + half_height)
	return top

func test_prop_scenes(step: String) -> Array[String]:
	var failures: Array[String] = []
	var expected: Dictionary[String, Vector2] = { # the footprint in metres: width (x) and depth (z)
		"crate": Vector2(1.0, 1.0), "stack": Vector2(1.2, 1.2), "table": Vector2(1.6, 0.9), "shelf": Vector2(1.6, 0.4), "pillar": Vector2(0.7, 0.7),
	}
	var heights: Dictionary[String, Vector2] = { # the allowed range of the height
		"crate": Vector2(0.99, 1.01), "stack": Vector2(1.7, 1.9), "table": Vector2(0.75, 1.0), "shelf": Vector2(1.8, 2.2), "pillar": Vector2(2.99, 3.0),
	}
	var files := DirAccess.get_files_at("res://steps/%s/props" % step)
	var scene_files: Array[String] = []
	for file in files:
		if file.ends_with(".tscn"):
			scene_files.append(file)
	scene_files.sort()
	var wanted: Array[String] = []
	for prop_name in PROP_NAMES:
		wanted.append(prop_name + ".tscn")
	wanted.sort()
	_expect(failures, scene_files == wanted, "props/ has %s, expected %s" % [scene_files, wanted])
	for prop_name in PROP_NAMES:
		var scene := _prop_scene(step, prop_name)
		var prop := scene.instantiate()
		var label := "%s/props/%s.tscn" % [step, prop_name]
		_expect(failures, prop is StaticBody3D and prop.get_script() == null, "%s: the root is not a plain StaticBody3D" % label)
		var body := prop as StaticBody3D
		_expect(failures, body != null and body.collision_layer == 1, "%s: collision layer %d, expected 1 (the world layer: the player collides with it)" % [label, body.collision_layer if body != null else -1])
		var shapes := 0
		var meshes := 0
		for node in prop.find_children("*", "", true, false):
			if node is CollisionShape3D:
				shapes += 1
				_expect(failures, (node as CollisionShape3D).shape is BoxShape3D or (node as CollisionShape3D).shape is CylinderShape3D, "%s: %s has a shape the footprint check does not know" % [label, node.name])
			elif node is MeshInstance3D:
				meshes += 1
				var mesh := (node as MeshInstance3D).mesh
				_expect(failures, mesh is PrimitiveMesh and (mesh as PrimitiveMesh).material != null and (mesh as PrimitiveMesh).material.resource_path == MATERIAL_DIR + "prop.tres", "%s: %s does not use prop.tres" % [label, node.name])
				_expect(failures, (node as MeshInstance3D).layers == 1, "%s: %s is not on render layer 1 only" % [label, node.name])
		_expect(failures, shapes >= 1 and meshes >= 1, "%s: %d shapes and %d meshes" % [label, shapes, meshes])
		var foot := Contents.footprint(scene, Transform3D.IDENTITY)
		_expect(failures, absf(foot.size.x - expected[prop_name].x) < 0.01 and absf(foot.size.y - expected[prop_name].y) < 0.01, "%s: the footprint is %.2f x %.2f m, expected %.1f x %.1f" % [label, foot.size.x, foot.size.y, expected[prop_name].x, expected[prop_name].y])
		_expect(failures, absf(foot.end.y) < 0.001 and absf(foot.get_center().x) < 0.06, "%s: the footprint %s does not sit with its back edge at z = 0, centred on x" % [label, foot])
		var height := _prop_height(prop)
		_expect(failures, height >= heights[prop_name].x and height <= heights[prop_name].y, "%s: %.2f m high, expected %.2f to %.2f" % [label, height, heights[prop_name].x, heights[prop_name].y])
		# What is drawn is what is solid: the meshes cover the same floor as the shapes.
		var drawn := Rect2()
		var first := true
		for node in prop.find_children("*", "MeshInstance3D", true, false):
			var box := (node as MeshInstance3D).transform * (node as MeshInstance3D).mesh.get_aabb()
			var rect := Rect2(Vector2(box.position.x, box.position.z), Vector2(box.size.x, box.size.z))
			drawn = rect if first else drawn.merge(rect)
			first = false
		_expect(failures, absf(drawn.position.x - foot.position.x) < 0.05 and absf(drawn.end.x - foot.end.x) < 0.05 and absf(drawn.position.y - foot.position.y) < 0.05 and absf(drawn.end.y - foot.end.y) < 0.05, "%s: the meshes cover %s but the shapes %s" % [label, drawn, foot])
		prop.free()
	return failures

func test_prop_spots(step: String) -> Array[String]:
	var failures: Array[String] = []
	var finals := _final_spots()
	for room_type in _room_types_of(step):
		var room := (load("res://steps/%s/room_%s.tscn" % [step, room_type]) as PackedScene).instantiate() as Node3D
		var label := "%s room_%s" % [step, room_type]
		var container := room.get_node_or_null("PropSpots")
		_expect(failures, container != null and container is Node3D and (container as Node3D).transform == Transform3D.IDENTITY, "%s has no PropSpots node at the room's origin" % label)
		if container == null:
			room.free()
			continue
		var spots: Array[Marker3D] = []
		for child in container.get_children():
			_expect(failures, child is Marker3D, "%s/PropSpots/%s is not a Marker3D" % [label, child.name])
			spots.append(child as Marker3D)
		_expect(failures, spots.size() >= 4 and spots.size() <= 6, "%s has %d prop spots, expected 4 to 6" % [label, spots.size()])
		var floor_box := room.get_node("Shell/Floor") as CSGBox3D
		var half := Vector2(floor_box.size.x, floor_box.size.z) / 2.0 - Vector2(WALL_THICKNESS, WALL_THICKNESS) # the inside of the walls
		var entrance := room.get_node("Entrance") as Marker3D
		var exit_point := room.get_node("Exit") as Marker3D
		var line_from := Vector2(entrance.position.x, entrance.position.z)
		var line_to := Vector2(exit_point.position.x, exit_point.position.z)
		var keys: Array[Vector2] = []
		for key in room.get_node("KeySpots").get_children():
			keys.append(Vector2((key as Marker3D).position.x, (key as Marker3D).position.z))
		for i in spots.size():
			var spot := spots[i]
			var at := Vector2(spot.position.x, spot.position.z)
			var front := Vector2(-spot.transform.basis.z.x, -spot.transform.basis.z.z)
			var name := "%s %s" % [label, spot.name]
			_expect(failures, is_zero_approx(spot.position.y), "%s is %.2f m above the floor" % [name, spot.position.y])
			_expect(failures, spot.transform.basis.y.is_equal_approx(Vector3.UP) and (is_equal_approx(absf(front.x), 1.0) and is_zero_approx(front.y) or is_equal_approx(absf(front.y), 1.0) and is_zero_approx(front.x)), "%s does not face along an axis of the room (front %s)" % [name, front])
			# The back of a prop is against the wall behind the spot, 5 cm away from it, and the prop faces into the room.
			var along_half := half.x if absf(front.x) > 0.5 else half.y
			var back_distance := at.dot(front) + along_half
			_expect(failures, absf(back_distance - 0.05) < 0.001, "%s is %.3f m from the wall behind it, expected 0.05" % [name, back_distance])
			_expect(failures, (Vector2.ZERO - at).dot(front) > 1.0, "%s does not face into the room" % name)
			_expect(failures, Geometry2D.get_closest_point_to_segment(at, line_from, line_to).distance_to(at) >= Contents.CORRIDOR_WIDTH / 2.0, "%s is on the walking line from the entrance to the exit" % name)
			for key in keys:
				_expect(failures, at.distance_to(key) >= 1.0, "%s is %.2f m from a key spot" % [name, at.distance_to(key)])
			for j in range(i + 1, spots.size()):
				_expect(failures, at.distance_to(Vector2(spots[j].position.x, spots[j].position.z)) >= 1.5, "%s and %s are less than 1.5 m apart" % [name, spots[j].name])
			# Every step puts them where the finished rooms have them.
			_expect(failures, i < (finals[room_type] as Array).size() and (finals[room_type] as Array)[i] == spot.transform, "%s is not where the finished room has it" % name)
		_expect(failures, spots.size() == (finals[room_type] as Array).size(), "%s has %d prop spots, the finished room has %d" % [label, spots.size(), (finals[room_type] as Array).size()])
		room.free()
	var goal := (load("res://steps/%s/room_goal.tscn" % step) as PackedScene).instantiate()
	_expect(failures, goal.get_node_or_null("PropSpots") == null, "%s: the goal room has prop spots" % step)
	goal.free()
	return failures

## The prop spots of the finished rooms, by room type: the spot transforms in scene order.
func _final_spots() -> Dictionary:
	var spots := {}
	for room_type in _room_types_of(FINAL_STEP):
		var room := (load("res://steps/%s/room_%s.tscn" % [FINAL_STEP, room_type]) as PackedScene).instantiate() as Node3D
		var list: Array[Transform3D] = []
		for child in room.get_node("PropSpots").get_children():
			list.append((child as Marker3D).transform)
		spots[room_type] = list
		room.free()
	return spots

## The prop bodies in a room: direct children that are static bodies (the door's hinge is deeper down).
func _props_in(room: Node3D) -> Array[Node3D]:
	var found: Array[Node3D] = []
	for child in room.get_children():
		if child is StaticBody3D and not child.is_queued_for_deletion():
			found.append(child as Node3D)
	return found

## How many prop spots a room type of a step has, by the type's name in the Type enum ("goal" has none).
func _prop_spot_count(step: String, type_name: String) -> int:
	if type_name == "goal":
		return 0
	var room := (load("res://steps/%s/room_%s.tscn" % [step, type_name]) as PackedScene).instantiate()
	var count := room.get_node("PropSpots").get_child_count()
	room.free()
	return count

func test_prop_determinism(step: String) -> Array[String]:
	var failures: Array[String] = []
	var chain_script := _chain_script(step)
	var first := _plans(chain_script, 42, 100)
	var second := _plans(chain_script, 42, 100)
	var other := _plans(chain_script, 43, 100)
	var any_props := 0
	var props_differ := false
	for i in first.size():
		var plan: Object = first[i]
		var type_name := _room_name(chain_script, plan.type)
		var spot_count := _prop_spot_count(step, type_name)
		_expect(failures, plan.props.size() == spot_count, "room %d (%s) has %d props for %d prop spots" % [i, type_name, plan.props.size(), spot_count])
		var kinds := 0
		if plan.props.size() > 0:
			kinds = chain_script.PROP_SCENES.size() if step == "step_01_prop_spots" else chain_script.PROP_SETS[plan.type].scenes.size()
		for prop: int in plan.props:
			_expect(failures, prop >= -1 and prop < kinds, "room %d holds prop %d of %d" % [i, prop, kinds])
			any_props += 1 if prop >= 0 else 0
		_expect(failures, plan.props == second[i].props, "seed 42 twice: room %d has other props" % i)
		props_differ = props_differ or plan.props != other[i].props
	_expect(failures, any_props >= 100, "only %d props in 100 rooms" % any_props)
	_expect(failures, props_differ, "seed 43 has the props of seed 42")
	# A room's props depend on the seed, the room's index and its type only: not on the lock chance, not on the goal room.
	for chance: float in [0.0, 1.0]:
		var again := _plans(chain_script, 42, 100, chance)
		for i in 100:
			_expect(failures, again[i].props == first[i].props, "room %d has other props at lock chance %.1f" % [i, chance])
	var near := _plans_to_goal(chain_script, 42, 12)
	for i in 12:
		_expect(failures, near.plans[i].props == first[i].props, "room %d has other props with a goal room at 12" % i)
	# The goal room holds nothing.
	var goal_plan: Object = near.plans[-1]
	_expect(failures, goal_plan.type == _goal_type(chain_script) and goal_plan.props.is_empty(), "the goal room holds %s" % [goal_plan.props])
	return failures

func test_props_in_level(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step, true, {"goal_room": 20})
	var level: Node3D = main.get_node("Level")
	var checked := {}
	var built := [0]
	var pilot := Autopilot.new(level)
	var on_tick := func() -> void:
		for index: int in level.rooms.keys():
			if checked.has(index):
				continue
			checked[index] = true
			failures.append_array(_room_props_problems(step, level, index))
			built[0] += _props_in(level.rooms[index]).size()
	_fast_forward(true)
	var arrived := await _walk(level, pilot, 8, 0, on_tick)
	_fast_forward(false)
	_expect(failures, arrived, "%s: the player did not reach room 8" % step)
	_expect(failures, built[0] >= 15, "%s: only %d props were built in the first 9 rooms" % [step, built[0]])
	# Props go with their room: no prop body is left in the tree that does not belong to a live room.
	await _wait_physics(5)
	var expected := 0
	for index: int in level.rooms.keys():
		for placed: int in level.chain.plans[index].props:
			expected += 1 if placed != Chain.NO_PROP else 0
	var in_tree := 0
	for body in level.find_children("*", "StaticBody3D", true, false):
		if not body.is_queued_for_deletion() and body.get_parent().get("prop_spots") != null:
			in_tree += 1
	_expect(failures, in_tree == expected, "%s: %d prop bodies in the tree, the live rooms hold %d" % [step, in_tree, expected])
	# R builds room 0 again with its props, and the old rooms' props are gone.
	await _action("regenerate")
	await _wait_physics(5)
	failures.append_array(_room_props_problems(step, level, 0))
	in_tree = 0
	for body in level.find_children("*", "StaticBody3D", true, false):
		if not body.is_queued_for_deletion() and body.get_parent().get("prop_spots") != null:
			in_tree += 1
	_expect(failures, in_tree == _props_in(level.rooms[0]).size(), "%s: %d prop bodies after R, room 0 holds %d" % [step, in_tree, _props_in(level.rooms[0]).size()])
	await _unload(main)
	return failures

## Everything a plan says about the props of one live room, checked against the room: as problems.
func _room_props_problems(step: String, level: Node3D, index: int) -> Array[String]:
	var problems: Array[String] = []
	var room: Node3D = level.rooms[index]
	var plan: Object = level.chain.plans[index]
	var bodies := _props_in(room)
	var placed: Array[int] = []
	for i: int in plan.props.size():
		if plan.props[i] != Chain.NO_PROP:
			placed.append(i)
	var where := "%s room %d" % [step, index]
	_expect(problems, bodies.size() == placed.size(), "%s: %d props in the room, the plan places %d" % [where, bodies.size(), placed.size()])
	_expect(problems, (room.get("prop_spots") as Array).size() == plan.props.size(), "%s: the room has %d prop spots, the plan %d entries" % [where, (room.get("prop_spots") as Array).size(), plan.props.size()])
	for k in mini(bodies.size(), placed.size()):
		var spot: Marker3D = (room.get("prop_spots") as Array)[placed[k]]
		var scene: PackedScene = level.chain.prop_scene(plan.type, plan.props[placed[k]])
		_expect(problems, bodies[k].transform == spot.transform and bodies[k].get_parent() == room, "%s: prop %d is not on its spot %d" % [where, k, placed[k]])
		_expect(problems, bodies[k].scene_file_path == scene.resource_path, "%s: prop %d is %s, the plan says %s" % [where, k, bodies[k].scene_file_path, scene.resource_path])
		_expect(problems, (plan.bounds as AABB).has_point(bodies[k].global_position + Vector3(0.0, 0.5, 0.0)), "%s: prop %d is outside its room" % [where, k])
	return problems

#endregion

#region Tutorial 05: the spot rules, exhaustively

## The rules of check_contents.gd, for every prop at every spot of every room type, and for every pair of spots:
## whatever the dice give, the rules hold. Every set is widened to all five props for this, so step 1's "any prop
## anywhere" is covered, too; the sets are put back afterwards.
func test_prop_spot_rules() -> Array[String]:
	var failures: Array[String] = []
	var layouts := Contents.read_layouts()
	var chain := Chain.new(1, 20)
	var all_five: Array[PackedScene] = []
	for prop_name in PROP_NAMES:
		all_five.append(_prop_scene(FINAL_STEP, prop_name))
	var ones: Array[float] = [1.0, 1.0, 1.0, 1.0, 1.0]
	var saved_scenes: Array[Array] = []
	var saved_weights: Array[Array] = []
	for prop_set in Chain.PROP_SETS:
		saved_scenes.append(prop_set.scenes.duplicate())
		saved_weights.append(prop_set.weights.duplicate())
		prop_set.scenes = all_five
		prop_set.weights = ones
	var singles := 0
	var pairs := 0
	for type in Chain.PROP_SETS.size():
		var spot_count := layouts[type].prop_spots.size()
		_expect(failures, spot_count >= 3, "%s has %d prop spots" % [_room_name(Chain, type), spot_count])
		for spot in spot_count:
			for prop in all_five.size():
				var plan := _plan_with(type, spot_count, {spot: prop})
				singles += 1
				for problem in Contents._room_problems(chain, plan, layouts[type]):
					failures.append(problem)
				for other in range(spot + 1, spot_count):
					for other_prop in all_five.size():
						pairs += 1
						for problem in Contents._room_problems(chain, _plan_with(type, spot_count, {spot: prop, other: other_prop}), layouts[type]):
							failures.append(problem)
		if failures.size() > 8:
			break
	for type in Chain.PROP_SETS.size():
		Chain.PROP_SETS[type].scenes = saved_scenes[type]
		Chain.PROP_SETS[type].weights = saved_weights[type]
	print("        %d single props and %d pairs of props over the prop spots of %d room types: no rule broken" % [singles, pairs, Chain.PROP_SETS.size()])
	return failures

## A plan of this room type whose prop spots are empty but for the ones given (spot -> prop index).
func _plan_with(type: int, spot_count: int, placed: Dictionary) -> Chain.Plan:
	var plan := Chain.Plan.new(0, type, Transform3D.IDENTITY, AABB())
	for spot in spot_count:
		plan.props.append(int(placed[spot]) if placed.has(spot) else Chain.NO_PROP)
	return plan

func test_props_are_solid() -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(FINAL_STEP, true, {"goal_room": 6, "lock_chance": 0.0})
	var level: Node3D = main.get_node("Level")
	var player: CharacterBody3D = level.player
	var room: Node3D = level.rooms[0]
	var bodies := _props_in(room)
	_expect(failures, bodies.size() >= 2, "room 0 holds only %d props" % bodies.size())
	var tested := 0
	for body in bodies:
		var depth := Contents.footprint(load(body.scene_file_path) as PackedScene, Transform3D.IDENTITY).size.y
		var front: Vector3 = -body.transform.basis.z # the way the prop faces
		var face := body.global_position + front * depth # the middle of its front face on the floor
		var start := face + front * 2.0
		var local_start: Vector3 = room.global_transform.affine_inverse() * start
		if absf(local_start.x) > 4.0 or absf(local_start.z) > 4.0:
			continue
		var clear := true
		for other in bodies:
			if other != body:
				clear = clear and other.global_position.distance_to(start) > 2.2
		if not clear:
			continue
		# A ray at the height of a hip hits the prop from the front.
		var ray := PhysicsRayQueryParameters3D.create(face + front * 1.0 + Vector3(0.0, 0.5, 0.0), face - front * 0.2 + Vector3(0.0, 0.5, 0.0))
		var hit := level.get_world_3d().direct_space_state.intersect_ray(ray)
		_expect(failures, not hit.is_empty() and hit["collider"] == body, "a ray at 0.5 m does not hit %s" % body.name)
		# The player walks into it from 2 m away and stops at its face.
		player.global_position = start
		player.rotation.y = atan2(front.x, front.z) # facing -front, which is -Z of the player's own basis
		player.velocity = Vector3.ZERO
		await _wait_physics(3)
		Input.action_press("move_forward")
		await _wait_physics(80)
		Input.action_release("move_forward")
		var stopped := (player.global_position - face).dot(front)
		_expect(failures, stopped > 0.38 and stopped < 0.6, "%s: the player stopped %.2f m from the face, expected the capsule radius (0.4) plus a skin" % [body.name, stopped])
		_expect(failures, absf(player.global_position.y) < 0.05, "%s: the player climbed or fell (y = %.2f)" % [body.name, player.global_position.y])
		tested += 1
	_expect(failures, tested >= 1, "no prop of room 0 could be walked into")
	await _unload(main)
	return failures

func test_step_one_props() -> Array[String]:
	var failures: Array[String] = []
	var chain_script := _chain_script("step_01_prop_spots")
	var spots := 0
	var placed := 0
	var kinds := [0, 0, 0, 0, 0]
	for chain_seed in range(1, 301):
		if chain_seed % 50 == 0:
			await process_frame
		for plan: Object in _plans(chain_script, chain_seed, 30):
			for prop: int in plan.props:
				spots += 1
				if prop != chain_script.NO_PROP:
					placed += 1
					kinds[prop] += 1
	var share := float(placed) / float(spots)
	_expect(failures, absf(share - 0.5) < 0.02, "%.3f of the %d spots hold a prop, step 1 says half" % [share, spots])
	for prop in 5:
		_expect(failures, absf(float(kinds[prop]) / float(placed) - 0.2) < 0.02, "%s is %.3f of the props, expected a fifth" % [PROP_NAMES[prop], float(kinds[prop]) / float(placed)])
	print("        step 1, seeds 1-300 x 30 rooms: %d of %d spots hold a prop (%.3f), by kind %s" % [placed, spots, share, kinds])
	return failures

#endregion

#region Tutorial 05: prop sets, the weighted pick, room weights

func test_prop_sets(step: String) -> Array[String]:
	var failures: Array[String] = []
	var chain_script := _chain_script(step)
	var names: Array[String] = ["straight", "long", "turn_left", "turn_right", "wide"]
	if STEPS.find(step) >= STEPS.find("step_04_rare_rooms"):
		names.append("vault")
	var prop_set_script := load("res://steps/%s/prop_set.gd" % step) as GDScript
	_expect(failures, chain_script.PROP_SETS.size() == names.size(), "%s: %d sets for %d room types" % [step, chain_script.PROP_SETS.size(), names.size()])
	var share_of := func(prop_set: Resource, wanted: Array[String]) -> float:
		var part := 0.0
		var total := 0.0
		for i: int in prop_set.scenes.size():
			total += prop_set.weights[i]
			if wanted.has((prop_set.scenes[i] as PackedScene).resource_path.get_file().get_basename()):
				part += prop_set.weights[i]
		return part / total
	for i in names.size():
		var path := "res://steps/%s/props/%s_set.tres" % [step, names[i]]
		var prop_set := load(path) as Resource
		_expect(failures, prop_set != null and prop_set.get_script() == prop_set_script, "%s is not a PropSet of its own step" % path)
		if prop_set == null:
			continue
		_expect(failures, chain_script.PROP_SETS[i] == prop_set, "%s: PROP_SETS[%d] is not %s_set.tres" % [step, i, names[i]])
		var scenes: Array = prop_set.scenes
		var weights: Array = prop_set.weights
		_expect(failures, scenes.size() == weights.size() and scenes.size() >= 3, "%s has %d scenes and %d weights" % [path, scenes.size(), weights.size()])
		var total: float = prop_set.empty_weight
		var seen := {}
		for k in mini(scenes.size(), weights.size()):
			total += weights[k]
			_expect(failures, weights[k] > 0.0, "%s: weight %d is %s" % [path, k, weights[k]])
			var scene_path: String = (scenes[k] as PackedScene).resource_path
			_expect(failures, scene_path.begins_with("res://steps/%s/props/" % step) and PROP_NAMES.has(scene_path.get_file().get_basename()) and not seen.has(scene_path), "%s: scene %d (%s) is not one of this step's props, or is listed twice" % [path, k, scene_path])
			seen[scene_path] = true
		_expect(failures, prop_set.empty_weight >= 0.0 and total > 0.0, "%s: empty weight %s, total %s" % [path, prop_set.empty_weight, total])
		var empty_share: float = prop_set.empty_weight / total
		_expect(failures, empty_share >= 0.1 and empty_share <= 0.6, "%s: %.0f percent of the spots stay empty" % [path, empty_share * 100.0])
		# Each room type has its own flavour.
		var typed := names[i]
		if typed == "long":
			var best := 0
			for k in weights.size():
				best = k if weights[k] > weights[best] else best
			_expect(failures, (scenes[best] as PackedScene).resource_path.ends_with("pillar.tscn"), "%s: the long hall does not favour pillars" % path)
		elif typed == "wide":
			_expect(failures, share_of.call(prop_set, ["table", "shelf"] as Array[String]) >= 0.5, "%s: tables and shelves are not most of the wide room" % path)
		elif typed == "vault":
			_expect(failures, share_of.call(prop_set, ["shelf", "crate", "stack"] as Array[String]) == 1.0, "%s: the vault holds more than shelves, crates and stacks" % path)
		elif typed == "straight":
			_expect(failures, scenes.size() == 5, "%s: the straight room does not use all five props" % path)
	return failures

func test_weighted_pick() -> Array[String]:
	var failures: Array[String] = []
	for step in _steps_from("step_02_prop_sets"):
		var chain_script := _chain_script(step)
		var pick := func(weights: Array[float], roll: float) -> int: return chain_script.weighted_pick(weights, roll)
		var two: Array[float] = [1.0, 3.0]
		_expect(failures, pick.call(two, 0.0) == 0 and pick.call(two, 0.2499) == 0 and pick.call(two, 0.25) == 1 and pick.call(two, 0.9999999) == 1, "%s: [1, 3] splits at a quarter" % step)
		var holes: Array[float] = [0.0, 2.0, 0.0, 2.0]
		_expect(failures, pick.call(holes, 0.0) == 1 and pick.call(holes, 0.4999) == 1 and pick.call(holes, 0.5) == 3 and pick.call(holes, 0.9999999) == 3, "%s: a weight of 0 is picked: %s %s %s %s" % [step, pick.call(holes, 0.0), pick.call(holes, 0.4999), pick.call(holes, 0.5), pick.call(holes, 0.9999999)])
		var single: Array[float] = [5.0]
		_expect(failures, pick.call(single, 0.0) == 0 and pick.call(single, 0.99) == 0, "%s: one weight is not picked" % step)
		var shares: Array[float] = [5.0, 2.0, 2.0, 1.0]
		var counts := [0, 0, 0, 0]
		var rng := RandomNumberGenerator.new()
		rng.seed = 7
		for i in 100000:
			counts[pick.call(shares, rng.randf())] += 1
		for k in 4:
			_expect(failures, absf(counts[k] / 100000.0 - shares[k] / 10.0) < 0.01, "%s: weight %s came up %.3f of the time, expected %.3f" % [step, shares[k], counts[k] / 100000.0, shares[k] / 10.0])
	return failures

## The data decides: what a set holds shows in the plans in proportion, and a changed Resource changes the plans.
func test_prop_distribution() -> Array[String]:
	var failures: Array[String] = []
	var counts: Dictionary[int, Dictionary] = {} # room type -> scene path (or "") -> number of spots
	for chain_seed in range(1, PROP_SEEDS + 1):
		if chain_seed % 50 == 0:
			await process_frame
		for plan: Object in _plans_to_goal(Chain, chain_seed, 20).plans:
			for k: int in plan.props.size():
				var per_type: Dictionary = counts.get_or_add(plan.type, {})
				var key := "" if plan.props[k] == Chain.NO_PROP else (Chain.PROP_SETS[plan.type].scenes[plan.props[k]] as PackedScene).resource_path
				per_type[key] = int(per_type.get(key, 0)) + 1
	var summary := ""
	for type: int in counts:
		var prop_set: Resource = Chain.PROP_SETS[type]
		var per_type: Dictionary = counts[type]
		var spots := 0
		for key: String in per_type:
			spots += per_type[key]
		var total: float = prop_set.empty_weight
		for weight: float in prop_set.weights:
			total += weight
		var tolerance := 4.0 * sqrt(0.25 / spots) + 0.005
		var empty_share := float(per_type.get("", 0)) / spots
		_expect(failures, spots >= 200 and absf(empty_share - prop_set.empty_weight / total) < tolerance, "%s: %.3f of %d spots are empty, the set says %.3f" % [_room_name(Chain, type), empty_share, spots, prop_set.empty_weight / total])
		for k: int in prop_set.scenes.size():
			var share := float(per_type.get((prop_set.scenes[k] as PackedScene).resource_path, 0)) / spots
			_expect(failures, absf(share - prop_set.weights[k] / total) < tolerance, "%s: %s is %.3f of the spots, the set says %.3f" % [_room_name(Chain, type), (prop_set.scenes[k] as PackedScene).resource_path.get_file().get_basename(), share, prop_set.weights[k] / total])
		summary += " %s %d spots, %.0f percent empty;" % [_room_name(Chain, type), spots, empty_share * 100.0]
	print("       ", summary)

	# Change the data, change the plans: no code is touched. The straight set with no empty spots left, and the long set empty.
	var straight_set: Resource = Chain.PROP_SETS[Chain.Type.STRAIGHT]
	var long_set: Resource = Chain.PROP_SETS[Chain.Type.LONG]
	var saved_straight: float = straight_set.empty_weight
	var saved_long: float = long_set.empty_weight
	straight_set.empty_weight = 0.0
	long_set.empty_weight = 1.0e9
	var filled := 0
	var straight_spots := 0
	var long_props := 0
	var rooms_equal := true
	var reference: Array = _plans_to_goal(Chain, 42, 20).plans
	for chain_seed in range(1, 101):
		for plan: Object in _plans_to_goal(Chain, chain_seed, 20).plans:
			if plan.type == Chain.Type.STRAIGHT:
				straight_spots += plan.props.size()
				filled += plan.props.filter(func(prop: int) -> bool: return prop != Chain.NO_PROP).size()
			elif plan.type == Chain.Type.LONG:
				long_props += plan.props.filter(func(prop: int) -> bool: return prop != Chain.NO_PROP).size()
	var changed: Array = _plans_to_goal(Chain, 42, 20).plans
	for i in reference.size():
		rooms_equal = rooms_equal and reference[i].type == changed[i].type and reference[i].transform == changed[i].transform and reference[i].locked == changed[i].locked
	straight_set.empty_weight = saved_straight
	long_set.empty_weight = saved_long
	_expect(failures, straight_spots > 0 and filled == straight_spots, "with an empty weight of 0 %d of %d straight-room spots hold a prop" % [filled, straight_spots])
	_expect(failures, long_props == 0, "with a huge empty weight %d props still stand in long halls" % long_props)
	_expect(failures, rooms_equal, "changing a prop set moved a room or a lock")
	return failures

func test_room_weights(step: String) -> Array[String]:
	var failures: Array[String] = []
	var chain_script := _chain_script(step)
	var weights_script := load("res://steps/%s/room_weights.gd" % step) as GDScript
	var weights := load("res://steps/%s/room_weights.tres" % step) as Resource
	_expect(failures, weights != null and weights.get_script() == weights_script and chain_script.ROOM_WEIGHTS == weights, "%s: room_weights.tres is not the chain's ROOM_WEIGHTS" % step)
	var has_vault := STEPS.find(step) >= STEPS.find("step_04_rare_rooms")
	var names: Array[String] = ["straight", "long", "turn_left", "turn_right", "wide"]
	if has_vault:
		names.append("vault")
	var ordinary_minimum := INF
	for i in names.size():
		var weight: float = weights.get(names[i])
		_expect(failures, weight > 0.0 and weight <= 6.0 and weights.weight_of(i) == weight, "%s: weight of %s is %s, weight_of(%d) is %s" % [step, names[i], weight, i, weights.weight_of(i)])
		if names[i] != "vault":
			ordinary_minimum = minf(ordinary_minimum, weight)
	_expect(failures, weights.straight == 2.0 and weights.long == 2.0 and weights.turn_left == 3.0 and weights.turn_right == 3.0 and weights.wide == 1.0, "%s: the tuned weights are 2, 2, 3, 3, 1 (straight, long, turn left, turn right, wide)" % step)
	if has_vault:
		_expect(failures, weights.vault <= ordinary_minimum and weights.min_gap >= 4 and weights.min_gap == 8, "%s: the vault weight %s is not the rarest, or min_gap is %s" % [step, weights.vault, weights.min_gap])
	# The data decides the order: a huge weight for straight makes nearly every room straight, then the weights are put back.
	var saved: float = weights.straight
	weights.straight = 1.0e6
	var straight := 0
	var total := 0
	for plan: Object in _plans(chain_script, 42, 60):
		total += 1
		straight += 1 if plan.type == 0 else 0
	weights.straight = saved
	_expect(failures, straight >= total - 2, "%s: with a straight weight of a million only %d of %d rooms are straight" % [step, straight, total])
	var first := _plans(chain_script, 42, 60)
	var second := _plans(chain_script, 42, 60)
	_expect(failures, _same_plans(first, second), "%s: the weighted order is not the same for the same seed" % step)
	return failures

func test_weighted_rooms() -> Array[String]:
	var failures: Array[String] = []
	var before := _chain_script("step_02_prop_sets")
	var after := _chain_script("step_03_weighted_rooms")
	var differ := 0
	for chain_seed in range(1, CONTENT_SEEDS + 1):
		if chain_seed % 50 == 0:
			await process_frame
		var old_rooms: Array = _plans_to_goal(before, chain_seed, 20).plans
		var new_rooms: Array = _plans_to_goal(after, chain_seed, 20).plans
		var same: bool = old_rooms.size() == new_rooms.size()
		for i in mini(old_rooms.size(), new_rooms.size()):
			same = same and old_rooms[i].type == new_rooms[i].type
		differ += 0 if same else 1
		_expect(failures, new_rooms[0].type == 0 and old_rooms[0].type == 0, "seed %d: room 0 is not the straight room" % chain_seed)
	_expect(failures, differ >= CONTENT_SEEDS * 0.9, "only %d of %d seeds have another room order than before: the new episode needs new weights to show" % [differ, CONTENT_SEEDS])
	print("        weighted rooms: %d of %d seeds (1-%d) have another room order than step 2" % [differ, CONTENT_SEEDS, CONTENT_SEEDS])

	# The mix of the rooms over 1000 seeds: the realised shares, which the heading and overlap rules bend.
	var counts := {}
	var total := 0
	var longest_straight_run := 0
	for chain_seed in range(1, SEED_COUNT + 1):
		if chain_seed % 100 == 0:
			await process_frame
		var run := 0
		for plan: Object in _plans_to_goal(Chain, chain_seed, 20).plans:
			if plan.type == Chain.Type.GOAL:
				break
			counts[plan.type] = int(counts.get(plan.type, 0)) + 1
			total += 1
			run = run + 1 if plan.type == Chain.Type.STRAIGHT else 0
			longest_straight_run = maxi(longest_straight_run, run)
	var shares := {}
	for type: int in counts:
		shares[_room_name(Chain, type)] = snappedf(float(counts[type]) / total, 0.001)
	print("        room mix, seeds 1-%d, rooms before the goal: %s, longest run of straight rooms %d" % [SEED_COUNT, shares, longest_straight_run])
	_expect(failures, counts.size() == 6, "only %d room types in 1000 runs" % counts.size())
	_expect(failures, shares["straight"] > 0.2 and shares["straight"] < 0.34, "straight rooms are %.3f of the mix" % shares["straight"])
	_expect(failures, shares["wide"] < shares["turn_left"] and shares["wide"] < shares["turn_right"] and shares["wide"] < shares["long"], "the wide room (weight 1) is not rarer than the others")
	_expect(failures, longest_straight_run <= 8, "a run of %d straight rooms" % longest_straight_run)

	# The first try of the weighted order follows the weights (nothing to filter yet: the vault is allowed).
	for chain_script: GDScript in [after, Chain]:
		var chain: RefCounted = _new_chain(chain_script, 1, 20)
		var firsts := {}
		var order_problems := 0
		var drawn: float = 20000.0
		for i in 20000:
			var order: Array[int] = chain._weighted_types()
			firsts[order[0]] = int(firsts.get(order[0], 0)) + 1
			var distinct := {}
			for type in order:
				distinct[type] = true
			if distinct.size() != order.size() or order.has(_goal_type(chain_script)):
				order_problems += 1
		_expect(failures, order_problems == 0, "%d weighted orders repeat a type or contain the goal room" % order_problems)
		var weight_sum := 0.0
		var kinds := _goal_type(chain_script)
		for type in kinds:
			weight_sum += chain_script.ROOM_WEIGHTS.weight_of(type)
		for type in kinds:
			var expected: float = chain_script.ROOM_WEIGHTS.weight_of(type) / weight_sum
			_expect(failures, absf(float(firsts.get(type, 0)) / drawn - expected) < 0.015, "type %d is tried first in %.3f of the orders, the weights say %.3f" % [type, float(firsts.get(type, 0)) / drawn, expected])
	return failures

#endregion

#region Tutorial 05: the vault

func test_vault_room() -> Array[String]:
	var failures: Array[String] = []
	for step in _steps_from("step_04_rare_rooms"):
		var room := (load("res://steps/%s/room_vault.tscn" % step) as PackedScene).instantiate() as Node3D
		root.add_child(room)
		(room.get("door") as Node).free() # the room puts a closed door in its exit; this test is about the hall
		await _wait_physics(5)
		var label := "%s room_vault" % step
		var floor_box := room.get_node("Shell/Floor") as CSGBox3D
		_expect(failures, Vector2(floor_box.size.x, floor_box.size.z).is_equal_approx(Vector2(14.0, 14.0)), "%s: the floor is %.1f x %.1f m, expected 14 x 14" % [label, floor_box.size.x, floor_box.size.z])
		var entrance := room.get_node("Entrance") as Marker3D
		var exit_point := room.get_node("Exit") as Marker3D
		_expect(failures, entrance.position.is_equal_approx(Vector3(0.0, 0.0, 7.0)) and exit_point.position.is_equal_approx(Vector3(0.0, 0.0, -7.0)) and exit_point.transform.basis.is_equal_approx(Basis.IDENTITY), "%s: entrance %s and exit %s are not opposite" % [label, entrance.position, exit_point.position])
		var space := room.get_world_3d().direct_space_state

		# Four pillars, 1 m thick, from the floor to the ceiling, solid.
		var pillars := room.get_node("Shell").find_children("Pillar*", "CSGCylinder3D", false, false)
		_expect(failures, pillars.size() == 4, "%s: %d pillars, expected 4" % [label, pillars.size()])
		for pillar: CSGCylinder3D in pillars:
			_expect(failures, is_equal_approx(pillar.radius, 0.5) and is_equal_approx(pillar.height, WALL_HEIGHT) and is_equal_approx(pillar.position.y, WALL_HEIGHT / 2.0), "%s: %s is %.2f m wide and %.2f m high" % [label, pillar.name, pillar.radius * 2.0, pillar.height])
			_expect(failures, absf(absf(pillar.position.x) - 4.5) < 0.001 and absf(absf(pillar.position.z) - 4.5) < 0.001, "%s: %s stands at %s, expected (+-4.5, +-4.5)" % [label, pillar.name, pillar.position])
			_expect(failures, pillar.material != null and pillar.material.resource_path == MATERIAL_DIR + "wall.tres", "%s: %s is not in wall.tres" % [label, pillar.name])
			var side := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(pillar.position.x, 1.5, pillar.position.z - 2.0), Vector3(pillar.position.x, 1.5, pillar.position.z + 2.0)))
			_expect(failures, not side.is_empty() and absf((side["position"] as Vector3).z - (pillar.position.z - 0.5)) < 0.05, "%s: a ray at %s hits the pillar at %s" % [label, pillar.name, side.get("position")])

		# A raised platform in the middle: 6 x 6 m, 0.12 m high (a step the capsule climbs), in the wall material, across the way.
		var platform := room.get_node("Shell/Platform") as CSGBox3D
		_expect(failures, Vector3(platform.size).is_equal_approx(Vector3(6.0, VAULT_PLATFORM_HEIGHT, 6.0)) and is_equal_approx(platform.position.y + platform.size.y / 2.0, VAULT_PLATFORM_HEIGHT) and is_zero_approx(platform.position.x) and is_zero_approx(platform.position.z), "%s: the platform is %s at %s, expected 6 x 0.12 x 6 in the middle on the floor" % [label, platform.size, platform.position])
		_expect(failures, platform.material != null and platform.material.resource_path == MATERIAL_DIR + "wall.tres", "%s: the platform is not in wall.tres: only doors, keys and the goal take an accent colour" % label)
		var middle := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(0.0, 1.0, 0.0), Vector3(0.0, -1.0, 0.0)))
		var aside := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(4.0, 1.0, 0.0), Vector3(4.0, -1.0, 0.0)))
		_expect(failures, not middle.is_empty() and absf((middle["position"] as Vector3).y - VAULT_PLATFORM_HEIGHT) < 0.01 and not aside.is_empty() and absf((aside["position"] as Vector3).y) < 0.01, "%s: the middle is at %.2f m and the side at %.2f m" % [label, (middle["position"] as Vector3).y if not middle.is_empty() else -1.0, (aside["position"] as Vector3).y if not aside.is_empty() else -1.0])
		var edge := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(0.0, 0.06, 5.0), Vector3(0.0, 0.06, 1.0)))
		_expect(failures, not edge.is_empty() and absf((edge["position"] as Vector3).z - 3.0) < 0.01, "%s: the platform's edge across the walking line is not at z = 3" % label)

		var key_spots := room.get_node("KeySpots").get_child_count()
		var prop_spots := room.get_node("PropSpots").get_child_count()
		_expect(failures, key_spots == 3 and prop_spots == 6, "%s: %d key spots and %d prop spots, expected 3 and 6" % [label, key_spots, prop_spots])
		_expect(failures, room.get_node_or_null("Ceiling") != null and room.get_node_or_null("RoomLight") != null and room.get_node_or_null("Fixture") != null, "%s: ceiling, light or fixture missing" % label)
		root.remove_child(room)
		room.free()
	return failures

func test_vault_spacing() -> Array[String]:
	var failures: Array[String] = []
	var weights: Resource = Chain.ROOM_WEIGHTS
	var min_gap: int = weights.min_gap
	_expect(failures, FileAccess.get_file_as_string("res://steps/%s/room_weights.tres" % FINAL_STEP).contains("min_gap = %d" % min_gap), "min_gap %d is not the value in room_weights.tres" % min_gap)
	var vaults_total := 0
	var seeds_with := 0
	var closest := 1000
	for chain_seed in range(1, SEED_COUNT + 1):
		if chain_seed % 50 == 0:
			await process_frame
		var last := -1
		var here := 0
		for plan: Object in _plans_to_goal(Chain, chain_seed, 20).plans:
			if plan.type != Chain.Type.VAULT:
				continue
			here += 1
			_expect(failures, plan.index >= 1 and plan.index < 20, "seed %d: a vault is room %d" % [chain_seed, plan.index])
			if last >= 0:
				closest = mini(closest, plan.index - last)
				_expect(failures, plan.index - last >= min_gap, "seed %d: vaults in rooms %d and %d are %d apart, the gap is %d" % [chain_seed, last, plan.index, plan.index - last, min_gap])
			last = plan.index
		vaults_total += here
		seeds_with += 1 if here > 0 else 0
		if failures.size() > 8:
			return failures
	print("        vaults, seeds 1-%d: %.2f per run, %d seeds have one, the closest two are %d rooms apart (min_gap %d)" % [SEED_COUNT, vaults_total / float(SEED_COUNT), seeds_with, closest, min_gap])
	_expect(failures, closest == min_gap, "the closest vaults are %d apart, but the rule should be met exactly sometimes (min_gap %d)" % [closest, min_gap])
	_expect(failures, seeds_with >= SEED_COUNT * 0.75 and seeds_with <= SEED_COUNT * 0.95, "%d of %d seeds have a vault" % [seeds_with, SEED_COUNT])
	_expect(failures, vaults_total >= SEED_COUNT * 0.9 and vaults_total <= SEED_COUNT * 1.7, "%d vaults in %d runs" % [vaults_total, SEED_COUNT])

	# The boundary of the filter itself: the next room is min_gap after the last vault -> allowed; one room sooner -> never a candidate.
	var chain := Chain.new(5, 100, 0.0)
	for i in 10:
		chain.next_plan()
	chain._last_vault = 10 - min_gap
	var allowed := 0
	for i in 3000:
		allowed += 1 if (chain._weighted_types() as Array[int]).has(Chain.Type.VAULT) else 0
	chain._last_vault = 10 - min_gap + 1
	var too_soon := 0
	for i in 3000:
		too_soon += 1 if (chain._weighted_types() as Array[int]).has(Chain.Type.VAULT) else 0
	_expect(failures, allowed == 3000 and too_soon == 0, "at min_gap %d the vault is a candidate in %d of 3000 orders, one room sooner in %d" % [min_gap, allowed, too_soon])
	return failures

func test_vault_seed_42() -> Array[String]:
	var failures: Array[String] = []
	var chain := _plans_to_goal(Chain, 42, 20)
	var vaults: Array[int] = []
	for plan: Object in chain.plans:
		if plan.type == Chain.Type.VAULT:
			vaults.append(plan.index)
	_expect(failures, vaults == SEED_42_VAULTS, "seed 42 has vaults %s, expected %s" % [vaults, SEED_42_VAULTS])
	_expect(failures, not vaults.is_empty() and vaults[0] < chain.goal_index, "seed 42 shows no vault before the goal room")
	print("        seed 42, goal room 20: vaults in rooms %s, locks in rooms %s, goal room %d" % [vaults, chain.plans.filter(func(plan: Object) -> bool: return plan.locked).map(func(plan: Object) -> int: return plan.index), chain.goal_index])
	# A vault can be locked: its key lies at one of its own key spots.
	var locked_vaults := 0
	for chain_seed in range(1, 301):
		var locked_chain := _plans_to_goal(Chain, chain_seed, 20, 1.0)
		for plan: Object in locked_chain.plans:
			if plan.type == Chain.Type.VAULT:
				if plan.index == locked_chain.goal_index - 1:
					_expect(failures, not plan.locked and plan.key_spot == -1, "seed %d: the vault in room %d, before the goal room, is locked" % [chain_seed, plan.index])
					continue # the room before the goal is never locked, a vault or not
				_expect(failures, plan.locked and plan.key_spot >= 0 and plan.key_spot < chain.key_spot_count(Chain.Type.VAULT) and chain.key_spot_count(Chain.Type.VAULT) == 3, "seed %d: the vault in room %d is not locked at lock chance 1, or its key spot is %d" % [chain_seed, plan.index, plan.key_spot])
				locked_vaults += 1
	_expect(failures, locked_vaults >= 100, "only %d locked vaults in 300 seeds" % locked_vaults)
	return failures

#endregion

#region Tutorial 05: check_contents.gd

func test_contents_check_seeds() -> Array[String]:
	var failures: Array[String] = []
	var layouts := Contents.read_layouts()
	var props := 0
	var vaults := 0
	for chance: float in [LOCK_CHANCE, 1.0]:
		for chain_seed in range(1, SEED_COUNT + 1):
			if chain_seed % 50 == 0:
				await process_frame
			var chain := Solvable.build(chain_seed, 20, chance)
			var problems := Contents.problems_of(chain, Contents.build_without_props(chain_seed, 20, chance), layouts)
			problems.append_array(Solvable.problems_of(chain, Solvable.build(chain_seed, 20, 0.0)))
			for problem in problems:
				failures.append("seed %d, chance %.1f: %s" % [chain_seed, chance, problem])
			for plan in chain.plans:
				vaults += 1 if plan.type == Chain.Type.VAULT else 0
				props += plan.props.filter(func(prop: int) -> bool: return prop != Chain.NO_PROP).size()
			if failures.size() > 8:
				return failures
	print("        seeds 1-%d at lock chance %.1f and 1.0: %d props placed, %d vaults, no rule broken" % [SEED_COUNT, LOCK_CHANCE, props, vaults])
	return failures

## A check that never fails is worth nothing: break the layouts and the plans of a good chain the way a bad level
## designer or a buggy generator could, and see that the check names it.
func test_contents_finds_faults() -> Array[String]:
	var failures: Array[String] = []
	var chain := Solvable.build(42, 20, LOCK_CHANCE)
	var bare := Contents.build_without_props(42, 20, LOCK_CHANCE)
	var clean := Contents.read_layouts()
	_expect(failures, Contents.problems_of(chain, bare, clean).is_empty(), "the check complains about a good chain: %s" % [Contents.problems_of(chain, bare, clean).slice(0, 3)])

	# Broken layouts: a prop spot where it must not be, one prop on every spot of that room type.
	var spot_faults: Array[Dictionary] = [
		{name = "a prop in the walking corridor", type = Chain.Type.STRAIGHT, at = Vector3(0.0, 0.0, 0.0), expect = "walking corridor"},
		{name = "a prop on a key spot", type = Chain.Type.STRAIGHT, at = Vector3(-3.5, 0.0, -0.5), expect = "key spot 0"},
		{name = "a prop in the door's swing", type = Chain.Type.STRAIGHT, at = Vector3(0.0, 0.0, -4.0), expect = "trigger or swing"},
		{name = "a prop in the wall", type = Chain.Type.STRAIGHT, at = Vector3(-4.9, 0.0, -4.9), expect = "sticks into a wall"},
		{name = "a prop on the way to a key", type = Chain.Type.LONG, at = Vector3(-1.9, 0.0, 7.0), expect = "blocks the way"},
		{name = "a prop on a pillar of the vault", type = Chain.Type.VAULT, at = Vector3(-4.5, 0.0, 5.0), expect = "pillar or a platform"},
		{name = "a prop on the platform of the vault", type = Chain.Type.VAULT, at = Vector3(2.0, 0.0, 2.0), expect = "pillar or a platform"},
		{name = "a prop in the swing of the door in the entrance", type = Chain.Type.WIDE, at = Vector3(-0.2, 0.0, 3.5), expect = "trigger or swing"},
	]
	for fault in spot_faults:
		var fault_layouts := Contents.read_layouts()
		fault_layouts[fault.type].prop_spots[0] = Transform3D(Basis.IDENTITY, fault.at)
		Contents._footprints.clear()
		var plan := _plan_with(fault.type, fault_layouts[fault.type].prop_spots.size(), {0: 0})
		var problems := Contents._room_problems(chain, plan, fault_layouts[fault.type])
		var named := false
		for problem in problems:
			named = named or problem.contains(fault.expect)
		_expect(failures, named, "the check does not find %s (expected \"%s\", got %s)" % [fault.name, fault.expect, problems.slice(0, 3)])
	var layouts := Contents.read_layouts()
	layouts[Chain.Type.STRAIGHT].prop_spots[1] = layouts[Chain.Type.STRAIGHT].prop_spots[0]
	Contents._footprints.clear()
	var doubled := Contents._room_problems(chain, _plan_with(Chain.Type.STRAIGHT, 5, {0: 0, 1: 1}), layouts[Chain.Type.STRAIGHT])
	var overlap_named := false
	for problem in doubled:
		overlap_named = overlap_named or problem.contains("overlaps the")
	_expect(failures, overlap_named, "the check does not find two props on one spot (got %s)" % [doubled.slice(0, 3)])
	Contents._footprints.clear()

	# Broken plans.
	var plan_faults: Array[Dictionary] = [
		{kind = "bad_index", name = "a prop the room type does not have", expect = "does not have"},
		{kind = "too_many", name = "more props than prop spots", expect = "props for"},
		{kind = "goal_props", name = "props in the goal room", expect = "props for 0 prop spots"},
		{kind = "close_vaults", name = "two vaults closer than min_gap", expect = "rooms apart"},
		{kind = "moved_room", name = "a prop that moves a room", expect = "not the room it is without props"},
		{kind = "moved_lock", name = "a prop that moves a lock", expect = "not the room it is without props"},
	]
	for fault in plan_faults:
		var broken := Solvable.build(42, 20, LOCK_CHANCE)
		var plain := Contents.build_without_props(42, 20, LOCK_CHANCE)
		_sabotage_contents(broken, fault.kind)
		var problems := Contents.problems_of(broken, plain, clean)
		var named := false
		for problem in problems:
			named = named or problem.contains(fault.expect)
		_expect(failures, named, "the check does not find %s (expected \"%s\", got %s)" % [fault.name, fault.expect, problems.slice(0, 3)])
	return failures

## The public way to the twin the check compares with: no prop spot in any room type, everything else as it was.
func test_clear_prop_spots() -> Array[String]:
	var failures: Array[String] = []
	var props_seen := 0
	for chain_seed in range(1, 41):
		var chain := Solvable.build(chain_seed, 20, LOCK_CHANCE)
		var bare := Contents.build_without_props(chain_seed, 20, LOCK_CHANCE)
		_expect(failures, chain.plans.size() == bare.plans.size(), "seed %d: %d rooms with props, %d without" % [chain_seed, chain.plans.size(), bare.plans.size()])
		for i in mini(chain.plans.size(), bare.plans.size()):
			var plan := chain.plans[i]
			var other := bare.plans[i]
			_expect(failures, plan.type == other.type and plan.transform == other.transform and plan.bounds == other.bounds and plan.locked == other.locked and plan.key_spot == other.key_spot, "seed %d: room %d is not the room it is without props" % [chain_seed, i])
			_expect(failures, other.props.is_empty(), "seed %d: room %d of the twin holds %d prop entries" % [chain_seed, i, other.props.size()])
			props_seen += plan.props.size()
	_expect(failures, props_seen > 0, "the chains of seeds 1-40 hold no props at all: the twin proves nothing")
	var fresh := Chain.new(1, 20, LOCK_CHANCE) # clearing the spots of one chain leaves the next chain alone
	var plan_zero := fresh.next_plan()
	_expect(failures, plan_zero.props.size() == 5, "a new chain lost its prop spots: room 0 has %d entries, expected 5" % plan_zero.props.size())
	return failures

func _sabotage_contents(chain: Chain, kind: String) -> void:
	match kind:
		"bad_index":
			chain.plans[0].props[0] = 99
		"too_many":
			chain.plans[1].props.append(0)
		"goal_props":
			chain.plans[-1].props.append(0)
		"close_vaults":
			var vault_at := -1
			for plan in chain.plans:
				if plan.type == Chain.Type.VAULT:
					vault_at = plan.index
			chain.plans[vault_at + 3].type = Chain.Type.VAULT # no props change: only the spacing is wrong
			chain.plans[vault_at + 3].props.clear()
			for i in 6:
				chain.plans[vault_at + 3].props.append(Chain.NO_PROP)
		"moved_room":
			chain.plans[7].transform = chain.plans[7].transform.translated(Vector3(0.0, 0.0, 1.0))
		"moved_lock":
			chain.plans[3].locked = false

func test_contents_command() -> Array[String]:
	var failures: Array[String] = []
	var executable := OS.get_executable_path()
	if executable.is_empty():
		_skip("check_contents.gd from the command line", "no executable path")
		return failures
	var output: Array = []
	var code := OS.execute(executable, ["--headless", "--path", ProjectSettings.globalize_path("res://"), "-s", "res://steps/%s/check_contents.gd" % FINAL_STEP, "--", "--seeds=40"], output, true)
	var text := ""
	for chunk: String in output:
		text += str(chunk)
	_expect(failures, code == 0 and text.contains("CONTENTS OK") and text.contains("seeds 1-40, lock chance 0.4") and text.contains("seeds 1-40, lock chance 1.0"), "exit code %d, output: %s" % [code, text.substr(0, 300)])
	return failures

#endregion

#region Helpers

func _report(test_name: String, failures: Array[String]) -> void:
	var script_errors := _script_errors.count - _script_errors_reported
	_script_errors_reported = _script_errors.count
	if script_errors > 0: # the test stopped at the failing line and the engine returned an empty array, which would read as a pass
		failures.insert(0, "the test stopped with a script error: see the log")
	if failures.is_empty():
		_passed += 1
		print("PASS  ", test_name)
		return
	_failed += 1
	print("FAIL  ", test_name)
	for message: String in failures.slice(0, 8):
		print("        ", message)
	if failures.size() > 8:
		print("        ... and %d more" % (failures.size() - 8))

func _skip(test_name: String, reason: String) -> void:
	_skipped += 1
	print("SKIP  ", test_name)
	print("        ", reason)

func _expect(failures: Array[String], condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

## Instances a step's main scene. By default it waits until the CSG shapes have built their collision.
## props are set on the Level before it enters the tree (goal_room, chain_seed, save_path ...).
## A level that saves gets a fresh temporary save file unless props bring one.
func _load_step(step: String, settle := true, props := {}) -> Node:
	var scene: PackedScene = load("res://steps/%s/main.tscn" % step)
	var main := scene.instantiate()
	var level := main.get_node_or_null("Level")
	if level != null:
		if level.get("save_path") != null and not props.has("save_path"):
			level.set("save_path", _fresh_save_path())
		for key: String in props:
			level.set(key, props[key])
	root.add_child(main)
	if settle:
		await _wait_physics(10)
	return main

func _unload(main: Node) -> void:
	for action: String in ["move_forward", "move_back", "move_left", "move_right", "look_left", "look_right", "look_up", "look_down", "jump"]:
		Input.action_release(action)
	root.remove_child(main)
	main.free()
	await process_frame

## A path in the temporary test folder that no file exists at.
func _fresh_save_path() -> String:
	_save_counter += 1
	DirAccess.make_dir_recursive_absolute(_save_dir)
	return _save_dir.path_join("best_times_%d.json" % _save_counter)

func _write_file(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()

func _wipe_save_dir() -> void:
	if not DirAccess.dir_exists_absolute(_save_dir):
		return
	for file in DirAccess.get_files_at(_save_dir):
		DirAccess.remove_absolute(_save_dir.path_join(file))
	DirAccess.remove_absolute(_save_dir)

## Runs the simulation faster than real time with the same 1/60 s steps: the engine ticks
## SPEED_UP times as often and hands out SPEED_UP times the delta of each (smaller) tick.
func _fast_forward(on: bool) -> void:
	Engine.physics_ticks_per_second = 60 * (SPEED_UP if on else 1)
	Engine.time_scale = float(SPEED_UP) if on else 1.0

## Sets the size of the game window (headless: the root viewport) and waits for the layout.
## The engine ignores the first size it is given after start-up, so it asks again.
func _set_screen(size: Vector2i) -> void:
	for attempt in 3:
		root.size = size
		for i in 3:
			await process_frame
		if root.size == size:
			return

func _wait_physics(frames: int) -> void:
	for i in frames:
		await physics_frame

func _action(action: StringName) -> void:
	var press := InputEventAction.new()
	press.action = action
	press.pressed = true
	Input.parse_input_event(press)
	Input.flush_buffered_events()
	await process_frame

## Presses an action the way a key does: the event is buffered and handled at the start of the next frame, before that
## frame's physics steps. (_action() hands it over at once, in the middle of a physics frame.)
func _press(action: StringName) -> void:
	var press := InputEventAction.new()
	press.action = action
	press.pressed = true
	Input.parse_input_event(press)
	await physics_frame

#endregion
