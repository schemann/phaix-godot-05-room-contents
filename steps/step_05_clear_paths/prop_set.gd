extends Resource
## What a room type may hold and how often: one data file per room type (props/*_set.tres), tuned in the
## inspector and never in code. A bigger weight comes up more often; the weight of nothing is the weight
## of an empty spot.

@export var scenes: Array[PackedScene] = [] ## The props this room type may hold.
@export var weights: Array[float] = [] ## One weight per scene, in the same order.
@export var empty_weight := 1.0 ## The weight of "no prop here": a spot stays empty.
