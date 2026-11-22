let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Scene { float2 size; float2 origin; float scale; float time; int occluders; int _pad; };
struct Sprite { float2 position; float2 velocity; float size; float alpha; float soft; float lump; };
struct Drift { float2 origin; float columnWidth; int count; float height; int occluders; };

static float4 clipPosition(float2 world, constant Scene &scene) {
    return float4((world - scene.origin) / scene.size * 2.0 - 1.0, 0.0, 1.0);
}

static float hash21(float2 p) {
    float3 q = fract(float3(p.xyx) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

// MARK: Flakes and lumps

struct PieceOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float radius;     // disc radius as a share of the point
    float alpha;
    float soft;
    float lump;
    float2 trail;
};

vertex PieceOut pieceVertex(uint id [[vertex_id]], const device Sprite *pieces [[buffer(0)]], constant Scene &scene [[buffer(1)]]) {
    Sprite s = pieces[id];
    float pixels = s.size * scene.scale;
    float speed = length(s.velocity);
    float travel = min(speed * 0.014, s.size * 1.8);
    float2 direction = speed > 0.01 ? s.velocity / speed : float2(0.0);
    float extent = max((s.size * (s.lump > 0.0 ? 1.3 : 1.0) * 1.5 + travel) * scene.scale + 2.0, 3.0);
    PieceOut out;
    out.position = clipPosition(s.position - direction * travel * 0.5, scene);
    out.trail = float2(direction.x, -direction.y) * travel * scene.scale / extent;
    out.pointSize = extent;
    out.radius = pixels / extent;
    out.alpha = s.alpha * saturate(pixels / 2.0);
    out.soft = s.soft;
    out.lump = s.lump;
    return out;
}

fragment float4 pieceFragment(PieceOut in [[stage_in]], float2 coord [[point_coord]],
                             constant Scene &scene [[buffer(0)]], const device float4 *occluders [[buffer(1)]]) {
    float occluderFade = 1.0;
    if (scene.occluders > 0) {
        float2 world = float2(scene.origin.x + in.position.x / scene.scale,
                              scene.origin.y + scene.size.y - in.position.y / scene.scale);
        for (int k = 0; k < scene.occluders; k++) {
            float4 o = occluders[k];
            float2 d = max(o.xy - world, world - o.zw);
            float dist = max(d.x, d.y);
            if (dist <= 0.0) discard_fragment();
            if (dist < 5.0) occluderFade = min(occluderFade, smoothstep(0.0, 5.0, dist));
        }
    }
    float2 centered = coord - 0.5;
    float along = clamp(dot(centered, in.trail) / max(dot(in.trail, in.trail), 0.00001), -0.5, 0.5);
    float2 p = (centered - in.trail * along) * 2.0 / max(in.radius, 0.001);
    float r = length(p);
    float rim = 0.0;
    if (in.lump > 0.0) {
        float sector = (atan2(p.y, p.x) + M_PI_F) / (2.0 * M_PI_F) * 7.0;
        float a = hash21(float2(floor(sector), in.lump * 91.0));
        float b = hash21(float2(floor(sector) + 1.0, in.lump * 91.0));
        r /= 0.82 + 0.3 * mix(a, b, smoothstep(0.0, 1.0, fract(sector)));
        rim = saturate(dot(p, float2(0.5, 0.7)));
    }
    float edge = mix(0.75, 0.15, in.soft);
    float a = (1.0 - smoothstep(edge, 1.0, r)) * in.alpha * occluderFade;
    // A faint cool halo keeps white flakes readable over white windows; over dark ones it all but vanishes.
    float halo = (1.0 - smoothstep(0.9, 1.45, r)) * (1.0 - a) * in.alpha * occluderFade * 0.3;
    if (a + halo < 0.003) discard_fragment();
    float3 snow = float3(0.97, 0.98, 1.0);
    float3 shadow = float3(0.66, 0.72, 0.82);
    float3 color = mix(snow, shadow, saturate(r * r * 0.45 + rim * 0.4));
    float3 haloColor = float3(0.36, 0.42, 0.54);
    return float4(color * a + haloColor * halo, a + halo);
}

// MARK: Drifts

struct DriftOut {
    float4 position [[position]];
    float2 local;
};

vertex DriftOut driftVertex(uint id [[vertex_id]], constant Scene &scene [[buffer(0)]], constant Drift &drift [[buffer(1)]]) {
    float width = float(drift.count) * drift.columnWidth;
    float2 corner = float2(float(id & 1), float(id >> 1));
    float2 local = float2(mix(-1.0, width + 1.0, corner.x), mix(-3.0, drift.height + 2.0, corner.y));
    DriftOut out;
    out.position = clipPosition(drift.origin + local, scene);
    out.local = local;
    return out;
}

static float depthAt(const device float *columns, constant Drift &drift, float x) {
    float width = float(drift.count) * drift.columnWidth;
    float t = clamp(x, 0.0, width) / drift.columnWidth - 0.5;
    int i1 = clamp(int(floor(t)), 0, drift.count - 1);
    int i0 = max(i1 - 1, 0);
    int i2 = min(i1 + 1, drift.count - 1);
    int i3 = min(i1 + 2, drift.count - 1);
    float f = saturate(t - floor(t));
    float f2 = f * f;
    float f3 = f2 * f;
    float c0 = columns[i0], c1 = columns[i1], c2 = columns[i2], c3 = columns[i3];
    float h = 0.5 * ((2.0 * c1) + (-c0 + c2) * f + (2.0 * c0 - 5.0 * c1 + 4.0 * c2 - c3) * f2 + (-c0 + 3.0 * c1 - 3.0 * c2 + c3) * f3);
    h = clamp(h, 0.0, max(max(c1, c2), 0.0) * 1.06);
    // Smooth pillowed roll-off at open drift ends instead of a vertical cliff.
    float beyond = max(max(-x, x - width), 0.0);
    if (beyond > 0.0) {
        float drop = beyond * beyond * 0.9 + beyond * 1.1;
        h = max(0.0, h - drop);
    }
    return h;
}

fragment float4 driftFragment(DriftOut in [[stage_in]], constant Scene &scene [[buffer(0)]], constant Drift &drift [[buffer(1)]],
                              const device float *columns [[buffer(2)]], const device float4 *occluders [[buffer(3)]]) {
    float2 world = drift.origin + in.local;
    for (int k = 0; k < drift.occluders; k++) {
        float4 o = occluders[k];
        if (all(world >= o.xy) && all(world < o.zw)) discard_fragment();
    }
    float x = in.local.x;
    float y = in.local.y;
    float rawH = depthAt(columns, drift, x);
    if (rawH < 0.05) discard_fragment();
    // Subtle natural snow-pillow micro-contour along the crest.
    float micro = (sin(world.x * 0.23) * 0.5 + sin(world.x * 0.59 + 1.7) * 0.35 + sin(world.x * 1.27) * 0.15) * 0.35 * saturate(rawH / 4.5);
    float h = max(0.0, rawH + micro);
    float px = 1.0 / scene.scale;
    // Gently rounded snow belly hugs the surface edge cleanly without hard pixel steps.
    float baseSoft = saturate((y + 0.85) / (px * 1.15) + 0.5);
    float topSoft = saturate((h - y) / (px * 1.2) + 0.5);
    float inside = topSoft * baseSoft * saturate(h / 0.7);
    // Outline just above the snow and a contact shadow under it, so a drift reads on a white title bar.
    float outline = saturate(1.0 - abs(y - h - 0.55) / 0.95) * 0.20 * saturate(h / 1.4);
    float contact = saturate(1.0 - abs(y + 1.45) / 1.5) * 0.32 * saturate(h / 1.2);
    float edgeAlpha = max(outline, contact) * (1.0 - inside);
    if (inside <= 0.0 && edgeAlpha <= 0.003) discard_fragment();
    if (inside <= 0.0) return float4(float3(0.30, 0.37, 0.50) * edgeAlpha, edgeAlpha);

    float dh = depthAt(columns, drift, x + 2.0) - depthAt(columns, drift, x - 2.0);
    float3 normal = normalize(float3(-dh / 4.0, 1.0, 0.65));
    float lit = saturate(dot(normal, normalize(float3(-0.38, 1.0, 0.78))));
    float below = h - y;
    float relY = saturate(y / max(h, 0.5));
    float occlusion = 1.0 - exp(-max(y + 0.9, 0.0) / 3.6);
    float3 snow = float3(0.97, 0.982, 0.996);
    float3 shade = float3(0.72, 0.79, 0.90);
    float3 deepShade = float3(0.62, 0.70, 0.84);
    float3 baseTint = mix(deepShade, shade, saturate(0.35 + 0.65 * relY));
    float3 color = mix(baseTint, snow, saturate(0.30 + 0.70 * lit) * mix(0.72, 1.0, occlusion));
    // Translucent sunlit snow crest rim.
    float crest = saturate(1.0 - below / 1.8);
    color = mix(color, float3(1.0), crest * crest * 0.42);
    color *= 1.0 + (hash21(floor(in.position.xy)) - 0.5) * 0.028;
    float2 cell = floor(in.position.xy / 3.0);
    float glint = hash21(cell + 7.0);
    if (glint > 0.985 && below < 4.0) {
        float pulse = pow(saturate(sin(scene.time * (1.0 + glint * 2.0) + glint * 60.0)), 30.0);
        color = mix(color, float3(1.0), pulse);
    }
    return float4(color * inside, inside);
}
// MARK: Snowmen

struct Part { float2 position; float size; float kind; float angle; float seed; };

struct PartOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float radius;
    float kind;
    float angle;
    float seed;
};

vertex PartOut partVertex(uint id [[vertex_id]], const device Part *parts [[buffer(0)]], constant Scene &scene [[buffer(1)]]) {
    Part s = parts[id];
    float pixels = s.size * scene.scale;
    float extent = pixels * 1.2 + 2.0;
    PartOut out;
    out.position = clipPosition(s.position, scene);
    out.pointSize = extent;
    out.radius = pixels / extent;
    out.kind = s.kind;
    out.angle = s.angle;
    out.seed = s.seed;
    return out;
}

fragment float4 partFragment(PartOut in [[stage_in]], float2 coord [[point_coord]]) {
    float2 p = (coord - 0.5) * 2.0 / max(in.radius, 0.001);
    p.y = -p.y;
    float r = length(p);
    float3 color;
    float a;
    if (in.kind < 0.5) {
        // A packed snowball: slightly lumpy, lit from the upper left, with a cool halo for white backgrounds.
        float angle = atan2(p.y, p.x);
        r /= 1.0 + 0.025 * sin(angle * 7.0 + in.seed * 40.0) + 0.015 * sin(angle * 13.0 + in.seed * 17.0);
        a = 1.0 - smoothstep(0.95, 1.0, r);
        float3 n = float3(p, sqrt(saturate(1.0 - r * r)));
        float lit = saturate(dot(n, normalize(float3(-0.45, 0.6, 0.65))));
        color = mix(float3(0.64, 0.71, 0.83), float3(0.97, 0.98, 1.0), 0.2 + 0.8 * lit);
        color *= 1.0 + (hash21(floor(coord * 40.0) + in.seed) - 0.5) * 0.04;
        float halo = (1.0 - smoothstep(1.0, 1.15, r)) * (1.0 - a) * 0.3;
        if (a + halo < 0.003) discard_fragment();
        return float4(color * a + float3(0.36, 0.42, 0.54) * halo, a + halo);
    } else if (in.kind < 1.5) {
        a = 1.0 - smoothstep(0.85, 1.0, r);
        color = mix(float3(0.10, 0.10, 0.11), float3(0.35, 0.35, 0.38), saturate(dot(p, float2(-0.5, 0.6))) * 0.6);
    } else if (in.kind < 2.5) {
        // A carrot: a cone from its root at x = -1 to the tip at x = 1, turned to face `angle`.
        float c = cos(-in.angle), s = sin(-in.angle);
        float2 q = float2(c * p.x - s * p.y, s * p.x + c * p.y);
        float half_ = 0.28 * (1.0 - q.x) * 0.5;
        float inside = step(-1.0, q.x) * step(q.x, 1.0) * step(abs(q.y), half_);
        a = inside;
        color = mix(float3(0.98, 0.55, 0.16), float3(0.80, 0.33, 0.08), saturate(q.y / max(half_, 0.001) * 0.5 + 0.5));
    } else if (in.kind < 3.5) {
        a = 1.0 - smoothstep(0.8, 1.0, r);
        color = float3(0.33, 0.22, 0.13);
    } else {
        // A fir tree: three tiers over a short trunk, each tier with snow lying along its top.
        a = 0.0;
        color = float3(0.36, 0.24, 0.14);
        if (abs(p.x) < 0.09 && p.y > -1.0 && p.y < -0.7) a = 1.0;
        for (int t = 0; t < 3; t++) {
            float low = -0.78 + float(t) * 0.42;
            float top = low + 0.72 - float(t) * 0.06;
            float half_ = (0.78 - float(t) * 0.17) * (top - p.y) / (top - low);
            float jag = 0.04 * sin(p.y * 40.0 + in.seed * 20.0);
            if (p.y >= low && p.y <= top && abs(p.x) < half_ + jag) {
                float along = (p.y - low) / (top - low);
                float edge = half_ - abs(p.x);
                bool snowy = along > 0.62 || (edge < 0.07 && along > 0.15) || (p.y - low < 0.06 && hash21(floor(p * 18.0) + in.seed) > 0.4);
                float lit = 0.75 + 0.25 * sign(-p.x);
                color = snowy ? float3(0.95, 0.97, 1.0) * (0.9 + 0.1 * lit) : float3(0.11, 0.30, 0.19) * lit;
                a = 1.0;
            }
        }
    }
    if (a < 0.003) discard_fragment();
    return float4(color * a, a);
}

// MARK: Weather effects

struct EffectSprite { float2 position; float2 size; float4 color; float4 parameters; };
struct EffectOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float4 parameters;
};

vertex EffectOut effectVertex(uint vertexID [[vertex_id]], uint instance [[instance_id]],
                              const device EffectSprite *sprites [[buffer(0)]], constant Scene &scene [[buffer(1)]]) {
    const float2 corners[6] = {float2(-1,-1), float2(1,-1), float2(-1,1), float2(-1,1), float2(1,-1), float2(1,1)};
    EffectSprite sprite = sprites[instance];
    float2 uv = corners[vertexID];
    float2 local = uv * sprite.size * 0.5;
    float c = cos(sprite.parameters.y), s = sin(sprite.parameters.y);
    float2 rotated = float2(c * local.x - s * local.y, s * local.x + c * local.y);
    EffectOut out;
    out.position = clipPosition(sprite.position + rotated, scene);
    out.uv = uv;
    out.color = sprite.color;
    out.parameters = sprite.parameters;
    return out;
}

fragment float4 effectFragment(EffectOut in [[stage_in]]) {
    float2 p = in.uv;
    float alpha = 0.0;
    float3 color = in.color.rgb;
    int kind = int(in.parameters.x + 0.5);
    if (kind == 0) {
        alpha = (1.0 - smoothstep(0.2, 1.0, abs(p.y))) * (0.3 + 0.7 * (p.x * 0.5 + 0.5));
    } else if (kind == 1) {
        // A notched petal with a soft central fold.
        float width = 0.62 * sqrt(saturate(1.0 - p.x * p.x)) * (1.0 + 0.3 * p.x);
        float edge = abs(p.y) - width;
        float notch = length(p - float2(0.9, 0.0));
        alpha = (1.0 - smoothstep(-0.08, 0.02, edge)) * smoothstep(0.12, 0.2, notch);
        color *= 0.76 + 0.24 * (1.0 - abs(p.y));
        color = mix(color, float3(1.0, 0.9, 0.95), exp(-abs(p.y) * 15.0) * 0.35);
    } else if (kind == 2) {
        // Lobed outline, central stem and branching veins.
        float theta = atan2(p.y, p.x);
        float lobes = 0.66 + 0.22 * cos(theta * 5.0 + in.parameters.z);
        float r = length(float2(p.x * 0.88, p.y));
        alpha = 1.0 - smoothstep(lobes - 0.05, lobes, r);
        float stem = (1.0 - smoothstep(0.025, 0.06, abs(p.y))) * step(-1.0, p.x) * step(p.x, 0.2);
        alpha = max(alpha, stem);
        float veins = exp(-abs(p.y) * 35.0) + exp(-abs(fract((p.x + abs(p.y)) * 3.0) - 0.5) * 35.0) * 0.35;
        color *= 0.65 + 0.35 * (1.0 - r);
        color = mix(color, float3(0.32, 0.18, 0.05), saturate(veins) * 0.4);
    } else if (kind == 3) {
        float r = length(p);
        alpha = exp(-r * r * 5.0) * 0.6 + exp(-r * r * 80.0) * 0.4;
        alpha *= 1.0 - smoothstep(0.8, 1.0, r);
        color = mix(color, float3(1.0, 1.0, 0.8), exp(-r * r * 50.0));
    } else if (kind == 4) {
        float head = p.x * 0.5 + 0.5;
        alpha = pow(head, 1.8) * exp(-p.y * p.y * 5.0);
        color = mix(color, float3(1.0), head * head);
    } else if (kind == 5) {
        alpha = 1.0 - smoothstep(0.3, 1.0, length(p));
    } else if (kind == 6) {
        alpha = exp(-p.y * p.y * 6.0);
    } else {
        alpha = (1.0 - smoothstep(0.3, 1.0, abs(p.y))) * 0.8;
    }
    alpha *= in.color.a;
    if (alpha < 0.002) discard_fragment();
    return float4(color * alpha, alpha);
}
"""
