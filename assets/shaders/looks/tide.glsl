// tide.glsl -- Tide (u_look 5): caustic light on a pool floor, thrown by light
// through moving water. Glowing filaments with a wide soft halo, each channel
// at a slightly different scale so every filament splits a little into
// colour, and faint shafts slanting down from the surface. Live, the water
// moves.
// Voronoi F2-F1 nets (0 on every cell wall) over a warped domain, drawn as
// glowing filaments with a wide soft halo rather than hard edges, the three
// channels at slightly different scales so every filament splits a little
// into colour, and faint shafts slanting down from the surface.
float cellEdge(vec2 p, float t) {
    vec2 i = floor(p), f = fract(p);
    float f1 = 8.0, f2 = 8.0;
    for (int y = -1; y <= 1; y++)
    for (int x = -1; x <= 1; x++) {
        vec2 g = vec2(float(x), float(y));
        vec2 h = vec2(hash(i + g), hash(i + g + 17.3));
        vec2 o = g + 0.5 + 0.40 * sin(t + 6.2831 * h) - f;
        float d = dot(o, o);
        if (d < f1) { f2 = f1; f1 = d; } else if (d < f2) { f2 = d; }
    }
    return sqrt(f2) - sqrt(f1);
}
float causticN(vec2 q, float t) {
    float e1 = cellEdge(q, t);
    float e2 = cellEdge(q * 1.7 + 4.1, t * 1.3);
    float px = 2.0 * 5.0 / u_resolution.y;
    // a bright thin core and a wide soft glow: light, not cracks
    float c1 = exp(-e1 / (0.030 + px)) + 0.45 * exp(-e1 / 0.16);
    float c2 = exp(-e2 / (0.025 + px)) + 0.45 * exp(-e2 / 0.14);
    return c1 * 0.55 + c1 * c2 * 0.55 + c2 * 0.10;
}
vec3 tide(vec2 uv, vec3 dawnBase, out vec3 emitN, out vec3 dawnN, out float lit) {
    float t = 1.7 + u_time * 0.06 * u_live;
    vec2 p = uv * 5.0 + u_seed * 0.3;
    vec2 w = vec2(fbm3n(p * 0.30 + 1.3 + t * 0.05), fbm3n(p * 0.30 + 7.9 - t * 0.04)) - 0.5;
    vec2 q = p + w * 1.8;
    vec3 c = vec3(causticN(q * 1.012, t), causticN(q, t), causticN(q * 0.988, t));
    vec2 L = normalize(u_dir);
    float pool = gauss(length(uv - L * 0.40) / 0.62);
    float side = litSideN(uv);
    // shafts: long soft streaks slanting down from the surface
    float sh = fbm3n(vec2(dot(uv, vec2(0.9, 0.35)) * 7.0, 0.5 + t * 0.02));
    float shafts = smoothstep(0.55, 0.9, sh) * smoothstep(-0.6, 0.5, uv.y) * 0.5;
    vec3 floorC = mixo(u_c1, u_c2, 0.35) * pool * 0.14;
    vec3 web = vec3(mixo(u_c2, u_c3, 0.6).r * c.r, mixo(u_c2, u_c3, 0.6).g * c.g, mixo(u_c2, u_c3, 0.6).b * c.b);
    vec3 col = floorC + web * (0.005 + 0.42 * pool * pool) * side + u_c2 * shafts * pool * 0.06;
    float cl = dot(c, vec3(0.333));
    emitN = u_c3 * smoothstep(0.9, 1.6, cl) * pool * side * 0.10;
    lit = clamp(cl * pool * side * 0.8, 0.0, 1.0);
    vec3 pale = mixo(u_c2, vec3(1.0), 0.55 + 0.35 * u_wash);
    // light: the net drawn in the theme's colour on pale water
    dawnN = mixo(dawnBase, pale, pool * 0.30);
    dawnN = mixo(dawnN, mixo(u_c2, u_c3, 0.5), clamp(cl * (0.15 + 0.55 * pool) * side, 0.0, 0.6));
    return grey(col, u_desat) * u_gain;
}
