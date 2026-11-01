// Eric Bruneton's precomputed atmospheric scattering ("Precomputed Atmospheric
// Scattering", EGSR 2008, as revised in his 2017 reference implementation),
// in RGB and in kilometers, the planet's center at the origin.
//
// This file is included both by the sky shader and by the addon's compute
// shaders (where the C++ side pastes it in), so it keeps to what the Godot
// shading language and GLSL have in common. Whoever includes it declares
// first, under these names:
// - the parameters: atm_bottom_radius, atm_top_radius, atm_rayleigh_scattering,
//   atm_rayleigh_scale_height, atm_mie_scattering, atm_mie_extinction, atm_mie_g,
//   atm_mie_scale_height, atm_absorption_extinction, atm_ozone_tip,
//   atm_ozone_width, atm_ground_albedo, atm_sun_angular_radius, atm_mu_s_min;
// - unless ATM_NO_TEXTURES is defined, atm_transmittance_texture;
// - unless ATM_PRECOMPUTE is defined, atm_scattering_texture,
//   atm_single_mie_texture and atm_irradiance_texture too;
// - and with ATM_LIGHT_SHADOW defined, float atm_light_shadow(float), which
//   atm_aerial_perspective() shadows its first light with.
// PI comes from the Godot shading language, or from a define in GLSL.

// Keep in sync with atmosphere_params.h.
const float ATM_TRANSMITTANCE_W = 256.0;
const float ATM_TRANSMITTANCE_H = 64.0;
const float ATM_SCATTERING_R = 32.0;
const float ATM_SCATTERING_MU = 128.0;
const float ATM_SCATTERING_MU_S = 32.0;
const float ATM_SCATTERING_NU = 8.0;
const float ATM_IRRADIANCE_W = 64.0;
const float ATM_IRRADIANCE_H = 16.0;

float atm_safe_sqrt(float a) {
	return sqrt(max(a, 0.0));
}

float atm_clamp_cosine(float mu) {
	return clamp(mu, -1.0, 1.0);
}

float atm_clamp_radius(float r) {
	return clamp(r, atm_bottom_radius, atm_top_radius);
}

float atm_distance_to_top(float r, float mu) {
	float discriminant = r * r * (mu * mu - 1.0) + atm_top_radius * atm_top_radius;
	return max(-r * mu + atm_safe_sqrt(discriminant), 0.0);
}

float atm_distance_to_bottom(float r, float mu) {
	float discriminant = r * r * (mu * mu - 1.0) + atm_bottom_radius * atm_bottom_radius;
	return max(-r * mu - atm_safe_sqrt(discriminant), 0.0);
}

bool atm_ray_intersects_ground(float r, float mu) {
	return mu < 0.0 && r * r * (mu * mu - 1.0) + atm_bottom_radius * atm_bottom_radius >= 0.0;
}

float atm_distance_to_nearest_boundary(float r, float mu, bool ray_intersects_ground) {
	return ray_intersects_ground ? atm_distance_to_bottom(r, mu) : atm_distance_to_top(r, mu);
}

// How dense each kind of matter is at an altitude, relative to the ground for
// air and haze, and to the peak of the ozone layer for ozone.
float atm_rayleigh_density(float altitude) {
	return exp(-altitude / max(atm_rayleigh_scale_height, 1e-3));
}

float atm_mie_density(float altitude) {
	return exp(-altitude / max(atm_mie_scale_height, 1e-3));
}

float atm_ozone_density(float altitude) {
	return max(0.0, 1.0 - abs(altitude - atm_ozone_tip) / max(atm_ozone_width * 0.5, 1e-3));
}

float atm_rayleigh_phase(float nu) {
	return 3.0 / (16.0 * PI) * (1.0 + nu * nu);
}

// Cornette-Shanks.
float atm_mie_phase(float g, float nu) {
	float k = 3.0 / (8.0 * PI) * (1.0 - g * g) / (2.0 + g * g);
	return k * (1.0 + nu * nu) / pow(max(1.0 + g * g - 2.0 * g * nu, 1e-6), 1.5);
}

// Texture coordinates that put 0 and 1 at the centers of the first and last
// texels, so that the ends of the range are sampled exactly.
float atm_texcoord_from_unit(float x, float size) {
	return 0.5 / size + x * (1.0 - 1.0 / size);
}

float atm_unit_from_texcoord(float u, float size) {
	return (u - 0.5 / size) / (1.0 - 1.0 / size);
}

vec2 atm_transmittance_uv(float r, float mu) {
	float H = sqrt(atm_top_radius * atm_top_radius - atm_bottom_radius * atm_bottom_radius);
	float rho = atm_safe_sqrt(r * r - atm_bottom_radius * atm_bottom_radius);
	float d = atm_distance_to_top(r, mu);
	float d_min = atm_top_radius - r;
	float d_max = rho + H;
	float x_mu = (d - d_min) / max(d_max - d_min, 1e-6);
	float x_r = rho / H;
	return vec2(atm_texcoord_from_unit(x_mu, ATM_TRANSMITTANCE_W), atm_texcoord_from_unit(x_r, ATM_TRANSMITTANCE_H));
}

// Where in the scattering table (nu, mu_s, mu, r, each in [0, 1]) the light
// scattered at r towards -mu is, for the sun at mu_s and nu between the two.
vec4 atm_scattering_uvwz(float r, float mu, float mu_s, float nu, bool ray_intersects_ground) {
	float H = sqrt(atm_top_radius * atm_top_radius - atm_bottom_radius * atm_bottom_radius);
	float rho = atm_safe_sqrt(r * r - atm_bottom_radius * atm_bottom_radius);
	float u_r = atm_texcoord_from_unit(rho / H, ATM_SCATTERING_R);

	// Rays that hit the ground take the bottom half of the mu axis, the others
	// the top half, so the discontinuity at the horizon falls between texels.
	float r_mu = r * mu;
	float discriminant = r_mu * r_mu - r * r + atm_bottom_radius * atm_bottom_radius;
	float u_mu;
	if (ray_intersects_ground) {
		float d = -r_mu - atm_safe_sqrt(discriminant);
		float d_min = r - atm_bottom_radius;
		float d_max = rho;
		u_mu = 0.5 - 0.5 * atm_texcoord_from_unit(d_max == d_min ? 0.0 : (d - d_min) / (d_max - d_min), ATM_SCATTERING_MU / 2.0);
	} else {
		float d = -r_mu + atm_safe_sqrt(discriminant + H * H);
		float d_min = atm_top_radius - r;
		float d_max = rho + H;
		u_mu = 0.5 + 0.5 * atm_texcoord_from_unit((d - d_min) / max(d_max - d_min, 1e-6), ATM_SCATTERING_MU / 2.0);
	}

	float d = atm_distance_to_top(atm_bottom_radius, mu_s);
	float d_min = atm_top_radius - atm_bottom_radius;
	float d_max = H;
	float a = (d - d_min) / (d_max - d_min);
	float D = atm_distance_to_top(atm_bottom_radius, atm_mu_s_min);
	float A = (D - d_min) / (d_max - d_min);
	float u_mu_s = atm_texcoord_from_unit(max(1.0 - a / A, 0.0) / (1.0 + a), ATM_SCATTERING_MU_S);

	float u_nu = (nu + 1.0) / 2.0;
	return vec4(u_nu, u_mu_s, u_mu, u_r);
}

vec2 atm_irradiance_uv(float r, float mu_s) {
	float x_r = (r - atm_bottom_radius) / (atm_top_radius - atm_bottom_radius);
	float x_mu_s = mu_s * 0.5 + 0.5;
	return vec2(atm_texcoord_from_unit(x_mu_s, ATM_IRRADIANCE_W), atm_texcoord_from_unit(x_r, ATM_IRRADIANCE_H));
}

#ifndef ATM_NO_TEXTURES

vec3 atm_transmittance_to_top(float r, float mu) {
	return textureLod(atm_transmittance_texture, atm_transmittance_uv(r, mu), 0.0).rgb;
}

// Between the point at r, looking towards mu, and the one d further along.
vec3 atm_transmittance(float r, float mu, float d, bool ray_intersects_ground) {
	float r_d = atm_clamp_radius(sqrt(d * d + 2.0 * r * mu * d + r * r));
	float mu_d = atm_clamp_cosine((r * mu + d) / r_d);
	if (ray_intersects_ground) {
		return min(atm_transmittance_to_top(r_d, -mu_d) / max(atm_transmittance_to_top(r, -mu), vec3(1e-20)), vec3(1.0));
	}
	return min(atm_transmittance_to_top(r, mu) / max(atm_transmittance_to_top(r_d, mu_d), vec3(1e-20)), vec3(1.0));
}

// What of the sun reaches r with the sun at mu_s, the part of its disk still
// above the horizon included.
vec3 atm_transmittance_to_sun(float r, float mu_s) {
	float sin_theta_h = atm_bottom_radius / r;
	float cos_theta_h = -sqrt(max(1.0 - sin_theta_h * sin_theta_h, 0.0));
	return atm_transmittance_to_top(r, mu_s) * smoothstep(-sin_theta_h * atm_sun_angular_radius, sin_theta_h * atm_sun_angular_radius, mu_s - cos_theta_h);
}

#endif // ATM_NO_TEXTURES

#ifndef ATM_PRECOMPUTE

// Rayleigh and multiple scattering (without their phase function), and single
// Mie scattering in a table of its own: what reaches r from -mu, with the sun
// at mu_s and nu between the two. Both tables store nu in slices along their
// width, which are interpolated by hand.
vec3 atm_scattering(float r, float mu, float mu_s, float nu, bool ray_intersects_ground, out vec3 single_mie) {
	vec4 uvwz = atm_scattering_uvwz(r, mu, mu_s, nu, ray_intersects_ground);
	float tex_coord_x = uvwz.x * (ATM_SCATTERING_NU - 1.0);
	float tex_x = floor(tex_coord_x);
	float lerp_factor = tex_coord_x - tex_x;
	vec3 uvw0 = vec3((tex_x + uvwz.y) / ATM_SCATTERING_NU, uvwz.z, uvwz.w);
	vec3 uvw1 = vec3((tex_x + 1.0 + uvwz.y) / ATM_SCATTERING_NU, uvwz.z, uvwz.w);
	single_mie = mix(textureLod(atm_single_mie_texture, uvw0, 0.0).rgb, textureLod(atm_single_mie_texture, uvw1, 0.0).rgb, lerp_factor);
	return mix(textureLod(atm_scattering_texture, uvw0, 0.0).rgb, textureLod(atm_scattering_texture, uvw1, 0.0).rgb, lerp_factor);
}

vec3 atm_irradiance(float r, float mu_s) {
	return textureLod(atm_irradiance_texture, atm_irradiance_uv(r, mu_s), 0.0).rgb;
}

// The light the air scatters towards camera along view_ray, from a light of
// unit illuminance towards light_direction, and what of the light behind it
// still gets through: the sky's own radiance.
vec3 atm_sky_radiance(vec3 camera, vec3 view_ray, vec3 light_direction, out vec3 transmittance) {
	vec3 origin = camera;
	float r = length(origin);
	float rmu = dot(origin, view_ray);
	float distance_to_top = -rmu - sqrt(rmu * rmu - r * r + atm_top_radius * atm_top_radius);
	// From space, start where the ray enters the atmosphere.
	if (distance_to_top > 0.0) {
		origin = origin + view_ray * distance_to_top;
		r = atm_top_radius;
		rmu += distance_to_top;
	} else if (r > atm_top_radius) {
		transmittance = vec3(1.0);
		return vec3(0.0);
	}
	float mu = rmu / r;
	float mu_s = dot(origin, light_direction) / r;
	float nu = dot(view_ray, light_direction);
	bool ray_intersects_ground = atm_ray_intersects_ground(r, mu);
	transmittance = ray_intersects_ground ? vec3(0.0) : atm_transmittance_to_top(r, mu);
	vec3 single_mie;
	vec3 scattering = atm_scattering(r, mu, mu_s, nu, ray_intersects_ground, single_mie);
	return scattering * atm_rayleigh_phase(nu) + single_mie * atm_mie_phase(atm_mie_g, nu);
}

// The air between camera and point, marched in p_samples steps, lit by two
// lights: what it scatters towards camera, and what of point's own light gets
// through it. The tables would give this as the difference between the light
// reaching camera and point along the same ray, but next to the horizon both
// are huge (the ray goes on through a thousand kilometers of air) and their
// difference falls apart; marched, the segment has no horizon.
//
// Single scattering is exact, shadowed by the planet through the
// transmittance table; the higher orders come from the sky's irradiance, as
// light arriving from everywhere at once.
vec3 atm_aerial_perspective(vec3 camera, vec3 point, vec3 light_direction_0, vec3 illuminance_0, vec3 light_direction_1, vec3 illuminance_1, int p_samples, out vec3 transmittance) {
	vec3 segment = point - camera;
	float d = length(segment);
	vec3 dir = segment / max(d, 1e-9);
	float dt = d / float(max(p_samples, 1));
	float nu_0 = dot(dir, light_direction_0);
	float nu_1 = dot(dir, light_direction_1);
	vec2 rayleigh_phase = vec2(atm_rayleigh_phase(nu_0), atm_rayleigh_phase(nu_1));
	vec2 mie_phase = vec2(atm_mie_phase(atm_mie_g, nu_0), atm_mie_phase(atm_mie_g, nu_1));

	vec3 optical_depth = vec3(0.0);
	vec3 inscatter = vec3(0.0);
	for (int i = 0; i < max(p_samples, 1); i++) {
		vec3 p = camera + dir * ((float(i) + 0.5) * dt);
		float r = atm_clamp_radius(length(p));
		vec3 up = p / max(length(p), 1e-9);
		float altitude = r - atm_bottom_radius;
		float rayleigh_density = atm_rayleigh_density(altitude);
		float mie_density = atm_mie_density(altitude);
		vec3 rayleigh = atm_rayleigh_scattering * rayleigh_density;
		vec3 mie = atm_mie_scattering * mie_density;
		vec3 extinction = rayleigh + atm_mie_extinction * mie_density + atm_absorption_extinction * atm_ozone_density(altitude);

		// The sky's light, half of the sphere bright as the sky above and the
		// other half dark, scattered evenly.
		float mu_s_0 = dot(up, light_direction_0);
		float mu_s_1 = dot(up, light_direction_1);
		// The first light's shadows in the air, if whoever includes this has
		// any: atm_light_shadow() gets how far along the segment the step is.
		float shadow_0 = 1.0;
#ifdef ATM_LIGHT_SHADOW
		shadow_0 = atm_light_shadow((float(i) + 0.5) / float(max(p_samples, 1)));
#endif
		vec3 source = illuminance_0 * (atm_transmittance_to_sun(r, mu_s_0) * shadow_0 * (rayleigh * rayleigh_phase.x + mie * mie_phase.x) + atm_irradiance(r, mu_s_0) * (rayleigh + mie) / (2.0 * PI));
		if (dot(illuminance_1, illuminance_1) > 0.0) {
			source += illuminance_1 * (atm_transmittance_to_sun(r, mu_s_1) * (rayleigh * rayleigh_phase.y + mie * mie_phase.y) + atm_irradiance(r, mu_s_1) * (rayleigh + mie) / (2.0 * PI));
		}

		// Integrated over the step, as in Hillaire's "Physically Based Sky,
		// Atmosphere and Cloud Rendering in Frostbite".
		vec3 step_transmittance = exp(-extinction * dt);
		inscatter += exp(-optical_depth) * source * (1.0 - step_transmittance) / max(extinction, vec3(1e-9));
		optical_depth += extinction * dt;
	}
	transmittance = exp(-optical_depth);
	return inscatter;
}

// What a surface at point facing normal receives from a light of unit
// illuminance towards light_direction: directly (returned), and from the sky.
vec3 atm_sun_and_sky_irradiance(vec3 point, vec3 normal, vec3 light_direction, out vec3 sky_irradiance) {
	float r = length(point);
	float mu_s = dot(point, light_direction) / r;
	sky_irradiance = atm_irradiance(r, mu_s) * (1.0 + dot(normal, point) / r) * 0.5;
	return atm_transmittance_to_sun(r, mu_s) * max(dot(normal, light_direction), 0.0);
}

#endif // ATM_PRECOMPUTE
