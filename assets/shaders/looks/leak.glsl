// leak.glsl -- Leak (u_look 1), THE CLEAN ONE: buttery smooth beams,
// deliberately no texture objects at all (a bokeh cut of this read as a
// Windows screensaver and died for it). Its signature is photographic
// instead: prismatic dispersion splits each beam edge into color fringes, and
// film halation bleeds the brightest beam softly into the dark side. Its
// luminescence is volumetric light: god-rays through the leak, drifting
// motes, an anamorphic streak with a little dispersion at the beam edge.
//
// The brand half is pulsar.frag's, the theme half theme.frag's; both are the
// code that sat in those files' main(), moved here unchanged.

// one beam with prismatic dispersion: the R/G/B channels land at slightly
// offset heights, so the beam's edges split into color fringes
vec3 beamRGB(float y, float c, float w, float o) {
    return vec3(gauss((y - c + o) / w),
                gauss((y - c) / w),
                gauss((y - c - o) / w));
}

vec2 leak_q;        // the frame turned to the beams' angle
float leak_fade;    // beams fade out toward the upper right

#ifdef BRAND

vec3 leakNight() {
    float lA = -0.35;
    vec2 lq = vec2(cos(lA) * uv.x + sin(lA) * uv.y,
                   -sin(lA) * uv.x + cos(lA) * uv.y);
    float lfade = smoothstep(0.85, -0.35, lq.x);
    leak_q = lq;
    leak_fade = lfade;
    vec3 leak = pal() ? mix(u_p_ga, u_p_gb * 0.85, lfade)
                      : mix(vec3(0.006, 0.007, 0.018), vec3(0.014, 0.016, 0.040), lfade);
    leak += VIOLET * beamRGB(lq.y, 0.36, 0.20, 0.050) * lfade * 0.55;
    leak += PERI   * beamRGB(lq.y, 0.05, 0.26, 0.055) * lfade * 0.45;
    leak += CYAN   * beamRGB(lq.y, -0.28, 0.14, 0.040)
          * smoothstep(0.50, -0.45, lq.x) * 0.50;
    // halation: an extra-wide faint copy of the cyan beam glowing outward
    leak += CYAN * gauss((lq.y + 0.28) / 0.42)
          * smoothstep(0.50, -0.45, lq.x) * 0.10;
    leak = mix(leak, vec3(dot(leak, vec3(0.33))), 0.15);
    leak += STAR * starsNight * (1.0 - lfade * 0.7) * 0.45;
    leak *= 1.0 - 0.35 * smoothstep(0.60, 1.10, r);
    return leak;
}

// dawn: the same beams as washes of pastel; dispersion would be invisible at
// this key, so the light cut trades it for pure color
vec3 leakDawn() {
    vec2 lq = leak_q;
    float lfade = leak_fade;
    vec3 dawnL = dawnBase;
    float dV = gauss((lq.y - 0.36) / 0.20) * lfade;
    float dP = gauss((lq.y - 0.05) / 0.26) * lfade;
    float dC = gauss((lq.y + 0.28) / 0.14) * smoothstep(0.50, -0.45, lq.x);
    dawnL = mix(dawnL, vec3(0.700, 0.650, 0.930), dV * 0.75);
    dawnL = mix(dawnL, vec3(0.700, 0.760, 0.970), dP * 0.68);
    dawnL = mix(dawnL, vec3(0.590, 0.840, 0.975), dC * 0.75);
    return dawnL;
}

void leakGlow(float wLeak) {
    vec2 lq = leak_q;
    vec2 rel = lq - vec2(-1.25, -0.05);
    float ang = atan(rel.y, rel.x);
    float rays = vnoise(vec2(ang * 34.0, 1.7)) * 0.65 + vnoise(vec2(ang * 91.0, 4.2)) * 0.35;
    rays = smoothstep(0.35, 0.95, rays) * smoothstep(2.3, 0.4, length(rel));
    float motes = starLayer(uv, 46.0, 0.035, 140.0, 0.0) + starLayer(uv + 7.3, 19.0, 0.03, 60.0, 0.0);
    float edge = -0.14;
    vec3 streak = vec3(glowLine(lq.y - edge - 0.0035, 0.010), glowLine(lq.y - edge, 0.010),
                       glowLine(lq.y - edge + 0.0035, 0.010)) * smoothstep(0.55, -0.6, lq.x);
    emit += wLeak * (PERI * rays * inten * 0.06 + CYAN * motes * inten * 0.28 + CYAN * streak * 0.10);
    dawnFx += wLeak * vec3(rays * 0.05 + streak.g * 0.08);
    dawnInk -= wLeak * motes * 0.06;
}

#else

vec3 leakNight() {
    float lA = u_beam;
    vec2 lq = vec2(cos(lA) * uv.x + sin(lA) * uv.y, -sin(lA) * uv.x + cos(lA) * uv.y);
    float lfade = smoothstep(0.85, -0.35, lq.x);
    leak_q = lq;
    leak_fade = lfade;
    vec3 leak = mix(u_ga, u_gb, lfade);
    leak += u_c1 * beamRGB(lq.y, 0.36, 0.20, 0.050) * lfade * 0.30 * u_gain;  // brand 0.55: violet is dim, theme c1 is not
    leak += u_c2 * beamRGB(lq.y, 0.05, 0.26, 0.055) * lfade * 0.45 * u_gain;
    leak += u_c3 * beamRGB(lq.y, -0.28, 0.14, 0.040) * smoothstep(0.50, -0.45, lq.x) * 0.50 * u_gain;
    leak += u_c3 * gauss((lq.y + 0.28) / 0.42) * smoothstep(0.50, -0.45, lq.x) * 0.10 * u_gain;
    leak = grey(leak, u_desat * 0.8);
    leak += u_star * starsNight * (1.0 - lfade * 0.7) * 0.45 * u_stars;
    leak *= 1.0 - 0.35 * smoothstep(0.60, 1.10, r);
    return leak;
}

vec3 leakDawn() {
    vec2 lq = leak_q;
    float lfade = leak_fade;
    vec3 dawnL = dawnBase;
    float dV = gauss((lq.y - 0.36) / 0.20) * lfade;
    float dP = gauss((lq.y - 0.05) / 0.26) * lfade;
    float dC = gauss((lq.y + 0.28) / 0.14) * smoothstep(0.50, -0.45, lq.x);
    dawnL = mixo(dawnL, l1, dV * 0.45 * u_gain);
    dawnL = mixo(dawnL, l2, dP * 0.68 * u_gain);
    dawnL = mixo(dawnL, l3, dC * 0.75 * u_gain);
    return dawnL;
}

void leakGlow(float wLeak) {
    vec2 lq = leak_q;
    // rays fan out from a source beyond the left edge, along the beams
    vec2 rel = lq - vec2(-1.25, -0.05);
    float ang = atan(rel.y, rel.x);
    float rays = vnoise(vec2(ang * 34.0, 1.7)) * 0.65 + vnoise(vec2(ang * 91.0, 4.2)) * 0.35;
    rays = smoothstep(0.35, 0.95, rays) * smoothstep(2.3, 0.4, length(rel));
    float motes = starLayer(uv + u_seed, 46.0, 0.035, 140.0, 0.0) + starLayer(uv - u_seed, 19.0, 0.03, 60.0, 0.0);
    float edge = -0.28 + 0.14;              // the upper edge of the brightest beam
    float disp = 0.0035 * u_signal;
    vec3 streak = vec3(line(lq.y - edge - disp, 0.010), line(lq.y - edge, 0.010), line(lq.y - edge + disp, 0.010))
                * smoothstep(0.55, -0.6, lq.x);
    emit += wLeak * u_web * (soft * rays * inten * 0.09 + u_c3 * motes * inten * 0.28
                             + u_c3 * streak * 0.10);
    dawnFx += wLeak * u_web * vec3(rays * 0.05 + streak.g * 0.08);
    dawnInk -= wLeak * u_web * motes * 0.06;      // motes on paper: pale specks catching light
}

#endif
