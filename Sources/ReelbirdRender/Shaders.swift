// Metal shader source, compiled at runtime (Command Line Tools have no `metal` compiler).
// Struct layouts mirror `CompositeUniforms` and `SpriteUniforms` in Compositor.swift: float4 fields only,
// so Swift and MSL agree on alignment without padding rules.

let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct CompositeUniforms {
    float4 canvas;      // W, H, viewport origin x, y (px)
    float4 card;        // card rect at zoom 1: x, y, w, h (px)
    float4 camera;      // scale, centre x, centre y, corner radius (px at zoom 1)
    float4 cameraPrev;  // scale, centre x, centre y, motion blur taps (0 = off)
    float4 shadow;      // strength, blur (px), offset y (px), 0
    float4 bg0;
    float4 bg1;
    float4 bg2;
    float4 bg3;
    float4 bgInfo;      // kind (0 solid, 1 gradient, 2 image), stop count, dither, 0
    float4 bgImage;     // aspect-fill: uv scale x, y, offset x, y
    float4 screenInfo;  // source W, H, isYUV, footprint (source px per output px)
    float4 yuv0;        // YCbCr → RGB rows (r, g, b) with offsets in .w
    float4 yuv1;
    float4 yuv2;
    float4 yuvOffset;   // y offset, c offset, y scale, 0
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
    float4 yuvOffset;   // y offset, c offset, isYUV, 0
    float4 camera;      // for screen-sampling modes: scale, cx, cy, 0
    float4 card;        // card rect at zoom 1
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

    float s = u.camera.x;
    float2 c = u.camera.yz;
    float2 cardSize = u.card.zw * s;
    float2 cardOrigin = u.card.xy + u.card.zw * ((float2(0) - c) * s + 0.5);
    float2 cardCentre = cardOrigin + cardSize * 0.5;
    float radius = u.camera.w * s;

    if (u.shadow.x > 0) {
        float blur = max(1.0, u.shadow.y * s);
        float sd = sdRoundRect(p - cardCentre - float2(0, u.shadow.z * s), cardSize * 0.5, radius);
        float a = 1 - smoothstep(-blur, blur, sd);
        col = mix(col, float3(0), a * a * u.shadow.x);
    }

    float sd = sdRoundRect(p - cardCentre, cardSize * 0.5, radius);
    float coverage = saturate(0.5 - sd);
    if (coverage > 0) {
        float2 q = (p - u.card.xy) / u.card.zw;
        float2 uv = (q - 0.5) / s + c;
        float3 sc;
        int taps = int(u.cameraPrev.w);
        if (taps > 1) {
            float2 uvPrev = (q - 0.5) / u.cameraPrev.x + u.cameraPrev.yz;
            float3 acc = float3(0);
            for (int i = 0; i < taps; i++) {
                float k = (float(i) + 0.5) / float(taps);
                acc += sampleScreen(screen0, screen1, lin, mix(uv, uvPrev, k), u).rgb;
            }
            sc = acc / float(taps);
        } else if (u.screenInfo.w / s > 1.3) {
            // Downscaling: 4 rotated-grid taps so text does not shimmer.
            float2 d = u.screenInfo.w / u.screenInfo.xy / s;
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
        // Cursor with a soft drop shadow. params: shadow offset (uv), blur (uv), shadow alpha.
        float4 c = tex0.sample(zero, in.uv);
        float2 o = u.params.xy;
        float b = u.params.z;
        float sh = 0;
        sh += tex0.sample(zero, in.uv - o).a * 0.4;
        sh += tex0.sample(zero, in.uv - o + float2(b, 0)).a * 0.15;
        sh += tex0.sample(zero, in.uv - o - float2(b, 0)).a * 0.15;
        sh += tex0.sample(zero, in.uv - o + float2(0, b)).a * 0.15;
        sh += tex0.sample(zero, in.uv - o - float2(0, b)).a * 0.15;
        sh *= u.params.w;
        float4 r = c + float4(0, 0, 0, sh) * (1 - c.a);
        return r * u.color.a;
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
        // Filled rounded rect with soft edge. params: half size x, y, radius, softness.
        float d = sdRoundRect(centred, u.params.xy, u.params.z);
        float a = u.params.w > 0 ? 1 - smoothstep(-u.params.w, u.params.w, d) : saturate(0.5 - d);
        return u.color * a;
    }
    if (mode == 5) {
        // Camera bubble. params: half size, radius, border width; params2: border rgba (premultiplied).
        float d = sdRoundRect(centred, u.params.xy, u.params.z);
        float a = saturate(0.5 - d);
        if (a <= 0) { return float4(0); }
        float4 c = sampleTex(tex0, tex1, lin, in.uv, u);
        float bw = u.params.w;
        if (bw > 0) {
            float bd = abs(d + bw * 0.5) - bw * 0.5;
            c.rgb = mix(c.rgb, u.params2.rgb, saturate(0.5 - bd) * u.params2.a);
        }
        c.a = 1;
        return c * a;
    }
    if (mode == 6) {
        // Privacy pixelation of the screen inside a rounded rect. params: half size, radius, cell (uv).
        float d = sdRoundRect(centred, u.params.xy, u.params.z);
        float a = saturate(0.5 - d);
        if (a <= 0) { return float4(0); }
        float2 p = u.rect.xy + lp;
        float s = u.camera.x;
        float2 q = (p - u.card.xy) / u.card.zw;
        float2 uv = (q - 0.5) / s + u.camera.yz;
        float2 cell = float2(u.params.w, u.params.w * u.params2.x);
        float2 cuv = (floor(uv / cell) + 0.5) * cell;
        float4 acc = float4(0);
        for (int j = -1; j <= 1; j++) {
            for (int i = -1; i <= 1; i++) {
                acc += sampleTex(tex0, tex1, lin, cuv + float2(i, j) * cell * 0.33, u);
            }
        }
        return float4((acc / 9).rgb, 1) * a;
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
