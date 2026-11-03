# Room Contents in Godot 4

Project files for tutorial 05 of the Godot 4 series by Phaix on YouTube (https://www.youtube.com/@Phaix).

Fill random rooms with furniture and add rare rooms in Godot 4, like Roblox DOORS.
A DOORS-style game with crates, tables, shelves and a rare vault, and paths that never get blocked.

Props on seeded markers with a random stream of their own, balance data in a Resource with a weighted pick, weighted room types, a rare vault with a spacing rule, and a headless check over a thousand seeds that proves every key, door and corridor stays clear. Every step is its own project folder.

![Screenshot](screenshot.png)

## Steps

Every step of the video is its own folder in `steps/`, the exact state at the end of that
part. Open the project in Godot 4.7, then open `steps/<step>/main.tscn` and press F6 to run
that step. The project's main scene is the final step.

| Folder | Part of the video |
|---|---|
| `steps/step_00_start` | Starting point (the final state of tutorial 04) |
| `steps/step_01_prop_spots` | Step 1 - Props on markers |
| `steps/step_02_prop_sets` | Step 2 - Prop sets |
| `steps/step_03_weighted_rooms` | Step 3 - Weighted rooms |
| `steps/step_04_rare_rooms` | Step 4 - A rare room |
| `steps/step_05_clear_paths` | Step 5 - Clear paths |

## Controls

WASD or arrow keys or the left stick to walk, mouse or right stick to look, Space to jump,
Esc gives the mouse back, a click captures it again. Further keys per tutorial are shown
in the video and in the HUD.

## Tests

```sh
godot --headless --path . -s res://tests/run_tests.gd
```

## Changed since the video

- One fix went into every step folder after the video: the old rooms are now freed when the door behind the player has shut, not when the player enters the next room. Before, you could look back through that door while it was still closing and see a hole where the oldest room had been.
- `door.gd` has a new signal, `closed`, emitted when the door has finished swinging shut (never when it is opened again on the way).
- `level.gd` has a new function, `_on_door_closed(index)`, which frees the rooms behind that door and puts a wall where the doorway of the room just left was. `_spawn_room` connects the signal, and `_on_room_entered` only closes the door behind the player now.
- `tests/run_tests.gd` has a new test, `test_rooms_wait_for_the_door`, and the streaming test expects the rooms to go when the door has shut.
- The rest is as in the video.

## Support

Support the channel: https://ko-fi.com/phaix or https://github.com/sponsors/schemann

## License

Code and scenes: MIT (see LICENSE).
