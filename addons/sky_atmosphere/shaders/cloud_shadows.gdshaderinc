// The clouds' shadows of a SkyAtmosphere, for spatial shaders, with its
// clouds_shadows_enabled on. SkyAtmosphere already darkens the whole scene
// with them; a material that reads them itself can darken only the sun's
// light instead, which is what really is in the shadow, for instance in its
// light() function:
//
//     #include "res://addons/sky_atmosphere/shaders/cloud_shadows.gdshaderinc"
//
//     varying vec3 world_position;
//
//     void vertex() {
//         world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
//     }
//
//     void light() {
//         float shadow = LIGHT_IS_DIRECTIONAL ? sky_cloud_shadow(world_position) : 1.0;
//         DIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION * LIGHT_COLOR / PI * shadow;
//     }
//
// The three global shader parameters below have to be declared in the
// project (Project Settings > Shader Globals) for a shader to use them:
// - sky_cloud_shadows, a sampler2D;
// - sky_cloud_shadows_area, a vec4;
// - sky_cloud_shadows_light, a vec4.
// SkyAtmosphere sets them every frame.
//
// The shadows also make the scene's own darkening redundant: turn
// clouds_shadows_strength down to 0 when materials do it themselves, and they
// keep the map and its parameters (whose strength is then 0, as below).

global uniform sampler2D sky_cloud_shadows : filter_linear, repeat_disable;
// xy: the map's center (world units, x and z), z: 1 / its size, w: strength.
global uniform vec4 sky_cloud_shadows_area;
// xyz: towards the sun.
global uniform vec4 sky_cloud_shadows_light;

// What of the sun gets through the clouds to world_position, 1 for all of it.
float sky_cloud_shadow(vec3 world_position) {
	if (sky_cloud_shadows_area.z <= 0.0) {
		return 1.0;
	}
	vec3 light = sky_cloud_shadows_light.xyz;
	light.y = max(light.y, 0.05);
	light = normalize(light);
	vec2 ground = world_position.xz - light.xz * (world_position.y / light.y);
	vec2 uv = (ground - sky_cloud_shadows_area.xy) * sky_cloud_shadows_area.z + 0.5;
	vec2 edge = abs(uv - 0.5);
	float inside = 1.0 - smoothstep(0.4, 0.5, max(edge.x, edge.y));
	return mix(1.0, texture(sky_cloud_shadows, uv).r, inside);
}
