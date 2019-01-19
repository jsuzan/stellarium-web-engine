/* Stellarium Web Engine - Copyright (c) 2018 - Noctua Software Ltd
 *
 * This program is licensed under the terms of the GNU AGPL v3, or
 * alternatively under a commercial licence.
 *
 * The terms of the AGPL v3 license can be found in the main directory of this
 * repository.
 */

#define PI 3.14159265

#ifdef GL_ES
precision mediump float;
#endif

uniform lowp    vec4      u_color;
uniform lowp    vec2      u_depth_range;
uniform mediump sampler2D u_tex;
uniform mediump sampler2D u_normal_tex;
uniform lowp    vec3      u_light_emit;
uniform mediump mat4      u_mv;  // Model view matrix.
uniform lowp    int       u_has_normal_tex;
uniform lowp    int       u_material; // 0: Oren Nayar, 1: generic, 2: ring
uniform lowp    int       u_is_moon; // Set to 1 for the Moon only.
uniform mediump sampler2D u_shadow_color_tex; // Used for the Moon.
uniform lowp    float     u_contrast;

uniform highp   vec4      u_sun; // Sun pos (xyz) and radius (w).
// Up to four spheres for illumination ray tracing.
uniform lowp    int       u_shadow_spheres_nb;
uniform mediump mat4      u_shadow_spheres;

varying highp   vec3 v_mpos;
varying mediump vec2 v_tex_pos;
varying lowp    vec4 v_color;
varying highp   vec3 v_normal;
varying highp   vec3 v_tangent;
varying highp   vec3 v_bitangent;

#ifdef VERTEX_SHADER

attribute highp   vec4 a_pos;
attribute highp   vec4 a_mpos;
attribute mediump vec2 a_tex_pos;
attribute lowp    vec3 a_color;
attribute highp   vec3 a_normal;
attribute highp   vec3 a_tangent;

void main()
{
    gl_Position = a_pos;
    gl_Position.z = (gl_Position.z - u_depth_range[0]) /
                    (u_depth_range[1] - u_depth_range[0]);
    v_mpos = a_mpos.xyz;
    v_tex_pos = a_tex_pos;
    v_color = vec4(a_color, 1.0) * u_color;

    v_normal = normalize(a_normal);
    v_tangent = normalize(a_tangent);
    v_bitangent = normalize(cross(v_normal, v_tangent));
}

#endif
#ifdef FRAGMENT_SHADER

float oren_nayar_diffuse(
        vec3 lightDirection,
        vec3 viewDirection,
        vec3 surfaceNormal,
        float roughness,
        float albedo) {

    float r2 = roughness * roughness;
    float LdotV = dot(lightDirection, viewDirection);
    float NdotL = dot(lightDirection, surfaceNormal);
    float NdotV = dot(surfaceNormal, viewDirection);
    float NaL = acos(NdotL);
    float NaV = acos(NdotV);
    float alpha = max(NaV, NaL);
    float beta = min(NaV, NaL);
    float gamma = dot(viewDirection - surfaceNormal * NdotV,
                      lightDirection - surfaceNormal * NdotL);
    float A = 1.0 - 0.5 * (r2 / (r2 + 0.33));
    float B = 0.45 * r2 / (r2 + 0.09);
    float C = sin(alpha) * tan(beta);
    float scale = 1.6; // Empirical value!
    return max(0.0, NdotL) * (A + B * max(0.0, gamma) * C) * scale;
}

/*
 * Compute the illumination if we only consider a single sphere in the scene.
 * Parameters:
 *   p       - The surface point where we compute the illumination.
 *   sphere  - A sphere: xyz -> pos, w -> radius.
 *   sun_pos - Position of the sun.
 *   sun_r   - Precomputed sun angular radius from the given point.
 */
float illumination_sphere(highp vec3 p, highp vec4 sphere, highp vec3 sun_pos, float sun_r)
{
    // Sphere angular radius as viewed from the point.
    float sph_r = asin(sphere.w / length(sphere.xyz - p));
    // Angle <sun, pos, sphere>
    highp float d = acos(min(1.0, dot(normalize(sun_pos - p),
                                normalize(sphere.xyz - p))));

    // Special case for the moon, to simulate lunar eclipses.
    // We assume the only body that can cast shadow on the moon is the Earth.
    if (u_is_moon == 1) {
        if (d >= sun_r + sph_r) return 1.0; // Outside of shadow.
        if (d <= sph_r - sun_r) return d / (sph_r - sun_r) * 0.6; // Umbra.
        if (d <= sun_r - sph_r) // Penumbra completely inside.
            return 1.0 - sph_r * sph_r / (sun_r * sun_r);
        return ((d - abs(sun_r - sph_r)) /
                (sun_r + sph_r - abs(sun_r - sph_r))) * 0.4 + 0.6;
    }

    if (d >= sun_r + sph_r) return 1.0; // Outside of shadow.
    if (d <= sph_r - sun_r) return 0.0; // Umbra.
    if (d <= sun_r - sph_r) // Penumbra completely inside.
        return 1.0 - sph_r * sph_r / (sun_r * sun_r);

    // Penumbra partially inside.
    // I took this from Stellarium, even though I am not sure how it works.
    float x = (sun_r * sun_r + d * d - sph_r * sph_r) / (2.0 * d);
    float alpha = acos(x / sun_r);
    float beta = acos((d - x) / sph_r);
    float AR = sun_r * sun_r * (alpha - 0.5 * sin(2.0 * alpha));
    float Ar = sph_r * sph_r * (beta - 0.5 * sin(2.0 * beta));
    float AS = sun_r * sun_r * 2.0 * 1.57079633;
    return 1.0 - (AR + Ar) / AS;
}

/*
 * Compute the illumination at a given point.
 * Parameters:
 *   p       - The surface point where we compute the illumination.
 */
float illumination(vec3 p)
{
    mediump float ret = 1.0;
    highp float sun_r = asin(u_sun.w / length(u_sun.xyz - p));
    for (int i = 0; i < 4; ++i) {
        if (u_shadow_spheres_nb > i) {
            highp vec4 sphere = u_shadow_spheres[i];
            ret = min(ret, illumination_sphere(p, sphere, u_sun.xyz, sun_r));
        }
    }
    return ret;
}

void main()
{
    vec3 light_dir = normalize(u_sun.xyz - v_mpos);
    // Compute N in view space
    vec3 n = v_normal;
    if (u_has_normal_tex != 0) {
        n = texture2D(u_normal_tex, v_tex_pos).rgb - vec3(0.5, 0.5, 0.0);
        // XXX: inverse the Y coordinates, don't know why!
        n = +n.x * v_tangent - n.y * v_bitangent + n.z * v_normal;
    }
    n = normalize(n);
    gl_FragColor = texture2D(u_tex, v_tex_pos) * v_color;
    gl_FragColor.rgb = (gl_FragColor.rgb - 0.5) * u_contrast + 0.5;

    if (u_material == 0) { // oren_nayar.
        float power = oren_nayar_diffuse(light_dir,
                                         normalize(-v_mpos),
                                         n,
                                         0.9, 0.12);
        lowp float illu = illumination(v_mpos);
        power *= illu;
        gl_FragColor.rgb *= power;

        // Earth shadow effect on the moon.
        if (u_is_moon == 1 && illu < 0.99) {
            vec4 shadow_col = texture2D(u_shadow_color_tex, vec2(illu, 0.5));
            gl_FragColor.rgb = mix(
                gl_FragColor.rgb, shadow_col.rgb, shadow_col.a);
        }

    } else if (u_material == 1) { // basic
        vec3 light = vec3(0.0, 0.0, 0.0);
        light += max(0.0, dot(n, light_dir));
        light += u_light_emit;
        gl_FragColor.rgb *= light;

    } else if (u_material == 2) { // ring
        lowp float illu = illumination(v_mpos);
        gl_FragColor.rgb *= illu;
    }
}

#endif
