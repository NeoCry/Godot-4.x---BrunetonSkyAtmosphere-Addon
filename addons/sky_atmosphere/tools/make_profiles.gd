extends SceneTree
## Writes the addon's example SkyCycleProfiles into profiles/:
##   godot --headless --path <project> --script res://addons/sky_atmosphere/tools/make_profiles.gd

const DIR := "res://addons/sky_atmosphere/profiles"


## A curve over the day from [hour, value] pairs, its range set to p_max.
func _curve(p_points: Array, p_max := 1.0) -> Curve:
	var curve := Curve.new()
	curve.max_value = p_max
	for point in p_points:
		curve.add_point(Vector2(point[0] / 24.0, point[1]))
	# Smooth, but without overshooting between the points.
	for i in curve.point_count:
		curve.set_point_left_mode(i, Curve.TANGENT_LINEAR if i == 0 else Curve.TANGENT_FREE)
	curve.bake()
	return curve


## A gradient over the day from [hour, color] pairs.
func _gradient(p_points: Array) -> Gradient:
	var gradient := Gradient.new()
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for point in p_points:
		offsets.push_back(point[0] / 24.0)
		colors.push_back(point[1])
	gradient.offsets = offsets
	gradient.colors = colors
	return gradient


func _save(p_profile: SkyCycleProfile, p_name: String) -> void:
	var path := DIR.path_join(p_name + ".tres")
	var error := ResourceSaver.save(p_profile, path)
	print("%s: %s" % [path, error_string(error)])


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)

	# A fair day: clouds building up in the afternoon, a haze at dawn.
	var day := SkyCycleProfile.new()
	day.clouds_coverage = _curve([[0, 0.35], [6, 0.3], [14, 0.55], [19, 0.45], [24, 0.35]])
	day.fog_density = _curve([[0, 0.0003], [6, 0.0007], [9, 0.0002], [15, 0.0001], [21, 0.00025], [24, 0.0003]], 0.002)
	day.fog_color = _gradient([
		[0, Color(0.05, 0.06, 0.09)],
		[5.5, Color(0.35, 0.3, 0.32)],
		[7, Color(0.75, 0.6, 0.5)],
		[10, Color(0.62, 0.68, 0.75)],
		[17, Color(0.62, 0.68, 0.75)],
		[19, Color(0.7, 0.5, 0.42)],
		[20.5, Color(0.2, 0.18, 0.22)],
		[24, Color(0.05, 0.06, 0.09)],
	])
	_save(day, "day")

	# Weather, over it.
	var clear := SkyCycleProfile.new()
	clear.clouds_coverage = _curve([[0, 0.12], [24, 0.12]])
	clear.fog_density = _curve([[0, 0.00005], [24, 0.00005]], 0.002)
	_save(clear, "weather_clear")

	var overcast := SkyCycleProfile.new()
	overcast.clouds_coverage = _curve([[0, 0.85], [24, 0.85]])
	overcast.clouds_density = _curve([[0, 1.5], [24, 1.5]], 4.0)
	overcast.storm = _curve([[0, 0.35], [24, 0.35]])
	overcast.fog_density = _curve([[0, 0.0006], [24, 0.0006]], 0.002)
	_save(overcast, "weather_overcast")

	var storm := SkyCycleProfile.new()
	storm.storm = _curve([[0, 1.0], [24, 1.0]])
	storm.clouds_coverage = _curve([[0, 0.95], [24, 0.95]])
	storm.clouds_wind_speed = _curve([[0, 25.0], [24, 25.0]], 50.0)
	storm.fog_density = _curve([[0, 0.0015], [24, 0.0015]], 0.002)
	storm.fog_color = _gradient([[0, Color(0.3, 0.33, 0.37)], [24, Color(0.3, 0.33, 0.37)]])
	_save(storm, "weather_storm")

	quit()
