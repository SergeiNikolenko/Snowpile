let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Scene { float2 size; float2 origin; float scale; float time; };
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
};

vertex PieceOut pieceVertex(uint id [[vertex_id]], const device Sprite *pieces [[buffer(0)]], constant Scene &scene [[buffer(1)]]) {
    Sprite s = pieces[id];
    float pixels = s.size * scene.scale;
    float extent = max(pixels * (s.lump > 0.0 ? 1.3 : 1.0) * 1.5 + 2.0, 3.0);
    PieceOut out;
    out.position = clipPosition(s.position, scene);
    out.pointSize = extent;
    out.radius = pixels / extent;
    out.alpha = s.alpha * saturate(pixels / 2.0);
    out.soft = s.soft;
    out.lump = s.lump;
    return out;
}

fragment float4 pieceFragment(PieceOut in [[stage_in]], float2 coord [[point_coord]]) {
    float2 p = (coord - 0.5) * 2.0 / max(in.radius, 0.001);
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
    float a = (1.0 - smoothstep(edge, 1.0, r)) * in.alpha;
    // A faint cool halo keeps white flakes readable over white windows; over dark ones it all but vanishes.
    float halo = (1.0 - smoothstep(0.9, 1.45, r)) * (1.0 - a) * in.alpha * 0.3;
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
    int i = clamp(int(floor(t)), 0, drift.count - 1);
    int j = min(i + 1, drift.count - 1);
    float h = mix(columns[i], columns[j], smoothstep(0.0, 1.0, saturate(t - floor(t))));
    float beyond = max(max(-x, x - width), 0.0);
    return h - beyond * 3.0;
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
    float h = depthAt(columns, drift, x);
    if (h < 0.05) discard_fragment();
    float px = 1.0 / scene.scale;
    float inside = saturate((h - y) / px + 0.5) * saturate((y + 1.0) / px + 0.5) * saturate(h / 0.8);
    // Outline just above the snow and a contact shadow under it, so a drift reads on a white title bar.
    float outline = saturate(1.0 - abs(y - h - 0.6) / 0.9) * 0.22 * saturate(h / 1.5);
    float contact = saturate(1.0 - abs(y + 1.6) / 1.4) * 0.3 * saturate(h / 1.5);
    float edgeAlpha = max(outline, contact) * (1.0 - inside);
    if (inside <= 0.0 && edgeAlpha <= 0.003) discard_fragment();
    if (inside <= 0.0) return float4(float3(0.36, 0.42, 0.54) * edgeAlpha, edgeAlpha);

    float dh = depthAt(columns, drift, x + 1.5) - depthAt(columns, drift, x - 1.5);
    float3 normal = normalize(float3(-dh / 3.0, 1.0, 0.6));
    float lit = saturate(dot(normal, normalize(float3(-0.35, 1.0, 0.8))));
    float below = h - y;
    float occlusion = 1.0 - exp(-max(y + 1.0, 0.0) / 3.0);
    float3 snow = float3(0.95, 0.965, 0.985);
    float3 shade = float3(0.70, 0.76, 0.86);
    float3 color = mix(shade, snow, saturate(0.35 + 0.65 * lit) * mix(0.75, 1.0, occlusion));
    color = mix(color, float3(1.0), saturate(1.0 - below / 1.2) * 0.35);
    color *= 1.0 + (hash21(floor(in.position.xy)) - 0.5) * 0.03;
    float2 cell = floor(in.position.xy / 3.0);
    float glint = hash21(cell + 7.0);
    if (glint > 0.985 && below < 4.0) {
        float pulse = pow(saturate(sin(scene.time * (1.0 + glint * 2.0) + glint * 60.0)), 30.0);
        color = mix(color, float3(1.0), pulse);
    }
    return float4(color * inside, inside);
}
"""
