// relief.glsl -- Relief (u_look 4): a topographic map of an unseen land, lit by
// one travelling light. Hairline contour lines of a smooth height field, every
// fifth an index line; the light blooms where it meets them and the index
// lines glow faintly of their own; high ground is nearer and brighter. Live,
// the land drifts and the light wanders, very slowly. The light cut is a
// printed map in the theme's ink.
float reliefH(vec2 p) { return fbm3n(p) + 0.35 * fbm3n(p * 2.1 + 5.3); }
vec3 relief(vec2 uv, vec3 dawnBase, out vec3 emitN, out vec3 dawnN, out float lit) {
    float t = u_time * u_live;
    // the land drifts, very slowly; the light wanders over it
    vec2 p = uv * 1.25 + u_seed * 0.11 + vec2(0.004, 0.0025) * t;
    float h = reliefH(p);
    float e = 1.5 / u_resolution.y;
    float gx = reliefH(p + vec2(e * 1.25, 0.0)) - h;
    float gy = reliefH(p + vec2(0.0, e * 1.25)) - h;
    float grad = length(vec2(gx, gy)) / e;
    float N = 26.0;
    float v = h * N;
    float fw = max(grad * N / u_resolution.y, 1e-4);          // one pixel, in v units
    float dist = abs(fract(v) - 0.5);                          // 0.5 on a line
    float isIndex = 1.0 - step(0.01, abs(mod(floor(v + 0.5), 5.0)));
    float line = smoothstep(0.5 - fw * (isIndex > 0.5 ? 1.8 : 1.15), 0.5 - fw * 0.15, dist);
    float near = smoothstep(0.5 - fw * 7.0, 0.5, dist);        // a soft halo round each line
    vec2 L = normalize(u_dir);
    vec2 bc = L * 0.45 + vec2(0.05, 0.0) + 0.06 * vec2(sin(t * 0.05), cos(t * 0.037));
    float d = length(uv - bc);
    float bloom = gauss(d / 0.55);
    float glow = gauss(d / 0.95);
    // depth: the high ground is nearer and brighter, the valleys recede
    float alt = mix(0.45, 1.0, smoothstep(0.25, 1.05, h));
    vec3 ink = mixo(u_c2, u_c3, smoothstep(0.2, 0.9, bloom));
    float band = fract(floor(v) / 5.0);
    vec3 tint = mixo(u_c1, u_c2, band) * (0.012 + 0.045 * bloom) * alt;
    vec3 col = u_c1 * glow * 0.30 + tint + ink * line * (0.05 + 1.0 * bloom) * alt;
    // luminescence: the light blooms where it meets the lines, and the index
    // lines carry a faint glow of their own
    emitN = mixo(u_c2, u_c3, 0.5) * near * bloom * bloom * 0.10 * alt
          + u_c3 * isIndex * near * bloom * 0.14 * alt;
    lit = clamp(line * bloom + glow * 0.3, 0.0, 1.0);
    // light: a printed map in the theme's ink, a whisper of the light as wash
    vec3 wash = mixo(dawnBase, mixo(u_c2, vec3(1.0), 0.55 + 0.4 * u_wash), glow * 0.28);
    dawnN = mixo(wash, mixo(u_c1, u_c2, 0.4) * 0.82,
                 line * (0.14 + 0.36 * bloom) * mix(0.6, 1.0, alt) * (isIndex > 0.5 ? 1.25 : 1.0));
    return grey(col, u_desat) * u_gain;
}
