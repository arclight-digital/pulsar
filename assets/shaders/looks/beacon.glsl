// beacon.glsl -- Beacon (u_look 7): a pulsar's beams sweeping through dust --
// Pulsar's own image. A small bright core, two opposed beams seen only where
// there is dust for them to light, prismatic fringes at their edges, an
// afterglow on the trailing side of the sweep. Live, the sweep turns very
// slowly.
// Pulsar's own image: a small bright core, two opposed beams, and the beams
// seen only where there is dust for them to light -- the light is the subject,
// the dust the stage. Prismatic fringes at the beam edges, an afterglow on the
// trailing side of the sweep, faint stars. Live, the sweep turns very slowly.
vec3 beacon(vec2 uv, vec3 dawnBase, float starsNight, out vec3 emitN, out vec3 dawnN, out float lit) {
    float t = u_time * u_live;
    vec2 L = normalize(u_dir);
    vec2 core = L * 0.38 + vec2(0.10, 0.04) + u_seed * 0.01;
    vec2 d = uv - core;
    float rr = length(d);
    float ang = atan(d.y, d.x);
    float sweep = 0.62 + t * 0.010;                          // the beam's angle
    // angular distance to the nearer of the two opposed beams, signed
    float a = mod(ang - sweep + 3.14159 * 0.5, 3.14159) - 3.14159 * 0.5;
    // dust: a warped, lane-y density the beams light up
    vec2 dp = uv * 1.8 + u_seed * 0.2 + vec2(t * 0.003, 0.0);
    float dust = fbm3n(dp + 1.7 * vec2(fbm3n(dp * 0.7 + 3.1), fbm3n(dp * 0.7 + 8.3)));
    dust = smoothstep(0.25, 0.85, dust);
    float width = 0.07 + 0.16 * rr;                         // beams widen with distance
    float fall = exp(-rr * 0.85);
    // afterglow on the trailing side (the sweep turns counter-clockwise)
    float trail = exp(-max(-a, 0.0) / (width * 5.0)) * step(a, 0.0);
    float ab = 0.012;
    vec3 beam = vec3(gauss((a + ab) / width), gauss(a / width), gauss((a - ab) / width));
    vec3 light = beam * fall * (0.10 + 1.6 * dust) + vec3(trail * fall * dust * 0.30);
    vec3 col = light.r * mixo(u_c2, u_c3, 0.3) * vec3(1.0, 0.0, 0.0)
             + light.g * mixo(u_c2, u_c3, 0.3) * vec3(0.0, 1.0, 0.0)
             + light.b * mixo(u_c2, u_c3, 0.3) * vec3(0.0, 0.0, 1.0);
    col *= 0.62;
    // the dust's own faint glow and its dark lanes, in the deep colour
    col += mixo(u_c1, u_c2, 0.3) * dust * exp(-rr * 0.8) * 0.13;
    // the core: a tight point with a soft halo
    float halo = exp(-rr / 0.16);
    col += mixo(u_c3, u_star, 0.5) * (exp(-rr / 0.012) * 0.9 + halo * 0.25);
    col += u_star * starsNight * 0.40 * (1.0 - dust * 0.8) * u_stars;
    emitN = u_c3 * (gauss(a / (width * 0.35)) * fall * dust * 0.14 + halo * 0.10);
    lit = clamp(dot(light, vec3(0.333)) + halo, 0.0, 1.0);
    vec3 pale = mixo(u_c2, vec3(1.0), 0.50 + 0.40 * u_wash);
    dawnN = mixo(dawnBase, pale, clamp(dot(light, vec3(0.333)) * 0.9 + halo * 0.6, 0.0, 0.85));
    dawnN = mixo(dawnN, mixo(u_c1, u_c2, 0.5) * 0.9, dust * (1.0 - dot(light, vec3(0.333))) * 0.10);
    // the beams themselves in colour on the paper
    dawnN = mixo(dawnN, mixo(u_c2, u_c3, 0.5), clamp(dot(light, vec3(0.333)) * 1.1 + halo * 0.45, 0.0, 0.7));
    return grey(col, u_desat) * u_gain;
}
