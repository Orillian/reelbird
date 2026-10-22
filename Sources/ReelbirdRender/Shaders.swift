// Metal shader source, compiled at runtime (Command Line Tools have no `metal` compiler).
// Struct layouts mirror `CompositeUniforms` and `SpriteUniforms` in Compositor.swift: float4 fields only,
// so Swift and MSL agree on alignment without padding rules.

let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct CompositeUniforms {
    float4 canvas;      // W, H, viewport origin x, y (px)
    float4 card;        // visible screen card: x0, y0, x1, y1 (px)
    float4 uvMap;       // source uv = xy + p * zw (p in canvas px)
    float4 uvPrev;      // the same half a frame earlier (motion blur)
    float4 params;      // corner radius (px), motion blur taps (0 = off), source px per output px, 0
    float4 shadow;      // ambient: strength, blur (px), offset y (px), 0
    float4 shadow2;     // contact: strength, blur (px), offset y (px), 0
    float4 bg0;
    float4 bg1;
    float4 bg2;
    float4 bg3;
    float4 bgInfo;      // kind (0 solid, 1 gradient, 2 image), stop count, dither, 0
    float4 bgImage;     // aspect-fill: uv scale x, y, offset x, y
    float4 screenInfo;  // source W, H, isYUV, 0
    float4 yuv0;        // YCbCr → RGB rows (r, g, b) with offsets in .w
    float4 yuv1;
    float4 yuv2;
    float4 yuvOffset;   // y offset, c offset, y scale, 0
    float4 uvClamp;     // screen uv limits (the crop, inset half a texel): min x, min y, max x, max y
};

struct SpriteUniforms {
    float4 rect;        // quad x, y, w, h (px, canvas space)
    float4 canvas;      // W, H, viewport origin x, y
    float4 uvRect;      // u0, v0, u1, v1
    float4 color;       // premultiplied colour / tint
    float4 params;      // mode specific
    float4 params2;     // mode specific
    float4 yuv0;
    float4 yuv1;
    float4 yuv2;
    float4 yuvOffset;   // y offset, c offset, y scale, isYUV
    float4 camera;      // for screen-sampling modes: source uv = xy + p * zw (p in canvas px)
    float4 card;        // privacy blur: cell size (uv)
    int4 mode;
};

struct VOut {
    float4 position [[position]];
    float2 local;   // px inside the quad
    float2 uv;
};

vertex VOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.position = float4(p * float2(2, -2) + float2(-1, 1), 0, 1);
    o.local = p;
    o.uv = p;
    return o;
}

static inline float sdRoundRect(float2 p, float2 halfSize, float r) {
    r = min(r, min(halfSize.x, halfSize.y));
    float2 q = abs(p) - halfSize + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

/// Rounded rect whose corners are superellipse arcs of exponent `n` (n <= 2: circular arcs, an exact SDF).
/// n = 4 gives continuous curvature where a corner meets the straight edge (the "squircle" corner).
static inline float sdRoundRectP(float2 p, float2 halfSize, float r, float n) {
    if (n <= 2.0) { return sdRoundRect(p, halfSize, r); }
    r = min(r, min(halfSize.x, halfSize.y));
    float2 q = abs(p) - halfSize + r;
    float2 m = max(q, 0.0) / max(r, 1e-4);
    float corner = pow(pow(m.x, n) + pow(m.y, n), 1.0 / n) * r;
    return corner + min(max(q.x, q.y), 0.0) - r;
}

static inline float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static inline float3 yuvToRGB(float y, float2 c, float4 r0, float4 r1, float4 r2, float4 off) {
    float3 v = float3((y - off.x) * off.z, c.x - off.y, c.y - off.y);
    return saturate(float3(dot(r0.xyz, v), dot(r1.xyz, v), dot(r2.xyz, v)));
}

static inline float4 sampleScreen(texture2d<float> t0, texture2d<float> t1, sampler s, float2 uv, constant CompositeUniforms& u) {
    uv = clamp(uv, u.uvClamp.xy, u.uvClamp.zw);
    if (u.screenInfo.z > 0.5) {
        float y = t0.sample(s, uv).r;
        float2 c = t1.sample(s, uv).rg;
        return float4(yuvToRGB(y, c, u.yuv0, u.yuv1, u.yuv2, u.yuvOffset), 1);
    }
    return float4(t0.sample(s, uv).rgb, 1);
}

static inline float3 background(float2 p, constant CompositeUniforms& u, texture2d<float> bgTex, sampler s) {
    int kind = int(u.bgInfo.x);
    if (kind == 2) {
        float2 uv = (p / u.canvas.xy - 0.5) * u.bgImage.xy + 0.5 + u.bgImage.zw;
        return bgTex.sample(s, uv).rgb;
    }
    if (kind == 1) {
        int n = int(u.bgInfo.y);
        float t = saturate((p.x / u.canvas.x + p.y / u.canvas.y) * 0.5);
        float3 c;
        if (n <= 2) { c = mix(u.bg0.rgb, u.bg1.rgb, t); }
        else if (n == 3) { c = t < 0.5 ? mix(u.bg0.rgb, u.bg1.rgb, t * 2) : mix(u.bg1.rgb, u.bg2.rgb, t * 2 - 1); }
        else {
            float k = t * 3;
            c = k < 1 ? mix(u.bg0.rgb, u.bg1.rgb, k) : (k < 2 ? mix(u.bg1.rgb, u.bg2.rgb, k - 1) : mix(u.bg2.rgb, u.bg3.rgb, k - 2));
        }
        // Deterministic dither against banding.
        return c + (hash12(p) - 0.5) * u.bgInfo.z;
    }
    return u.bg0.rgb;
}

fragment float4 composite_fragment(VOut in [[stage_in]],
                                   constant CompositeUniforms& u [[buffer(0)]],
                                   texture2d<float> screen0 [[texture(0)]],
                                   texture2d<float> screen1 [[texture(1)]],
                                   texture2d<float> bgTex [[texture(2)]]) {
    constexpr sampler lin(filter::linear, address::clamp_to_edge, mip_filter::linear);
    float2 p = in.position.xy - u.canvas.zw;
    float3 col = background(p, u, bgTex, lin);

    float2 cardCentre = (u.card.xy + u.card.zw) * 0.5;
    float2 cardHalf = max(float2(0), (u.card.zw - u.card.xy) * 0.5);
    float radius = u.params.x;

    // Shadows: a soft ambient one, then a tight contact one. Squared falloff reads as a gaussian.
    if (u.shadow.x > 0) {
        float blur = max(1.0, u.shadow.y);
        float sd = sdRoundRect(p - cardCentre - float2(0, u.shadow.z), cardHalf, radius);
        float a = 1 - smoothstep(-blur, blur, sd);
        col = mix(col, float3(0), a * a * u.shadow.x);
    }
    if (u.shadow2.x > 0) {
        float blur = max(1.0, u.shadow2.y);
        float sd = sdRoundRect(p - cardCentre - float2(0, u.shadow2.z), cardHalf, radius);
        float a = 1 - smoothstep(-blur, blur, sd);
        col = mix(col, float3(0), a * a * u.shadow2.x);
    }

    float sd = sdRoundRect(p - cardCentre, cardHalf, radius);
    float coverage = saturate(0.5 - sd);
    if (coverage > 0) {
        float2 uv = u.uvMap.xy + p * u.uvMap.zw;
        float3 sc;
        int taps = int(u.params.y);
        float footprint = u.params.z;
        if (taps > 1) {
            float2 uvPrev = u.uvPrev.xy + p * u.uvPrev.zw;
            float3 acc = float3(0);
            for (int i = 0; i < taps; i++) {
                float k = (float(i) + 0.5) / float(taps);
                acc += sampleScreen(screen0, screen1, lin, mix(uv, uvPrev, k), u).rgb;
            }
            sc = acc / float(taps);
        } else if (footprint > 1.3) {
            // Downscaling: 4 rotated-grid taps so text does not shimmer.
            float2 d = footprint / u.screenInfo.xy;
            sc = (sampleScreen(screen0, screen1, lin, uv + d * float2(-0.125, -0.375), u).rgb +
                  sampleScreen(screen0, screen1, lin, uv + d * float2(0.375, -0.125), u).rgb +
                  sampleScreen(screen0, screen1, lin, uv + d * float2(0.125, 0.375), u).rgb +
                  sampleScreen(screen0, screen1, lin, uv + d * float2(-0.375, 0.125), u).rgb) * 0.25;
        } else {
            sc = sampleScreen(screen0, screen1, lin, uv, u).rgb;
        }
        col = mix(col, sc, coverage);
    }
    return float4(col, 1);
}

// Catmull-Rom bicubic from 9 bilinear taps (mip 0): crisp when a cursor bitmap is drawn larger than it is.
static inline float4 sampleCatmullRom(texture2d<float> tex, sampler s, float2 uv, float2 texSize) {
    float2 pos = uv * texSize;
    float2 p1 = floor(pos - 0.5) + 0.5;
    float2 f = pos - p1;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 t0 = (p1 - 1) / texSize, t3 = (p1 + 2) / texSize, t12 = (p1 + w2 / w12) / texSize;
    float4 r = float4(0);
    r += tex.sample(s, float2(t0.x, t0.y), level(0)) * w0.x * w0.y;
    r += tex.sample(s, float2(t12.x, t0.y), level(0)) * w12.x * w0.y;
    r += tex.sample(s, float2(t3.x, t0.y), level(0)) * w3.x * w0.y;
    r += tex.sample(s, float2(t0.x, t12.y), level(0)) * w0.x * w12.y;
    r += tex.sample(s, float2(t12.x, t12.y), level(0)) * w12.x * w12.y;
    r += tex.sample(s, float2(t3.x, t12.y), level(0)) * w3.x * w12.y;
    r += tex.sample(s, float2(t0.x, t3.y), level(0)) * w0.x * w3.y;
    r += tex.sample(s, float2(t12.x, t3.y), level(0)) * w12.x * w3.y;
    r += tex.sample(s, float2(t3.x, t3.y), level(0)) * w3.x * w3.y;
    r = saturate(r);
    r.rgb = min(r.rgb, r.aaa);
    return r;
}

vertex VOut sprite_vertex(uint vid [[vertex_id]], constant SpriteUniforms& u [[buffer(0)]]) {
    float2 corner = float2(vid & 1, (vid >> 1) & 1);
    float2 px = u.rect.xy + corner * u.rect.zw;
    VOut o;
    o.position = float4(px / u.canvas.xy * float2(2, -2) + float2(-1, 1), 0, 1);
    o.local = corner * u.rect.zw;
    o.uv = mix(u.uvRect.xy, u.uvRect.zw, corner);
    return o;
}

static inline float4 sampleTex(texture2d<float> t0, texture2d<float> t1, sampler s, float2 uv, constant SpriteUniforms& u) {
    if (u.yuvOffset.w > 0.5) {
        float y = t0.sample(s, uv).r;
        float2 c = t1.sample(s, uv).rg;
        return float4(yuvToRGB(y, c, u.yuv0, u.yuv1, u.yuv2, u.yuvOffset), 1);
    }
    return t0.sample(s, uv);
}

/// Mean colour of the screen cell starting at `origin` (uv), from n × n bilinear taps spread over it, clamped to
/// the visible screen (`u.params2`).
static inline float3 cellMean(texture2d<float> t0, texture2d<float> t1, sampler s, float2 origin, float2 cell, int n,
                              constant SpriteUniforms& u) {
    float3 acc = float3(0);
    for (int j = 0; j < n; j++) {
        for (int i = 0; i < n; i++) {
            float2 uv = origin + (float2(i, j) + 0.5) / float(n) * cell;
            acc += sampleTex(t0, t1, s, clamp(uv, u.params2.xy, u.params2.zw), u).rgb;
        }
    }
    return acc / float(n * n);
}

fragment float4 sprite_fragment(VOut in [[stage_in]],
                                constant SpriteUniforms& u [[buffer(0)]],
                                texture2d<float> tex0 [[texture(0)]],
                                texture2d<float> tex1 [[texture(1)]]) {
    constexpr sampler lin(filter::linear, address::clamp_to_edge, mip_filter::linear);
    int mode = u.mode.x;
    float2 size = u.rect.zw;
    float2 lp = in.local;
    float2 centred = lp - size * 0.5;

    constexpr sampler zero(filter::linear, address::clamp_to_zero, mip_filter::linear);
    if (mode == 0) {
        // Premultiplied texture × opacity.
        return tex0.sample(zero, in.uv) * u.color.a;
    }
    if (mode == 1) {
        // Cursor with a soft drop shadow and motion blur.
        // params: shadow offset (uv), blur (uv), shadow alpha. params2: trail (uv), taps, 1 = magnifying.
        float2 o = u.params.xy;
        float b = u.params.z;
        int taps = max(1, int(u.params2.z));
        bool cubic = u.params2.w > 0.5;
        float2 texSize = float2(tex0.get_width(), tex0.get_height());
        float4 acc = float4(0);
        for (int i = 0; i < taps; i++) {
            float k = taps > 1 ? float(i) / float(taps - 1) : 0.0;
            float2 uv = in.uv + u.params2.xy * k;
            float4 c = cubic ? sampleCatmullRom(tex0, zero, uv, texSize) : tex0.sample(zero, uv);
            float sh = 0;
            sh += tex0.sample(zero, uv - o).a * 0.4;
            sh += tex0.sample(zero, uv - o + float2(b, 0)).a * 0.15;
            sh += tex0.sample(zero, uv - o - float2(b, 0)).a * 0.15;
            sh += tex0.sample(zero, uv - o + float2(0, b)).a * 0.15;
            sh += tex0.sample(zero, uv - o - float2(0, b)).a * 0.15;
            sh *= u.params.w;
            acc += c + float4(0, 0, 0, sh) * (1 - c.a);
        }
        return acc / float(taps) * u.color.a;
    }
    if (mode == 9) {
        // Click ripple: a faint disc, a crisp white ring, a thin dark outline so it reads on light and dark
        // screens. params: radius, ring width, ring alpha, disc alpha; params2.x: outline alpha.
        float d = length(centred);
        float r = u.params.x, th = u.params.y;
        float disc = (1 - smoothstep(r - 1.0, r + 0.5, d)) * u.params.w;
        float ring = (1 - smoothstep(th * 0.5 - 0.6, th * 0.5 + 0.6, abs(d - (r - th * 0.5)))) * u.params.z;
        float line = (1 - smoothstep(0.35, 1.1, abs(d - r - 0.6))) * u.params2.x;
        float w = max(ring, disc);
        return float4(w, w, w, w) + float4(0, 0, 0, line) * (1 - w);
    }
    if (mode == 2) {
        // Ring. params: radius, thickness (px), softness.
        float d = abs(length(centred) - u.params.x) - u.params.y * 0.5;
        float a = 1 - smoothstep(-u.params.z, u.params.z, d);
        return u.color * a;
    }
    if (mode == 3) {
        // Rounded rect stroke. params: half size x, y, radius, stroke width.
        float d = abs(sdRoundRect(centred, u.params.xy, u.params.z)) - u.params.w * 0.5;
        return u.color * saturate(0.5 - d);
    }
    if (mode == 4) {
        // Filled rounded rect with soft edge. params: half size x, y, radius, softness; mode.y: corner exponent.
        float d = sdRoundRectP(centred, u.params.xy, u.params.z, float(u.mode.y));
        float a = u.params.w > 0 ? 1 - smoothstep(-u.params.w, u.params.w, d) : saturate(0.5 - d);
        return u.color * a;
    }
    if (mode == 5) {
        // Camera bubble. params: half size, radius, border width; params2: border rgba (premultiplied);
        // mode.y: corner exponent (2 = circular corners, 4 = continuous "squircle" corners); color.a: opacity.
        float d = sdRoundRectP(centred, u.params.xy, u.params.z, float(u.mode.y));
        float a = saturate(0.5 - d);
        if (a <= 0) { return float4(0); }
        float4 c = sampleTex(tex0, tex1, lin, in.uv, u);
        float bw = u.params.w;
        if (bw > 0) {
            float bd = abs(d + bw * 0.5) - bw * 0.5;
            c.rgb = mix(c.rgb, u.params2.rgb, saturate(0.5 - bd) * u.params2.a);
        }
        c.a = 1;
        return c * (a * u.color.a);
    }
    if (mode == 6 || mode == 10 || mode == 12) {
        // Privacy blur of the screen inside a rounded rect. Cells are anchored to the screen texture, so they hold
        // still through zoom and pan, and each cell is reduced to one average colour: nothing under it survives.
        // 6 = pixelate (flat cells); 10 = blur (a quadratic B-spline through the 3 × 3 nearest cell averages).
        // 12 = a solid bar in u.color. params: half size, corner radius (-1 = an oval), soft edge (px, outside
        // the area only); card.xy: cell size (uv); params2: uv clamp (the crop).
        float d;
        if (u.params.z < 0) {
            float2 h = max(u.params.xy, float2(1e-3));
            d = (length(centred / h) - 1.0) * min(h.x, h.y);
        } else {
            d = sdRoundRect(centred, u.params.xy, u.params.z);
        }
        float feather = u.params.w;
        float a = feather > 0.5 ? 1.0 - smoothstep(0.0, feather, d) : saturate(0.5 - d);
        if (a <= 0) { return float4(0); }
        if (mode == 12) { return u.color * a; }
        float2 p = u.rect.xy + lp;
        float2 uv = u.camera.xy + p * u.camera.zw;
        float2 cell = max(u.card.xy, float2(1e-5));
        float3 col;
        if (mode == 6) {
            col = cellMean(tex0, tex1, lin, floor(uv / cell) * cell, cell, 4, u);
        } else {
            float2 g = uv / cell - 0.5;
            float2 i0 = floor(g + 0.5);
            float2 f = g - i0;
            float2 w0 = 0.5 * (0.5 - f) * (0.5 - f), w1 = 0.75 - f * f, w2 = 0.5 * (0.5 + f) * (0.5 + f);
            float wx[3] = { w0.x, w1.x, w2.x };
            float wy[3] = { w0.y, w1.y, w2.y };
            col = float3(0);
            for (int j = 0; j < 3; j++) {
                for (int i = 0; i < 3; i++) {
                    float2 ci = i0 + float2(i - 1, j - 1);
                    col += cellMean(tex0, tex1, lin, ci * cell, cell, 3, u) * (wx[i] * wy[j]);
                }
            }
            // A little grain keeps large smooth areas from banding.
            col += (hash12(p) - 0.5) * (1.5 / 255.0);
        }
        return float4(saturate(col), 1) * a * u.color.a;
    }
    if (mode == 7) {
        // Arrow from params.xy to params.zw (quad-local px). params2: thickness, head length.
        float2 a = u.params.xy, b = u.params.zw;
        float th = u.params2.x, head = u.params2.y;
        float2 dir = normalize(b - a + 1e-5);
        float2 nrm = float2(-dir.y, dir.x);
        float2 shaftEnd = b - dir * head * 0.8;
        float2 pa = lp - a, ba = shaftEnd - a;
        float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-5));
        float dLine = length(pa - ba * h) - th * 0.5;
        // Head: triangle b, b - dir*head ± nrm*head*0.6
        float2 rel = lp - b;
        float along = -dot(rel, dir);
        float across = abs(dot(rel, nrm));
        float dHead = max(across - along * 0.6, max(-along, along - head));
        float dd = min(dLine, dHead);
        return u.color * saturate(0.5 - dd);
    }
    if (mode == 8) {
        // Spotlight: dim everything outside a rounded rect. params: rect centre x, y (quad px), half w, h; params2: radius, feather.
        float d = sdRoundRect(lp - u.params.xy, u.params.zw, u.params2.x);
        float a = smoothstep(-u.params2.y, u.params2.y, d);
        return u.color * a;
    }
    return float4(0);
}
"""#
