// The clouds' layer and their density, shared by the sky shader and the
// compute shader of SkyAtmosphere's cloud shadows (where the C++ side pastes
// it in), so it keeps to what the Godot shading language and GLSL have in
// common, as atmosphere_common.gdshaderinc does. Whoever includes it declares
// first, under these names: atm_bottom_radius (kilometers), clouds_storm,
// clouds_bottom_altitude, clouds_thickness, clouds_coverage, clouds_density,
// clouds_coverage_scale, clouds_shape_scale, clouds_detail_scale,
// clouds_detail_strength, clouds_wind_offset, and the samplers
// clouds_shape_texture and clouds_detail_texture.

// The layer, as the storm changes it: bottom and thickness in meters,
// coverage, density.
struct CloudsLayer {
	float bottom;
	float thickness;
	float coverage;
	float density;
	float storm;
};

CloudsLayer clouds_layer() {
	CloudsLayer layer;
	layer.storm = clamp(clouds_storm, 0.0, 1.0);
	// Storm clouds hang lower, tower higher, cover the whole sky, and are
	// much denser, so little light makes it through them.
	layer.bottom = clouds_bottom_altitude * mix(1.0, 0.6, layer.storm);
	layer.thickness = max(clouds_thickness * mix(1.0, 2.5, layer.storm), 1.0);
	layer.coverage = mix(clouds_coverage, max(clouds_coverage, 0.95), layer.storm);
	layer.density = clouds_density * mix(1.0, 3.0, layer.storm);
	return layer;
}

float clouds_planet_radius() {
	return atm_bottom_radius * 1000.0;
}

// Altitude above the curved ground of a point given relative to the ground
// right below the camera.
float clouds_altitude(vec3 p) {
	float R = clouds_planet_radius();
	return length(p + vec3(0.0, R, 0.0)) - R;
}

// Where a ray from p_origin (at p_altitude, right above the planet's center)
// meets the sphere at p_sphere_altitude: both distances, or a negative far
// one if it misses. The radii are subtracted before squaring them, which keeps
// the precision of a planet this size.
vec2 clouds_sphere(float altitude, vec3 dir, float sphere_altitude) {
	float R = clouds_planet_radius();
	float b = (altitude + R) * dir.y;
	float c = (altitude - sphere_altitude) * (2.0 * R + altitude + sphere_altitude);
	float d = b * b - c;
	if (d < 0.0) {
		return vec2(-1.0);
	}
	d = sqrt(d);
	return vec2(-b - d, -b + d);
}

float clouds_remap(float value, float low, float high, float new_low, float new_high) {
	return new_low + (value - low) / max(high - low, 1e-5) * (new_high - new_low);
}

// The density of the clouds at the world position p (meters), h being how far
// up into the layer it is.
float clouds_density_at(vec3 p, float h, CloudsLayer layer, bool detail) {
	if (h <= 0.0 || h >= 1.0) {
		return 0.0;
	}
	vec3 q = p - clouds_wind_offset;

	// Where the sky is cloudy at all: the shape noise, stretched out much
	// wider. The storm evens it out.
	float weather = textureLod(clouds_shape_texture, vec3(q.x, 0.37 * clouds_coverage_scale, q.z) / clouds_coverage_scale, 0.0).r;
	float coverage = clamp(layer.coverage + (weather - 0.5) * 0.6 * (1.0 - layer.storm), 0.0, 1.0);

	// Rounded bottoms, and tops that reach higher where it is cloudier.
	float top = mix(0.35, 1.0, coverage);
	float profile = smoothstep(0.0, 0.08, h) * (1.0 - smoothstep(top * 0.45, top, h));

	float shape = textureLod(clouds_shape_texture, q / clouds_shape_scale, 0.0).r;
	float cloud = clamp(clouds_remap(shape * profile, 1.0 - coverage, 1.0, 0.0, 1.0), 0.0, 1.0) * coverage;
	if (cloud <= 0.0) {
		return 0.0;
	}

	if (detail) {
		// Wisps at the bottom, billows higher up.
		float fine = textureLod(clouds_detail_texture, (q - clouds_wind_offset * 0.2) / clouds_detail_scale, 0.0).r;
		float erosion = mix(1.0 - fine, fine, clamp(h * 4.0, 0.0, 1.0)) * clouds_detail_strength * (1.0 - 0.5 * layer.storm);
		cloud = clamp(clouds_remap(cloud, erosion, 1.0, 0.0, 1.0), 0.0, 1.0);
	}
	return cloud * layer.density;
}
