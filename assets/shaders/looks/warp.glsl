// warp.glsl -- Warp: starlight stretched toward a vanishing point, at rest.
// NOT SHIPPED: the alternative for slot 7 (see freshLook in shared.glsl and
// looks.json). Same contract as beacon().
// The moment after a jump: every star drawn out into a soft streak along
// the line to a vanishing point on the lit side, streaks in log-radius so
// they grow toward the edges, each blue at its head and warm at its tail
// (the channels land a little apart along the streak), a quiet glow at the
// point they all fall toward. Live, the streaks creep outward, very slowly.
float warpLayer(float a, float la, float rr, float sectors, float seed, float t, float shift, out float headness) {
    float ai = a / 6.2831853 * sectors + seed * 13.0;
    float id = floor(ai);
    float fa = fract(ai) - 0.5;
    headness = 0.0;
    float h = hash(vec2(id, 1.3 + seed));
    if (h < 0.74) return 0.0;                                   // most sectors hold none
    float c = mix(-2.6, 0.5, hash(vec2(id, 7.1 + seed)));
    c = mod(c + t * 0.02 + 2.6, 3.1) - 2.6;                     // live: creep outward
    float len = 0.12 + 0.55 * hash(vec2(id, 3.3 + seed));
    float sAl = (la - c + shift) / len;                          // 0 tail .. 1 head
    float body = smoothstep(0.0, 0.35, sAl) * smoothstep(1.02, 0.85, sAl);
    float px = abs(fa) * (6.2831853 / sectors) * rr * u_resolution.y;
    float wpx = 0.55 + rr * 1.1;
    headness = smoothstep(0.5, 1.0, sAl);
    return exp(-(px * px) / (wpx * wpx)) * body * (0.35 + 0.65 * hash(vec2(id, 5.5 + seed)));
}
vec3 warp(vec2 uv, vec3 dawnBase, float starsNight, out vec3 emitN, out vec3 dawnN, out float lit) {
    float t = u_time * u_live;
    vec2 L = normalize(u_dir);
    vec2 vp = L * 0.34 + vec2(0.08, 0.06) + u_seed * 0.01;
    vec2 d = uv - vp;
    float rr = length(d);
    float a = atan(d.y, d.x);
    float la = log(rr + 1e-3);
    vec3 col = vec3(0.0);
    float hd;
    // two layers of sectors, each with the channels a touch apart along the
    // streak: the head leans to the highlight, the tail to the deep colour
    float ab = 0.035;
    vec3 s1 = vec3(warpLayer(a, la, rr, 260.0, 0.0, t,  ab, hd), warpLayer(a, la, rr, 260.0, 0.0, t, 0.0, hd),
                   warpLayer(a, la, rr, 260.0, 0.0, t, -ab, hd));
    float head1 = hd;
    vec3 s2 = vec3(warpLayer(a, la, rr, 170.0, 1.0, t,  ab, hd), warpLayer(a, la, rr, 170.0, 1.0, t, 0.0, hd),
                   warpLayer(a, la, rr, 170.0, 1.0, t, -ab, hd));
    float head2 = hd;
    vec3 tint1 = mixo(mixo(u_c1, u_c2, 0.6), mixo(u_c3, u_star, 0.45), head1);
    vec3 tint2 = mixo(mixo(u_c1, u_c2, 0.6), mixo(u_c3, u_star, 0.45), head2);
    vec3 streaks = s1 * tint1 * 0.60 + s2 * tint2 * 0.42;
    // none crowding the point itself
    streaks *= smoothstep(0.03, 0.22, rr);
    float glow = exp(-rr / 0.22);
    float haze = exp(-rr * 1.6);
    col += streaks;
    col += mixo(u_c2, u_c3, 0.5) * glow * 0.22 + mixo(u_c1, u_c2, 0.3) * haze * 0.14;
    col += mixo(u_c3, u_star, 0.6) * exp(-rr / 0.015) * 0.6;
    col += u_star * starsNight * 0.25 * u_stars * (1.0 - glow);
    emitN = mixo(u_c3, u_star, 0.4) * dot(s1 + s2, vec3(0.333)) * (head1 + head2) * 0.10 + u_c3 * glow * 0.06;
    lit = clamp(dot(streaks, vec3(0.333)) * 2.0 + glow * 0.5, 0.0, 1.0);
    // the light cut, only when light shows (dark never reads it)
    dawnN = vec3(0.0);
    if (wantDawn) {
        vec3 pale = mixo(u_c2, vec3(1.0), 0.50 + 0.40 * u_wash);
        dawnN = mixo(dawnBase, pale, clamp(glow * 0.45 + haze * 0.15, 0.0, 0.8));
        dawnN = mixo(dawnN, mixo(u_c1, u_c2, 0.5) * 0.85, clamp(dot(streaks, vec3(0.333)) * 1.4, 0.0, 0.5));
    }
    return grey(col, u_desat) * u_gain;
}
