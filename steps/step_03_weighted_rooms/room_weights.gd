extends Resource
## How often each room type comes up: the chain tries the types in a weighted order, a bigger weight
## first more often. One data file (room_weights.tres), tuned in the inspector and never in code.

@export var straight := 2.0
@export var long := 2.0
@export var turn_left := 3.0
@export var turn_right := 3.0
@export var wide := 1.0

## The weight of a room type, by its number in the chain's Type enum.
func weight_of(type: int) -> float:
	return [straight, long, turn_left, turn_right, wide][type]
