extends Resource
class_name FootballPlayer

var id: int
var player_name: String
var number: int
var role: String
var natural_role: String
var tactical_role: String
var attributes: Dictionary = {}
var form: float = 0.0
var fatigue: float = 0.0
var stamina: float = 100.0
var tackle_cooldown: float = 0.0
var carry_distance: float = 0.0
var position: Vector2 = Vector2.ZERO
var tactical_position: Vector2 = Vector2.ZERO
var team_index: int = 0
var on_pitch := true

func get_attribute(attribute_name: String) -> float:
	return float(attributes.get(attribute_name, 50.0))

func apply_condition(seconds: float, fatigue_per_second: float) -> void:
	fatigue = clampf(fatigue + fatigue_per_second * seconds, 0.0, 1.0)
	stamina = get_attribute("stamina") * (1.0 - fatigue)

func record_action(success: bool, form_change: float) -> void:
	form = clampf(form + (form_change if success else -form_change * 0.5), -1.0, 1.0)

func restore_fitness(fatigue_reduction: float) -> void:
	fatigue = clampf(fatigue - fatigue_reduction, 0.0, 1.0)
	stamina = get_attribute("stamina") * (1.0 - fatigue)
