extends SceneTree
## Checks that every run can be finished, for seeds 1 to 1000. Data only: no level is started and no
## player walks, the chain is asked for its plans and the plans are read. A generator needs a check,
## not hope: one lucky seed proves nothing, a thousand seeds with a rule list prove a lot.
##
##   godot --headless --path godot/05-room-contents -s res://steps/step_01_prop_spots/check_solvable.gd
##
## Option: `-- --seeds=200` checks seeds 1 to 200 only. The exit code is 0 if every seed passes and
## 1 if any fails, so a build server can run it.

const Chain := preload("room_chain.gd")

const DEFAULT_SEEDS := 1000
const GOAL_ROOM := 20
const LOCK_CHANCES: Array[float] = [0.4, 1.0] ## The level's default, and the worst case: every room that may be locked is.
const MAX_PLANS := 100 ## A chain that has not reached its goal room by now is broken.

func _initialize() -> void:
	var seed_count := DEFAULT_SEEDS
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--seeds="):
			seed_count = int(argument.trim_prefix("--seeds="))

	var failed := 0
	for chance in LOCK_CHANCES:
		var locked_rooms := 0
		var seeds_with_problems := 0
		for chain_seed in range(1, seed_count + 1):
			if chain_seed % 100 == 0:
				await process_frame # every chain reads six room scenes: let the engine empty its queue now and then
			var chain := build(chain_seed, GOAL_ROOM, chance)
			var problems := problems_of(chain, build(chain_seed, GOAL_ROOM, 0.0))
			for plan in chain.plans:
				locked_rooms += 1 if plan.locked else 0
			if not problems.is_empty():
				seeds_with_problems += 1
				if seeds_with_problems <= 5: # the first few are enough to find the cause
					for problem in problems:
						printerr("seed %d, lock chance %.1f: %s" % [chain_seed, chance, problem])
		print("seeds 1-%d, lock chance %.1f: %d locked rooms, %d seeds with problems" % [seed_count, chance, locked_rooms, seeds_with_problems])
		failed += seeds_with_problems
	print("SOLVABLE " + ("OK" if failed == 0 else "FAILED: %d seeds" % failed))
	quit(1 if failed > 0 else 0)

## The chain of a seed as data: plans until the goal room is made.
static func build(chain_seed: int, goal_room: int, chance: float) -> Chain:
	var chain := Chain.new(chain_seed, goal_room, chance)
	while chain.plans.size() < MAX_PLANS:
		if chain.next_plan().type == Chain.Type.GOAL:
			break
	return chain

## Every way a run could get stuck or a lock could change the rooms, as sentences. Empty: fine.
## plain is the same seed and goal without any lock.
static func problems_of(chain: Chain, plain: Chain) -> Array[String]:
	var problems: Array[String] = []

	# The run ends in exactly one goal room, the last plan.
	var goal_rooms := 0
	for plan in chain.plans:
		goal_rooms += 1 if plan.type == Chain.Type.GOAL else 0
	if goal_rooms != 1 or chain.plans[-1].type != Chain.Type.GOAL:
		problems.append("%d goal rooms, the last plan is type %d" % [goal_rooms, chain.plans[-1].type])

	# Locks never change the rooms: the same order, the same places, as without locks.
	if chain.plans.size() != plain.plans.size():
		problems.append("%d rooms with locks, %d without" % [chain.plans.size(), plain.plans.size()])
	for i in mini(chain.plans.size(), plain.plans.size()):
		var plan := chain.plans[i]
		var bare := plain.plans[i]
		if plan.type != bare.type or plan.transform != bare.transform or plan.bounds != bare.bounds:
			problems.append("room %d is not the room it is without locks" % i)
			break

	# Room by room: what is locked, where its key is.
	var before_goal := chain.goal_index - 1
	for plan in chain.plans:
		var where := "room %d" % plan.index
		if plan.locked and plan.key_spot < 0:
			problems.append("%s is locked and has no key" % where)
		if not plan.locked and plan.key_spot >= 0:
			problems.append("%s is not locked but holds a key" % where)
		if plan.key_spot >= chain.key_spot_count(plan.type):
			problems.append("%s: key spot %d does not exist (the room type has %d)" % [where, plan.key_spot, chain.key_spot_count(plan.type)])
		if plan.locked and (plan.index == 0 or plan.index == before_goal or plan.type == Chain.Type.GOAL):
			problems.append("%s is locked, but room 0, the room before the goal and the goal room never are" % where)

	# Play it as data: the player walks the rooms in order, picks up the key of a room before its
	# door (the key lies in the same room) and uses one key per locked door.
	var held := 0
	for plan in chain.plans:
		if plan.key_spot >= 0:
			held += 1
		if plan.locked:
			if held == 0:
				problems.append("stuck: room %d is locked and the player holds no key" % plan.index)
				break
			held -= 1
	return problems
