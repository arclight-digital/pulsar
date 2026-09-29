// shared.glsl -- what the looks added since the first four share: a few
// helpers, the night every one of them sits on, their glow pass, the quiet
// corner, and the dispatch from u_look to a look. Written against
// theme.frag's contract (u_c1.. u_ga.. mixo, grey); pulsar.frag maps its brand
// palette onto the same names. First in looks/looks.json, so everything after
// it can use it.

float fbm3n(vec2 p) {
    float a = 0.5, s = 0.0;
    for (int i = 0; i < 3; i++) { s += a * vnoise(p); p = p * 2.03 + 11.7; a *= 0.5; }
    return s / 0.875;
}
float lineGlow(float d, float w) { return exp(-(d * d) / (w * w)); }
// the side the light mass comes from (u_dir), 1 there and 0 at the far corner
float litSideN(vec2 p) { return smoothstep(1.05, -0.55, dot(p, normalize(-u_dir))); }

// the looks, defined in the files after this one
vec3 satin(vec2 uv, vec3 dawnBase, out vec3 emitN, out vec3 dawnN, out float lit);
vec3 relief(vec2 uv, vec3 dawnBase, out vec3 emitN, out vec3 dawnN, out float lit);
vec3 tide(vec2 uv, vec3 dawnBase, out vec3 emitN, out vec3 dawnN, out float lit);
vec3 orbit(vec2 uv, vec3 dawnBase, float starsNight, out vec3 emitN, out vec3 dawnN, out float lit);
vec3 beacon(vec2 uv, vec3 dawnBase, float starsNight, out vec3 emitN, out vec3 dawnN, out float lit);

// Each look its own sky: the first looks' two star layers at a seed of the
// look's own, so no two looks show the same stars. Twinkles live.
float lookStars(float look) {
    vec2 s = uv + u_seed + vec2(look * 37.1, look * 11.9);
    return starLayer(s, 110.0, 0.030, 600.0, u_live) + starLayer(s, 28.0, 0.050, 260.0, u_live);
}

// u_look -> a look's light (added to the ground by freshNight), its light-mode
// cut and its luminescence. Slot 7 is Beacon; looks/warp.glsl draws the same
// contract, so Warp in its place is this one line plus its file in looks.json.
vec3 freshLook(float look, out vec3 dawnN, out vec3 emitN) {
    float lit;
    float stars = lookStars(floor(look + 0.5));
    // the sky places its own stars; the rest get theirs in the dark between
    // their light (fainter on the cloth, where they are dust in the weave)
    if (look > 5.5) {
        if (look < 6.5) return orbit(uv, dawnBase, stars, emitN, dawnN, lit);
        return beacon(uv, dawnBase, stars, emitN, dawnN, lit);
    }
    vec3 lightc;
    float amount = 0.40;
    if (look < 2.5) { lightc = satin(uv, dawnBase, emitN, dawnN, lit); amount = 0.22; }
    else if (look < 4.5) lightc = relief(uv, dawnBase, emitN, dawnN, lit);
    else lightc = tide(uv, dawnBase, emitN, dawnN, lit);
    return lightc + u_star * stars * amount * u_stars * clamp(1.0 - dot(lightc, vec3(0.3333)) * 5.0, 0.0, 1.0);
}

// the night under a look: the theme's ground, lit from its side, the look's
// light on top, a vignette and half the family's downlight
vec3 freshNight(vec3 lightc) {
    vec3 night = mix(u_ga, u_gb, litSideN(uv)) + lightc;
    night *= 1.0 - 0.38 * smoothstep(0.55, 1.10, r);
    night += u_c2 * u_down * 0.5 * pow(smoothstep(-0.25, 0.62, uv.y), 1.6);
    return night;
}

// the family's luminescence response: the lit core glows gently, the look's
// own effect on top, never brighter than the highlight colour, then the
// soft knee. calm < 1 quiets it (pulsar.frag's live sky).
vec3 freshGlow(vec3 night, vec3 emitN, float calm) {
    inten = clamp(dot(night - mix(u_ga, u_gb, 0.5), vec3(0.3333)) * 2.6, 0.0, 1.0);
    vec3 e = u_c3 * pow(inten, 3.0) * 0.16 + emitN;
    e = min(e, u_c3 * 0.85 + 0.03);
    return knee(night + e * u_glow * calm);
}

// ---- the quiet corner ----
// Quick settings, notifications and the calendar all open from the top
// edge, mostly top-right, and sit over the wallpaper as translucent-feeling
// cards. A bright fold or beam there fights them, so every look is calmed
// toward its own ground in that corner and, more gently, along the bar.
void quietCorner(inout vec3 night, inout vec3 dawn) {
    float aspect = u_resolution.x / u_resolution.y;
    vec2 qc = (uv - vec2(0.5 * aspect, 0.5)) * vec2(0.8, 1.2);
    float quiet = exp(-dot(qc, qc) * 2.2) * u_quiet;
    float bar = smoothstep(0.30, 0.50, uv.y) * 0.35 * u_quiet;
    night = mix(night, u_ga, clamp(quiet * 0.85 + bar, 0.0, 1.0));
    dawn = mixo(dawn, mix(u_da, u_db, 0.5), clamp(quiet * 0.75 + bar * 0.7, 0.0, 1.0));
}
