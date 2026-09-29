// nebula.glsl -- Nebula (u_look 0), the look Pulsar shipped with: a domain-warped
// noise field (iq's f(p + fbm(p + fbm(p)))) folded like defocused light
// through fabric, lit only in the palette, over a near-black ground with
// stars in the dark. Its signature luminescence is ion trails: filaments on
// the field's isolines with a halo, over a faint circuit lattice lit only by
// the glow near it.
//
// LOCKED: the field is approved as-is -- do not retune its constants or math.
// The brand half is pulsar.frag's, the theme half theme.frag's; both are the
// code that sat in those files' main(), moved here unchanged.

#ifdef BRAND

vec2 nebula_w;
float nebula_f, nebula_mask, nebula_lum;
vec3 nebula_col;

// the field; w and f only when Nebula shows (a skipped look costs nothing)
void nebulaField(float wNebula) {
    nebula_w = vec2(0.0);
    nebula_f = 0.0;
    if (wNebula > 0.0) {
        vec2 p = uv * 2.2 + vec2(0.0, u_time * 0.01);
        vec2 q = vec2(fbm(p), fbm(p + vec2(5.2, 1.3)));
        nebula_w = vec2(fbm(p + 3.0 * q + vec2(1.7, 9.2)),
                      fbm(p + 3.0 * q + vec2(8.3, 2.8)));
        nebula_f = fbm(p + 3.0 * nebula_w);
    }
    // light mass flows out of the lower-left; the upper-right goes dark.
    // the smoothstep remap is contrast, not gain: creases below 0.28 stay
    // black, folds above it glow -- raising overall gain instead of this is
    // what made an earlier cut read as uniform smoke
    nebula_mask = smoothstep(1.05, -0.55, dot(uv, normalize(vec2(0.80, 0.60))));
    nebula_lum = pow(smoothstep(0.28, 0.92, nebula_f), 1.6) * nebula_mask;
    // color from the fold depth, brand ramp only, then pulled toward grey --
    // full-sat hues are what made the earlier cuts read like test cards
    vec3 nebula = pmix(VIOLET * 0.75, PERI, smoothstep(0.35, 0.75, nebula_f));
    nebula = pmix(nebula, CYAN, smoothstep(0.70, 0.95, nebula_f) * 0.8);
    nebula_col = mix(nebula, vec3(dot(nebula, vec3(0.30, 0.55, 0.15))), 0.18);
}

// the night: kept LOW on purpose -- this sits behind a desktop full of
// windows, and the reference boards go to true black in the empty regions.
// Every brand look's chain starts from it.
vec3 nebulaNight() {
    vec3 night = mix(pal() ? u_p_ga : vec3(0.005, 0.006, 0.016),      // upper-right, near black
                     pal() ? u_p_gb : vec3(0.016, 0.019, 0.048),      // lower-left, indigo cast
                     nebula_mask);
    night += nebula_col * nebula_lum * 0.75;
    night += STAR * starsNight * clamp(1.0 - nebula_lum * 3.0, 0.0, 1.0) * 0.55;
    night *= 1.0 - 0.40 * smoothstep(0.55, 1.10, r); // vignette
    // soft downlight from the top, same move as the tile icon's ambient glow:
    // widest at top center, gone by mid-frame, periwinkle so it stays cool
    night += PERI * 0.17 * pow(smoothstep(-0.25, 0.62, uv.y), 1.6)
           * (0.70 + 0.30 * exp(-uv.x * uv.x * 1.2));
    return night;
}

// dawn: the field as watercolor, wetter than before
vec3 nebulaDawn(vec3 dawn) {
    vec3 wet = pmix(mix(PERI, vec3(1.0), 0.12), mix(CYAN, vec3(1.0), 0.20),
                    smoothstep(0.6, 0.9, nebula_f));
    dawn = mix(dawn, wet, nebula_lum * 0.95);
    dawn = mix(dawn, mix(VIOLET, vec3(1.0), 0.60), starsDawn * 0.35); // pale glints
    return dawn;
}

void nebulaGlow(float wNebula) {
    g2 = fbm3(uv * 2.7 + nebula_w * 1.8 + 4.1);
    float ca = 0.0020;
    vec3 f3 = vec3(glowLine(g2 - 0.52 - ca, 0.0060), glowLine(g2 - 0.52, 0.0060), glowLine(g2 - 0.52 + ca, 0.0060))
            + 0.5 * vec3(glowLine(nebula_f - 0.63 - ca, 0.0050), glowLine(nebula_f - 0.63, 0.0050), glowLine(nebula_f - 0.63 + ca, 0.0050));
    float halo = glowLine(g2 - 0.52, 0.050) + 0.5 * glowLine(nebula_f - 0.63, 0.040);
    float tr = lattice(uv, 26.0);
    emit += wNebula * (CYAN * f3 * 0.55 * carry + PERI * halo * 0.12 * carry
                     + mix(VIOLET, PERI, 0.5) * tr * (0.010 + 0.18 * inten));
    dawnFx += wNebula * vec3(f3.g * 0.28 * (0.1 + 0.9 * carry));
    dawnInk += wNebula * tr * 0.025;
}

vec3 nebulaPearl(vec3 dawn, float amount) {
    vec3 pearl = mix(0.5 + 0.5 * cos(6.2831 * (g2 * 2.2 + nebula_f * 0.8 + vec3(0.0, 0.33, 0.67))),
                     mix(PERI, vec3(1.0), 0.3), 0.8);
    return mix(dawn, pearl, amount);
}

#else

vec2 nebula_w;
float nebula_f, nebula_lum;

vec3 nebulaNight() {
    vec2 dir = normalize(-u_dir);   // mask falls off TOWARD this
    vec2 p = uv * u_fold + u_seed;
    vec2 q = vec2(fbm(p), fbm(p + vec2(5.2, 1.3)));
    nebula_w = vec2(fbm(p + 3.0 * q + vec2(1.7, 9.2)), fbm(p + 3.0 * q + vec2(8.3, 2.8)));
    nebula_f = fbm(p + 3.0 * nebula_w);
    float mask = smoothstep(1.05, -0.55, dot(uv, dir));
    nebula_lum = pow(smoothstep(0.28, 0.92, nebula_f), 1.6) * mask;
    vec3 nebula = mixo(u_c1 * 0.75, u_c2, smoothstep(0.35, 0.75, nebula_f));
    nebula = mixo(nebula, u_c3, smoothstep(0.70, 0.95, nebula_f) * 0.8);
    nebula = grey(nebula, u_desat);

    vec3 night = mix(u_ga, u_gb, mask);
    night += nebula * nebula_lum * 0.75 * u_gain;
    night += u_star * starsNight * clamp(1.0 - nebula_lum * 3.0, 0.0, 1.0) * 0.55 * u_stars;
    night *= 1.0 - 0.40 * smoothstep(0.55, 1.10, r);
    night += u_c2 * u_down * pow(smoothstep(-0.25, 0.62, uv.y), 1.6) * (0.70 + 0.30 * exp(-uv.x * uv.x * 1.2));
    return night;
}

vec3 nebulaDawn() {
    vec3 dawn = dawnBase;
    vec3 wet = mixo(mixo(l1, l2, smoothstep(0.35, 0.75, nebula_f)), l3, smoothstep(0.6, 0.9, nebula_f));
    dawn = mixo(dawn, wet, nebula_lum * 0.95 * u_gain);
    dawn = mixo(dawn, mixo(u_c1, vec3(1.0), 0.45), starsDawn * 0.35 * u_stars);
    return dawn;
}

void nebulaGlow(float wNebula) {
    g2 = fbm(uv * 2.7 + nebula_w * 1.8 + u_seed * 0.73 + 4.1);
    float ca = 0.0020 * u_signal;
    vec3 f3 = vec3(line(g2 - 0.52 - ca, 0.0060), line(g2 - 0.52, 0.0060), line(g2 - 0.52 + ca, 0.0060))
            + 0.5 * vec3(line(nebula_f - 0.63 - ca, 0.0050), line(nebula_f - 0.63, 0.0050), line(nebula_f - 0.63 + ca, 0.0050));
    halo = (line(g2 - 0.52, 0.050) + 0.5 * line(nebula_f - 0.63, 0.040)) * u_web;
    fil = f3.g * u_web;
    tr = lattice(uv, 26.0) * step(1.0 - u_web, hash(floor(uv * 26.0) + 41.0)) * u_web * u_signal;
    emit += wNebula * (u_c3 * f3 * u_web * 0.55 * carry + soft * halo * 0.12 * carry
                     + mixo(u_c2, u_c3, 0.4) * tr * (0.010 + 0.18 * inten));
    dawnFx += wNebula * vec3(fil * 0.28 * (0.1 + 0.9 * carry));
    dawnInk += wNebula * tr * 0.025;
}

vec3 nebulaPearl(vec3 dawn, float amount) {
    vec3 pearl = mixo(0.5 + 0.5 * cos(6.2831 * (g2 * 2.2 + nebula_f * 0.8 + vec3(0.0, 0.33, 0.67))), l2, 0.8);
    return mixo(dawn, pearl, amount);
}

#endif
