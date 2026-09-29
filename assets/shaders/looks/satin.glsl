// satin.glsl -- Satin (u_look 2): a satin sheet, piled up. The brushed-metal
// cut this replaced read as 2009; this one is cloth. The sheet is three
// layers of creases (ridged noise, warped into each other); its crests are
// |x| with the tiniest rounding -- sharp enough to read as fabric folding
// over, never a single-pixel knife edge for the sheen to alias on. It is lit
// like cloth: Kajiya-Kay anisotropic sheen, the highlight stretched ALONG the
// threads, which follow the creases, through knee() so nothing clips to
// white. Its luminescence is the sheen's own soft glow. Live, the creases
// shift, slowly. The light cut is pale silk: folds as soft shade, sheen as
// white.

float satinAxis = 1.0;   // how well defined the thread axis is at this pixel

float satinSheet(vec2 p, float t) {
    // broad creases: fewer, bigger folds, the finest layer only a whisper
    vec2 q = p * 1.8 + u_seed * 0.1;
    float w = fbm3n(q * 0.5 + t) * 2.0;
    float na = 2.0 * vnoise(q * 1.3 + w) - 1.0;
    float nb = 2.0 * vnoise(q * 2.3 + w * 1.3 + 5.0) - 1.0;
    float nc = 2.0 * vnoise(q * 3.9 + w * 1.6 + 11.0) - 1.0;
    float a = 1.0 - sqrt(na * na + 0.0025);
    float b = 1.0 - sqrt(nb * nb + 0.0025);
    float c = 1.0 - sqrt(nc * nc + 0.0025);
    return a * 0.58 + b * 0.27 + c * 0.05 + fbm3n(q * 0.4) * 0.6;
}

vec3 satin(vec2 uv, vec3 dawnBase, out vec3 emitN, out vec3 dawnN, out float lit) {
    float t = u_time * 0.015 * u_live;
    float e = 2.0 / u_resolution.y;
    float h  = satinSheet(uv, t);
    float hx = satinSheet(uv + vec2(e, 0.0), t);
    float hy = satinSheet(uv + vec2(0.0, e), t);
    float amp = 0.016;
    vec3 n = normalize(vec3(-(hx - h) / e * amp, -(hy - h) / e * amp, 1.0));
    // The threads follow the creases (that is the look), from the sheet's
    // slope over a wider step, and settle to the weave where the cloth is
    // flat. The blend is on the thread's AXIS, in double-angle form: T and -T
    // shade alike, so blending directions made a hard seam wherever the
    // blended direction flipped. Double-angle is continuous.
    float E = 0.035;
    vec2 G = vec2(satinSheet(uv + vec2(E, 0.0), t) - satinSheet(uv - vec2(E, 0.0), t),
                  satinSheet(uv + vec2(0.0, E), t) - satinSheet(uv - vec2(0.0, E), t));
    vec2 weave = normalize(vec2(1.0, 0.35));
    float wgt = smoothstep(0.03, 0.16, length(G));
    vec2 pu = length(G) > 1e-6 ? normalize(vec2(-G.y, G.x)) : weave;
    vec2 m = mix(vec2(weave.x * weave.x - weave.y * weave.y, 2.0 * weave.x * weave.y),
                 vec2(pu.x * pu.x - pu.y * pu.y, 2.0 * pu.x * pu.y), wgt);
    float a2 = 0.5 * atan(m.y, m.x + 1e-6);
    satinAxis = length(m);
    vec2 along = vec2(cos(a2), sin(a2));
    vec3 T = normalize(vec3(along, 0.0) - n * dot(n, vec3(along, 0.0)));
    vec2 Ld = normalize(u_dir);
    vec3 L = normalize(vec3(-Ld * 0.9, 0.55));
    vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));
    float tl = dot(T, L), th = dot(T, H);
    float diff = sqrt(max(1.0 - tl * tl, 0.0));
    float sheen = pow(sqrt(max(1.0 - th * th, 0.0)), 48.0);
    // where the axis is ill-defined (the blend cancels) the anisotropic sheen
    // would swing into a star: hand over to a plain isotropic one there
    float iso = pow(max(dot(n, H), 0.0), 140.0) * 1.3;
    sheen = mix(iso, sheen, smoothstep(0.08, 0.55, satinAxis));
    float lamb = max(dot(n, L), 0.0);
    // the creases between the folds sink a little deeper into shade
    float occl = smoothstep(-0.4, 1.0, h);
    float fall = smoothstep(1.15, -0.45, dot(uv, -Ld));
    float base = (0.08 + 0.60 * lamb * diff) * occl * fall;
    vec3 cloth = mixo(u_c1, u_c2, smoothstep(0.1, 0.7, base * 1.6)) * base;
    float sAmt = 0.30 * occl * fall;
    vec3 shine = mixo(u_c2, u_c3, 0.7) * sheen * sAmt;
    vec3 col = cloth * 0.9 + shine;
    // a second wash of colour across the cloth from the far side, in the
    // theme's contrast colour, catching the folds as the main light does
    vec2 w2 = -Ld * 0.55 + vec2(0.10, -0.05);
    float wash2 = gauss(length(uv - w2) / 0.85);
    vec3 c2nd = mixo(u_c4, u_c3, 0.25);
    col += c2nd * wash2 * (0.05 + 0.34 * occl * (0.3 + 0.7 * lamb * diff));
    // the weave's own grain, fixed to the pixel: satin reads as cloth, not
    // plastic, when the light has a little texture in it
    float weave2 = hashS(floor(gl_FragCoord.xy) + 17.3) - 0.5;
    col *= 1.0 + weave2 * 0.28;
    emitN = u_c3 * pow(sqrt(max(1.0 - th * th, 0.0)), 48.0 * 0.35) * sAmt * 0.10;
    lit = clamp(base * 1.4 + sheen * sAmt, 0.0, 1.0);
    vec3 paleCloth = mixo(dawnBase, mixo(u_c2, vec3(1.0), 0.6 + 0.3 * u_wash), 0.35 * fall);
    // folds in soft shade of the theme's own colour, the sheen as white
    dawnN = mixo(paleCloth, mixo(u_c1, u_c2, 0.5), (1.0 - occl * (0.35 + 0.65 * lamb * diff)) * 0.30 * fall);
    dawnN = mixo(dawnN, vec3(1.0), sheen * sAmt * 1.6);
    dawnN = mixo(dawnN, mixo(c2nd, vec3(1.0), 0.45), wash2 * 0.22);
    dawnN *= 1.0 + weave2 * 0.06;
    return grey(col, u_desat) * u_gain;
}
