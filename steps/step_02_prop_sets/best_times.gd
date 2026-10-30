extends RefCounted
## The best time per seed, saved as JSON:
##   {"formatVersion": 1, "bestTimes": {"42": 39.817}}
## The seed is a string, because a JSON key is always a string.
## Loading never fails: no file is an empty list, and a file that cannot be read is kept as
## <name>.bad while the list starts empty. A save writes back everything that was in the file.

const FORMAT_VERSION := 1
const NO_TIME := -1.0 ## What best() says for a seed without a time.

var _path: String
var _data := {} ## The whole file as loaded, so keys this version does not know survive a save.

func _init(path: String) -> void:
	_path = path
	_load()

## The best time of a seed in seconds, or NO_TIME.
func best(chain_seed: int) -> float:
	var times: Dictionary = _data.get("bestTimes", {})
	var time: Variant = times.get(str(chain_seed), NO_TIME)
	return float(time) if time is float or time is int else NO_TIME

## Keeps the time if the seed has none yet or this one is faster. Returns true if it did.
func submit(chain_seed: int, time: float) -> bool:
	var rounded := snappedf(time, 0.001) # milliseconds are enough
	var old := best(chain_seed)
	if old != NO_TIME and rounded >= old:
		return false
	var times: Dictionary = _data.get_or_add("bestTimes", {})
	times[str(chain_seed)] = rounded
	_data["formatVersion"] = maxi(FORMAT_VERSION, int(_data.get("formatVersion", 0))) # never lower it
	_save()
	return true

func _load() -> void:
	if not FileAccess.file_exists(_path):
		return
	var json := JSON.new()
	var readable := json.parse(FileAccess.get_file_as_string(_path)) == OK
	if readable and json.data is Dictionary and (json.data as Dictionary).get("bestTimes", {}) is Dictionary:
		_data = json.data
		return
	# Never delete what cannot be read: keep it to look at later, start with an empty list.
	push_warning("best times: %s cannot be read, kept as %s.bad" % [_path, _path])
	DirAccess.rename_absolute(_path, _path + ".bad")

## Writes next to the file first, then renames: a crash in between leaves the old file whole.
func _save() -> void:
	var temp_path := _path + ".tmp"
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		push_warning("best times: cannot write %s (error %d)" % [temp_path, FileAccess.get_open_error()])
		return
	file.store_string(JSON.stringify(_data, "\t"))
	file.flush()
	file.close()
	if DirAccess.rename_absolute(temp_path, _path) != OK:
		push_warning("best times: cannot replace %s" % _path)
