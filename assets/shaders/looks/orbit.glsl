// orbit.glsl -- Orbit (u_look 6): a ringed planet's limb catching a low sun.
// The light is the subject: the atmosphere's scattered rim, brightest on the
// sunward limb; the rings as bands of light with a gap, passing behind the
// planet and shadowed by it; sparse glints of ring particles. The planet
// itself is a dark silhouette against the light.
// Light is the subject: the atmosphere's scattered rim (bright on the sunward
// limb, thinning round the terminator), the rings as bands of light with
// gaps, shadowed where the planet blocks the sun, and prismatic glints along
// the lit ring. The planet itself is dark: a silhouette against the light.
vec3 orbit(vec2 uv, vec3 dawnBase, float starsNight, out vec3 emitN, out vec3 dawnN, out float lit) {
    float t = u_time * u_live;
    vec2 L = normalize(u_dir);
    // One composition for every theme: the planet low on the left, well
    // inside the frame (it sat mostly off the bottom), the rings sweeping up
    // to the right. It does not follow the theme's light direction or seed:
    // a planet that moved with each theme read as a different scene.
    vec2 pc = vec2(-0.52, -0.30);
    float R = 0.50;
    vec2 d = uv - pc;
    float dp = length(d);
    vec2 sun = normalize(vec2(0.55, 0.85));                  // light from the upper right, behind
    float inside = smoothstep(R + 0.002, R - 0.002, dp);
    // atmosphere: a thin rim outside the limb, brightest toward the sun
    float facing = 0.5 + 0.5 * dot(normalize(d), sun);
    float atm = exp(-max(dp - R, 0.0) / 0.018) * (1.0 - inside) + exp(-max(R - dp, 0.0) / 0.006) * inside * 0.6;
    atm *= pow(facing, 2.2);
    float scatter = exp(-max(dp - R, 0.0) / 0.12) * (1.0 - inside) * pow(facing, 3.0);
    // the terminator: the night side of the disc stays black, a sliver lit
    float day = smoothstep(0.05, 0.35, dot(normalize(d), sun)) * smoothstep(R - 0.10, R, dp) * inside;
    // rings: an ellipse in the planet's frame, tilted
    float ra = 0.42;
    vec2 rd = vec2(cos(ra) * d.x + sin(ra) * d.y, -sin(ra) * d.x + cos(ra) * d.y);
    vec2 re = rd / vec2(1.0, 0.26);
    float rr = length(re) * (0.78 / R);   // ring radii in planet radii (drawn at R = 0.78)
    float band = smoothstep(1.08, 1.11, rr) * smoothstep(1.95, 1.86, rr);
    // ringlets and one clear gap, as the real ones have
    float struc = 0.50 + 0.50 * vnoise(vec2(rr * 55.0, 0.5)) - 0.85 * smoothstep(1.52, 1.54, rr) * smoothstep(1.62, 1.60, rr);
    // the far half of the rings goes behind the planet; the near half in front
    // softened: a hard switch from behind to in front drew a straight seam
    float behindPlanet = smoothstep(-0.02, 0.02, rd.y) * inside;
    // the planet's shadow falls across the rings, away from the sun
    vec2 toSun = -sun;
    // soft-edged on both axes: a hard edge on either cut the ring off in a
    // straight line (the step at dot(d, sun) = 0 drew a seam across it)
    float inShadow = smoothstep(0.08, -0.08, dot(d, sun)) * smoothstep(R * 1.25, R * 0.80, abs(dot(d, vec2(-sun.y, sun.x)))) * 0.75;
    float ringLight = band * struc * (1.0 - behindPlanet) * (1.0 - inShadow * 0.85);
    // glints: sparse points of sunlight caught by ring particles
    float glint = starLayer(uv + u_seed, 70.0, 0.08, 500.0, u_live) * band * (1.0 - inShadow) * (1.0 - behindPlanet);
    vec3 col = vec3(0.0);
    col += mixo(u_c2, u_c3, 0.6) * ringLight * 0.30;
    col += vec3(1.0, 0.85, 0.95) * mixo(u_c3, u_star, 0.5) * glint * 0.45;
    col += mixo(u_c3, u_star, 0.35) * atm * 0.55 + mixo(u_c2, u_c3, 0.5) * scatter * 0.30;
    col += mixo(u_c1, u_c2, 0.5) * day * 0.12;
    col *= 1.0 - inside * (1.0 - day) * 0.9;                 // the planet occludes what is behind it
    col += u_star * starsNight * 0.45 * (1.0 - inside) * u_stars;
    emitN = mixo(u_c3, u_star, 0.4) * atm * 0.16 + u_c3 * glint * 0.20;
    lit = clamp(atm + ringLight * 0.4, 0.0, 1.0);
    // the light cut, only when light shows (dark never reads it)
    dawnN = vec3(0.0);
    if (wantDawn) {
        vec3 pale = mixo(u_c2, vec3(1.0), 0.50 + 0.40 * u_wash);
        dawnN = mixo(dawnBase, pale, clamp(atm * 0.8 + scatter * 0.5 + ringLight * 0.45, 0.0, 0.85));
        dawnN = mixo(dawnN, mixo(u_c1, u_c2, 0.5) * 0.9, inside * (1.0 - day) * 0.12);
        // the limb and the rings in the theme's colour
        dawnN = mixo(dawnN, mixo(u_c2, u_c3, 0.5), clamp(atm * 0.65 + ringLight * 0.40, 0.0, 0.75));
    }
    return grey(col, u_desat) * u_gain;
}
