// The sky of a SkyAtmosphere node: Bruneton's precomputed atmosphere, the
// sun's and the moon's disks seen through it, the stars behind them, the
// ground below the horizon, and a layer of volumetric clouds lit through the
// same air, which a storm thickens and lightning lights up from inside.
//
// SkyAtmosphere sets every uniform here, and the tables in particular, which
// it computes. Edit the node, not the material.
shader_type sky;
render_mode use_half_res_pass;

group_uniforms atmosphere;
// Kilometers, per kilometer. See atmosphere_common.gdshaderinc.
uniform vec3 atm_rayleigh_scattering = vec3(0.005802, 0.013558, 0.0331);
uniform float atm_bottom_radius = 6360.0;
uniform vec3 atm_mie_scattering = vec3(0.003996);
uniform float atm_top_radius = 6460.0;
uniform vec3 atm_mie_extinction = vec3(0.00444);
uniform float atm_mie_g = 0.8;
uniform vec3 atm_absorption_extinction = vec3(0.00065, 0.001881, 0.000085);
uniform float atm_rayleigh_scale_height = 8.0;
uniform vec3 atm_ground_albedo = vec3(0.1);
uniform float atm_mie_scale_height = 1.2;
uniform float atm_ozone_tip = 25.0;
uniform float atm_ozone_width = 30.0;
uniform float atm_sun_angular_radius = 0.004675;
uniform float atm_mu_s_min = -0.2;
uniform sampler2D atm_transmittance_texture : filter_linear, repeat_disable;
uniform sampler3D atm_scattering_texture : filter_linear, repeat_disable;
uniform sampler3D atm_single_mie_texture : filter_linear, repeat_disable;
uniform sampler2D atm_irradiance_texture : filter_linear, repeat_disable;
// Meters per world unit.
uniform float world_scale = 1.0;

group_uniforms lights;
// Towards the lights, and their illuminance: linear color times energy, in
// the scene's units, before the air reddens it.
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform vec3 sun_illuminance = vec3(0.0);
uniform float sun_angular_radius = 0.004651;
uniform vec3 moon_direction = vec3(0.0, -1.0, 0.0);
uniform vec3 moon_illuminance = vec3(0.0);
uniform float moon_angular_radius = 0.0045;

group_uniforms sky;
uniform float sky_energy = 1.0;
uniform float sun_disk_scale = 2.0;
uniform float sun_disk_intensity = 1.0;
uniform float moon_disk_intensity = 1.0;
uniform sampler2D night_sky : filter_linear, source_color, hint_default_black;
uniform float night_sky_energy = 1.0;
uniform bool ground_enabled = true;

group_uniforms clouds;
uniform bool clouds_enabled = true;
uniform float clouds_coverage = 0.45;
uniform float clouds_density = 1.0;
uniform float clouds_bottom_altitude = 1500.0;
uniform float clouds_thickness = 2500.0;
uniform float clouds_extinction = 0.04;
uniform float clouds_anisotropy = 0.6;
uniform float clouds_ambient_strength = 1.0;
uniform sampler3D clouds_shape_texture : filter_linear, repeat_enable, hint_default_black;
uniform float clouds_shape_scale = 12000.0;
uniform float clouds_coverage_scale = 60000.0;
uniform sampler3D clouds_detail_texture : filter_linear, repeat_enable, hint_default_black;
uniform float clouds_detail_scale = 1800.0;
uniform float clouds_detail_strength = 0.35;
// How far the wind has blown the clouds, in meters.
uniform vec3 clouds_wind_offset = vec3(0.0);
uniform float clouds_fade_distance = 40000.0;
uniform int clouds_samples = 48;
uniform int clouds_light_samples = 6;
uniform float clouds_storm = 0.0;
// xyz: where the flash is, in meters; w: how bright it is right now.
uniform vec4 clouds_lightning = vec4(0.0);
uniform vec3 clouds_lightning_color : source_color = vec3(0.75, 0.8, 1.0);

#include "atmosphere_common.gdshaderinc"

// The camera in the atmosphere's frame: the planet's center is right below
// it, so the sky is the same wherever it goes, only not how high.
vec3 atmosphere_camera(vec3 position) {
	return vec3(0.0, atm_bottom_radius + max(position.y * world_scale * 0.001, 0.0005), 0.0);
}

// The sky along dir from camera, lit by both lights, and what of what is
// behind it gets through (nothing, when the ground is in the way).
vec3 sky_radiance(vec3 camera, vec3 dir, out vec3 transmittance) {
	vec3 radiance = atm_sky_radiance(camera, dir, sun_direction, transmittance) * sun_illuminance;
	if (dot(moon_illuminance, moon_illuminance) > 0.0) {
		vec3 unused;
		radiance += atm_sky_radiance(camera, dir, moon_direction, unused) * moon_illuminance;
	}
	return radiance;
}

// Where the ground is in the way: the lit ground, and the air in front of it.
// The ray ends on the ground, which is just what the tables' ground half holds
// the light of.
vec3 ground_radiance(vec3 camera, vec3 dir) {
	float r = length(camera);
	float mu = dot(camera, dir) / r;
	float d = atm_distance_to_bottom(r, mu);
	vec3 point = camera + dir * d;
	vec3 normal = normalize(point);

	vec3 sky_irradiance;
	vec3 irradiance = (atm_sun_and_sky_irradiance(point, normal, sun_direction, sky_irradiance) + sky_irradiance) * sun_illuminance;
	if (dot(moon_illuminance, moon_illuminance) > 0.0) {
		vec3 moon_sky_irradiance;
		irradiance += (atm_sun_and_sky_irradiance(point, normal, moon_direction, moon_sky_irradiance) + moon_sky_irradiance) * moon_illuminance;
	}
	vec3 unused;
	vec3 air = sky_radiance(camera, dir, unused);
	return air + atm_ground_albedo / PI * irradiance * atm_transmittance(r, mu, d, true);
}

// A light's disk: its illuminance spread over the solid angle it covers, so
// that it is as bright as the light it casts, darkening towards its limb.
vec3 light_disk(vec3 eyedir, vec3 direction, vec3 illuminance, float angular_radius, float intensity) {
	float radius = angular_radius * sun_disk_scale;
	float cos_angle = dot(eyedir, direction);
	float cos_radius = cos(radius);
	if (radius <= 0.0 || cos_angle < cos_radius) {
		return vec3(0.0);
	}
	float r = clamp(acos(clamp(cos_angle, -1.0, 1.0)) / radius, 0.0, 1.0);
	float limb = 1.0 - 0.6 * (1.0 - sqrt(max(0.0, 1.0 - r * r)));
	float solid_angle = 2.0 * PI * (1.0 - cos_radius);
	return illuminance / max(solid_angle, 1e-7) * limb * intensity;
}

// Clouds.

// The farthest a ray is marched through the layer, past where it enters it.
const float CLOUDS_MAX_MARCH = 30000.0;

#include "clouds_common.gdshaderinc"


float clouds_henyey_greenstein(float cos_theta, float g) {
	float g2 = g * g;
	return (1.0 - g2) / (4.0 * PI * pow(max(1.0 + g2 - 2.0 * g * cos_theta, 1e-4), 1.5));
}

// Mostly forward, with a little back scattering, for the silver lining and
// the bright side alike.
float clouds_phase(float cos_theta, float g) {
	return mix(clouds_henyey_greenstein(cos_theta, g), clouds_henyey_greenstein(cos_theta, -0.3 * g), 0.25);
}

// The optical depth towards a light from p, through the layer. p_world is the
// same point in the world, where the noise is.
float clouds_light_depth(vec3 p, vec3 p_world, vec3 light_dir, CloudsLayer layer, int samples) {
	if (samples <= 0) {
		return 0.0;
	}
	float depth = 0.0;
	float span = layer.thickness * 0.6;
	float t = 0.0;
	for (int i = 0; i < samples; i++) {
		// Steps grow away from p, where the detail matters most.
		float next = span * pow(float(i + 1) / float(samples), 1.6);
		float mid = 0.5 * (t + next);
		float h = (clouds_altitude(p + light_dir * mid) - layer.bottom) / layer.thickness;
		depth += clouds_density_at(p_world + light_dir * mid, h, layer, false) * (next - t);
		t = next;
	}
	return depth * clouds_extinction;
}

// Light scattered towards the eye by a unit of cloud, from one light, several
// orders of it (Wrenninge's octaves): each order is dimmer, less forward, and
// gets through more cloud than the last. Clouds scatter nearly all the light
// they take in, many times over, so the higher orders carry a lot of it.
vec3 clouds_light_scattering(vec3 light, float depth, float cos_theta) {
	vec3 result = vec3(0.0);
	float a = 1.0;
	float b = 1.0;
	float c = 1.0;
	for (int i = 0; i < 4; i++) {
		result += light * a * clouds_phase(cos_theta, clouds_anisotropy * c) * exp(-depth * b);
		a *= 0.7;
		b *= 0.35;
		c *= 0.4;
	}
	return result;
}

// Marches the clouds along a ray from the camera at position (world units):
// their light, and how much of what is behind them still shows through them.
vec4 clouds_march(vec3 position, vec3 dir, int samples, int light_samples, float jitter) {
	CloudsLayer layer = clouds_layer();
	vec3 world_origin = position * world_scale;
	// Under the ground, the clouds are seen as from the ground: below it the
	// camera would be inside the planet, where no ray stops at the ground and
	// the downward ones find the layer on the planet's far side.
	world_origin.y = max(world_origin.y, 1.0);
	float altitude = world_origin.y;
	// The march happens relative to the ground right below the camera.
	vec3 origin = vec3(0.0, altitude, 0.0);
	float top = layer.bottom + layer.thickness;

	float t_start;
	float t_end;
	vec2 bottom_hit = clouds_sphere(altitude, dir, layer.bottom);
	vec2 top_hit = clouds_sphere(altitude, dir, top);
	if (altitude < layer.bottom) {
		// From below, unless the ground is in the way.
		vec2 ground_hit = clouds_sphere(altitude, dir, 0.0);
		if (altitude >= 0.0 && ground_hit.x > 0.0) {
			return vec4(0.0, 0.0, 0.0, 1.0);
		}
		t_start = bottom_hit.y;
		t_end = top_hit.y;
	} else if (altitude < top) {
		// From inside.
		t_start = 0.0;
		t_end = bottom_hit.x > 0.0 ? bottom_hit.x : top_hit.y;
	} else {
		// From above.
		if (top_hit.y < 0.0) {
			return vec4(0.0, 0.0, 0.0, 1.0);
		}
		t_start = max(top_hit.x, 0.0);
		t_end = bottom_hit.x > 0.0 ? bottom_hit.x : top_hit.y;
	}
	t_end = min(t_end, t_start + CLOUDS_MAX_MARCH);
	if (t_end <= t_start) {
		return vec4(0.0, 0.0, 0.0, 1.0);
	}

	// Both lights as they reach the layer, through the air below it.
	vec3 camera = atmosphere_camera(position);
	vec3 entry = camera + dir * (t_start * 0.001);
	float r_entry = atm_clamp_radius(length(entry));
	vec3 up_entry = normalize(entry);
	vec3 light_dirs[2] = vec3[2](sun_direction, moon_direction);
	vec3 illuminances[2] = vec3[2](sun_illuminance, moon_illuminance);
	vec3 lights[2];
	// Light from everywhere else: the sky above, and the lit ground below.
	vec3 sky_light = vec3(0.0);
	vec3 ground_light = vec3(0.0);
	vec3 ground = vec3(0.0, atm_bottom_radius, 0.0);
	for (int i = 0; i < 2; i++) {
		float mu_s = dot(up_entry, light_dirs[i]);
		lights[i] = illuminances[i] * atm_transmittance_to_sun(r_entry, mu_s);
		sky_light += illuminances[i] * atm_irradiance(r_entry, mu_s) / PI;
		vec3 ground_sky;
		vec3 ground_sun = atm_sun_and_sky_irradiance(ground, vec3(0.0, 1.0, 0.0), light_dirs[i], ground_sky);
		ground_light += illuminances[i] * (ground_sun + ground_sky) * atm_ground_albedo / PI;
	}
	sky_light *= clouds_ambient_strength;
	ground_light *= clouds_ambient_strength;

	// A storm's clouds keep less of the light they scatter.
	float albedo = mix(0.99, 0.8, layer.storm);

	// The steps follow the layer's thickness rather than the length of the ray
	// through it: towards the horizon, where that is tens of kilometers, steps
	// spread over all of it would be longer than the clouds are wide, and each
	// would show as a slice. They are only allowed to grow a few times longer
	// there, which their number makes up for.
	float dt = max(layer.thickness / float(samples), (t_end - t_start) / float(samples * 4));
	int steps = min(int(ceil((t_end - t_start) / dt)), samples * 4);
	float transmittance = 1.0;
	vec3 luminance = vec3(0.0);
	float depth_sum = 0.0;
	float weight_sum = 0.0;
	for (int i = 0; i < steps; i++) {
		float t = t_start + (float(i) + jitter) * dt;
		vec3 p = origin + dir * t;
		vec3 p_world = world_origin + dir * t;
		float h = (clouds_altitude(p) - layer.bottom) / layer.thickness;
		float density = clouds_density_at(p_world, h, layer, true);
		if (density <= 0.0) {
			continue;
		}
		float extinction = density * clouds_extinction;
		// Clouds that take no light out (clouds_extinction at 0) give none either.
		if (extinction <= 0.0) {
			continue;
		}

		vec3 scattering = mix(ground_light, sky_light, clamp(h, 0.0, 1.0)) * mix(0.5, 1.0, h);
		for (int j = 0; j < 2; j++) {
			if (dot(lights[j], lights[j]) > 0.0) {
				float depth = clouds_light_depth(p, p_world, light_dirs[j], layer, light_samples);
				scattering += clouds_light_scattering(lights[j], depth, dot(dir, light_dirs[j]));
			}
		}
		if (clouds_lightning.w > 0.0) {
			vec3 to_flash = (p_world - clouds_lightning.xyz * world_scale) / 2500.0;
			scattering += clouds_lightning_color * clouds_lightning.w * 6.0 * exp(-dot(to_flash, to_flash));
		}
		scattering *= extinction * albedo;

		// Integrated over the step, as in Hillaire's "Physically Based Sky,
		// Atmosphere and Cloud Rendering in Frostbite".
		float step_transmittance = exp(-extinction * dt);
		luminance += transmittance * (scattering - scattering * step_transmittance) / extinction;
		float weight = transmittance * (1.0 - step_transmittance);
		depth_sum += t * weight;
		weight_sum += weight;
		transmittance *= step_transmittance;
		if (transmittance < 0.01) {
			transmittance = 0.0;
			break;
		}
	}

	if (weight_sum > 0.0) {
		// The air between the camera and the clouds, at their average depth.
		float depth = depth_sum / weight_sum;
		vec3 point = camera + dir * (depth * 0.001);
		vec3 air_transmittance;
		vec3 inscatter = atm_aerial_perspective(camera, point, sun_direction, sun_illuminance, moon_direction, moon_illuminance, 8, air_transmittance);
		luminance = luminance * air_transmittance + inscatter * (1.0 - transmittance);

		// And far clouds, whose tiling would show, fade into the sky behind them.
		float fade = exp(-depth / max(clouds_fade_distance, 1.0));
		vec3 unused;
		luminance = luminance * fade + sky_radiance(camera, dir, unused) * (1.0 - transmittance) * (1.0 - fade);
	}
	return vec4(luminance, transmittance);
}

void sky() {
	if (AT_HALF_RES_PASS) {
		if (clouds_enabled) {
			// Reflections make do with fewer samples.
			int samples = AT_CUBEMAP_PASS ? max(clouds_samples / 2, 1) : clouds_samples;
			int light_samples = AT_CUBEMAP_PASS ? min(clouds_light_samples, 3) : clouds_light_samples;
			// Interleaved gradient noise, to trade banding for fine noise.
			float jitter = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
			vec4 clouds = clouds_march(POSITION, EYEDIR, samples, light_samples, jitter);
			COLOR = clouds.rgb * sky_energy;
			ALPHA = clouds.a;
		} else {
			COLOR = vec3(0.0);
			ALPHA = 1.0;
		}
	} else {
		vec3 camera = atmosphere_camera(POSITION);
		vec3 transmittance;
		vec3 color = sky_radiance(camera, EYEDIR, transmittance);
		float r = length(camera);
		if (ground_enabled && atm_ray_intersects_ground(r, dot(camera, EYEDIR) / r)) {
			color = ground_radiance(camera, EYEDIR);
		}

		// Reflections get the lights' own specular highlights already.
		if (!AT_CUBEMAP_PASS) {
			vec3 disks = light_disk(EYEDIR, sun_direction, sun_illuminance, sun_angular_radius, sun_disk_intensity);
			disks += light_disk(EYEDIR, moon_direction, moon_illuminance, moon_angular_radius, moon_disk_intensity);
			color += disks * transmittance;
		}

		color += texture(night_sky, SKY_COORDS).rgb * night_sky_energy * transmittance;

		COLOR = color * sky_energy;
		if (clouds_enabled) {
			COLOR = COLOR * HALF_RES_COLOR.a + HALF_RES_COLOR.rgb;
		}
	}
}
