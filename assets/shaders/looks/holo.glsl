// holo.glsl -- Holo (u_look 3): iridescent foil, the spectrum clipped to
// three columns between darker flanks, luminous mid-height. Its effect is
// thin-film interference -- contour fringes from a smooth thickness field,
// hue rotating across each fringe like an oil slick -- and technicolor
// mis-registration, each channel reading the column ramp a little apart.
// The muddy version of this look died of desaturation, so it keeps most of
// its chroma. Its luminescence: thin-film fringes and a diffraction sheen,
// coloured by wavelength, and one faint hologram scan band.
//
// The brand half is pulsar.frag's, the theme half theme.frag's; both are the
// code that sat in those files' main(), moved here unchanged.

float holo_fring, holo_hx;

#ifdef BRAND

// the column ramp: indigo | rose | periwinkle | teal | indigo. Split out so
// the technicolor pass can sample it three times at offset positions.
vec3 holoRamp(float hx) {
    vec3 c = INDIGO;
    c = pmix(c, ROSE,   smoothstep(-0.38, -0.16, hx));
    c = pmix(c, PERI,   smoothstep(-0.04,  0.12, hx));
    c = pmix(c, TEAL,   smoothstep( 0.16,  0.30, hx));
    c = pmix(c, INDIGO, smoothstep( 0.34,  0.52, hx));
    return c;
}

vec3 holoNight() {
    float nx = gl_FragCoord.x / u_resolution.x - 0.5;
    float ab = 0.030;
    float film = vnoise(uv * 2.4 + 3.0) + 0.5 * vnoise(uv * 4.8 + 7.0);
    holo_fring = 0.5 + 0.5 * sin(film * 22.0);                  // interference fringes
    float sheen = 0.5 + 0.5 * sin(nx * 9.0 + sin(uv.y * 1.8) * 0.7);
    // fringes SHIMMER the columns, they must not replace them -- the 0.10
    // version of this hue shift turned the whole frame into an oil slick
    holo_hx = nx * 1.25 + 0.06 * sin(uv.y * 2.2 + 1.0)
            + (holo_fring - 0.5) * 0.035 + uv.y * 0.08;
    vec3 holo = vec3(holoRamp(holo_hx + ab).r, holoRamp(holo_hx).g, holoRamp(holo_hx - ab).b);
    float env = smoothstep(0.62, 0.10, abs(uv.y)) * 0.62 + 0.10;
    holo *= env * (0.72 + 0.28 * sheen) * (0.92 + 0.11 * holo_fring);
    holo = mix(holo, vec3(dot(holo, vec3(0.33))), 0.04);   // nearly full chroma
    holo += STAR * starsNight * 0.20 * smoothstep(0.40, 0.62, abs(uv.y));
    holo *= 1.0 - 0.30 * smoothstep(0.65, 1.15, r);
    return holo;
}

// dawn: the foil ramp pushed to pastel over the pale ground
vec3 holoDawn() {
    float ab = 0.030;
    vec3 dawnH = mix(dawnBase,
                     mix(vec3(holoRamp(holo_hx + ab).r, holoRamp(holo_hx).g, holoRamp(holo_hx - ab).b),
                         vec3(1.0), 0.38),
                     smoothstep(0.62, 0.10, abs(uv.y)) * 0.78 + 0.16);
    dawnH *= 0.94 + 0.06 * holo_fring;
    return dawnH;
}

void holoGlow(float wHolo) {
    g2 = fbm3(uv * 1.9 + 2.3);
    float thick = g2 * 2.4 + uv.x * 0.35 + 0.15 * sin(uv.y * 3.1);
    vec3 film = 0.5 + 0.5 * cos(6.2831 * (thick + vec3(0.0, 0.33, 0.67)));
    float gd = dot(uv, normalize(vec2(0.8, 0.45)));
    vec3 grating = (0.5 + 0.5 * cos(6.2831 * (gd * 3.0 + vec3(0.0, 0.33, 0.67))))
                 * gauss((gd - 0.05) / 0.22);
    float scanBand = glowLine(uv.y - 0.14, 0.035);
    emit += wHolo * (mix(film, CYAN, 0.45) * inten * 0.12 + grating * inten * 0.08
                     + PERI * scanBand * (0.02 + 0.08 * inten));
    dawnFx += wHolo * (film * 0.06 + grating * 0.05 + vec3(scanBand * 0.04));
}

#else

vec3 holoRamp(float hx) {
    vec3 flank = u_c1 * 0.32;
    vec3 c = flank;
    c = mixo(c, u_c4, smoothstep(-0.38, -0.16, hx));
    c = mixo(c, u_c2, smoothstep(-0.04,  0.12, hx));
    c = mixo(c, u_c3, smoothstep( 0.16,  0.30, hx));
    c = mixo(c, flank, smoothstep( 0.34,  0.52, hx));
    return c;
}

vec3 holoNight() {
    float nx = gl_FragCoord.x / u_resolution.x - 0.5;
    float film = vnoise(uv * 2.4 + 3.0 + u_seed) + 0.5 * vnoise(uv * 4.8 + 7.0);
    holo_fring = 0.5 + 0.5 * sin(film * 22.0);
    float sheen = 0.5 + 0.5 * sin(nx * 9.0 + sin(uv.y * 1.8) * 0.7);
    holo_hx = nx * 1.25 + 0.06 * sin(uv.y * 2.2 + 1.0) + (holo_fring - 0.5) * 0.035 + uv.y * 0.08;
    float ab = 0.030;
    vec3 holo = vec3(holoRamp(holo_hx + ab).r, holoRamp(holo_hx).g, holoRamp(holo_hx - ab).b);
    float env = smoothstep(0.62, 0.10, abs(uv.y)) * 0.62 + 0.10;
    holo *= env * (0.72 + 0.28 * sheen) * (0.92 + 0.11 * holo_fring) * u_gain;
    holo = max(holo, u_ga);
    holo += u_star * starsNight * 0.20 * smoothstep(0.40, 0.62, abs(uv.y)) * u_stars;
    holo *= 1.0 - 0.30 * smoothstep(0.65, 1.15, r);
    return holo;
}

vec3 holoDawn() {
    float ab = 0.030;
    vec3 hr = vec3(holoRamp(holo_hx + ab).r, holoRamp(holo_hx).g, holoRamp(holo_hx - ab).b);
    vec3 dawnH = mixo(dawnBase, mixo(hr, vec3(1.0), u_wash * 0.8),
                      (smoothstep(0.62, 0.10, abs(uv.y)) * 0.78 + 0.16) * u_gain);
    dawnH *= 0.94 + 0.06 * holo_fring;
    return dawnH;
}

void holoGlow(float wHolo) {
    g2 = fbm(uv * 1.9 + u_seed * 0.51 + 2.3);
    // thin film: hue follows optical thickness, fringes drift across it
    float thick = g2 * 2.4 + uv.x * 0.35 + 0.15 * sin(uv.y * 3.1);
    vec3 film = 0.5 + 0.5 * cos(6.2831 * (thick + vec3(0.0, 0.33, 0.67)));
    // grating: a broad diagonal band whose colour runs with angle
    float gd = dot(uv, normalize(vec2(0.8, 0.45)));
    vec3 grating = (0.5 + 0.5 * cos(6.2831 * (gd * 3.0 + vec3(0.0, 0.33, 0.67))))
                 * gauss((gd - 0.05) / 0.22);
    float scanBand = line(uv.y - 0.14, 0.035) * u_signal;
    emit += wHolo * u_web * (mixo(film, u_c3, 0.45) * inten * 0.12 + grating * inten * 0.08
                             + soft * scanBand * (0.02 + 0.08 * inten));
    dawnFx += wHolo * u_web * (film * 0.06 + grating * 0.05 + vec3(scanBand * 0.04));
}

#endif
