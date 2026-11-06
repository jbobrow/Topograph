// The terrain, ported from `renderTerrain` in viewer/app.js. The viewer fills and
// strokes contour polygons; here each pixel asks the elevation field directly, so
// the lines stay smooth at any zoom and only the grid has to be uploaded once.

#include <metal_stdlib>
using namespace metal;

// Keep in step with `Uniforms` in TerrainRenderer.swift.
struct Uniforms {
    float4 ground;
    float4 ink;
    float4 hair;
    float2 drawable;   // pixels
    float2 translate;  // points
    float scale;       // pixels per point
    float k;           // points per map unit
    float origin;      // map units the field extends past the map
    float cell;        // map units per field cell
    float markerZoom;
};

struct TerrainVarying {
    float4 position [[position]];
};

vertex TerrainVarying terrainVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    return { float4(p * 2 - 1, 0, 1) };
}

struct Elevation {
    float value;
    float2 slope;  // per field cell
};

// A cubic B-spline over the grid: smooth contours when one cell is many pixels
// wide, and a true slope for the line widths.
static Elevation sampleField(texture2d<float, access::read> field, float2 c) {
    int2 size = int2(field.get_width(), field.get_height());
    if (any(c < -2.0) || c.x > size.x + 1.0 || c.y > size.y + 1.0) {
        return { 0, float2(0) };
    }
    float2 whole = floor(c), t = c - whole, t2 = t * t, t3 = t2 * t, r = 1 - t;
    float2 w[4] = { r * r * r / 6, (3 * t3 - 6 * t2 + 4) / 6, (-3 * t3 + 3 * t2 + 3 * t + 1) / 6, t3 / 6 };
    float2 d[4] = { -r * r / 2, 1.5 * t2 - 2 * t, -1.5 * t2 + t + 0.5, t2 / 2 };

    Elevation e = { 0, float2(0) };
    int2 base = int2(whole);
    for (int j = 0; j < 4; j++) {
        for (int i = 0; i < 4; i++) {
            int2 at = clamp(base + int2(i - 1, j - 1), int2(0), size - 1);
            float v = field.read(uint2(at)).r;
            e.value += w[i].x * w[j].y * v;
            e.slope += float2(d[i].x * w[j].y, w[i].x * d[j].y) * v;
        }
    }
    return e;
}

fragment float4 terrainFragment(TerrainVarying in [[stage_in]],
                                constant Uniforms &u [[buffer(0)]],
                                constant float *thresholds [[buffer(1)]],
                                constant float *dither [[buffer(2)]],
                                constant float *bayer [[buffer(3)]],
                                constant uint &levels [[buffer(4)]],
                                texture2d<float, access::read> field [[texture(0)]]) {
    float2 point = in.position.xy / u.scale;
    float3 color = u.ground.rgb;

    // Instrument grid, fixed to the screen: one point every 24.
    float2 grid = fmod(point, 24.0);
    if (all(grid >= 12.0) && all(grid < 13.0)) color = u.hair.rgb;

    float2 map = (point - u.translate) / u.k;
    Elevation e = sampleField(field, (map + u.origin) / u.cell - 0.5);

    // Elevation as dither density, in whole points so the dots stay crisp at any zoom.
    int band = -1;
    for (uint i = 0; i < levels; i++) {
        if (e.value >= thresholds[i]) band = i;
    }
    if (band >= 0) {
        uint2 dot = uint2(point) % 8;
        if (bayer[dot.y * 8 + dot.x] < dither[band] * 64) color = u.ink.rgb;
    }

    // Contour lines. Dividing by the slope turns a difference in elevation into a
    // distance in pixels. Every fourth line is an index contour.
    float slope = max(length(e.slope) / (u.cell * u.k * u.scale), 1e-7);
    for (uint i = 0; i < levels; i++) {
        bool index = i % 4 == 3;
        float half_width = (index ? 1.1 : 0.5) * u.scale / 2;
        float distance = abs(e.value - thresholds[i]) / slope;
        float coverage = saturate(half_width + 0.5 - distance);
        color = mix(color, u.ink.rgb, coverage * (index ? 0.9 : 0.45));
    }
    return float4(color, 1);
}

// Markers: squares for what you made or posted, circles for what you kept.

struct Marker {
    float2 position;
    float base;
    float mine;
};

struct MarkerVarying {
    float4 position [[position]];
    float2 offset;  // pixels from the center
    float radius;   // pixels
    float mine;
};

vertex MarkerVarying markerVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                  constant Uniforms &u [[buffer(0)]],
                                  constant Marker *markers [[buffer(1)]]) {
    Marker m = markers[iid];
    float radius = m.base * sqrt(min(u.k, u.markerZoom)) * u.scale;
    float reach = radius + 1.0 * u.scale + 1.0;
    float2 corner = float2(vid & 1, (vid >> 1) & 1) * 2 - 1;
    float2 center = (m.position * u.k + u.translate) * u.scale;
    float2 pixel = center + corner * reach;
    float2 clip = pixel / u.drawable * 2 - 1;
    return { float4(clip.x, -clip.y, 0, 1), corner * reach, radius, m.mine };
}

fragment float4 markerFragment(MarkerVarying in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float d = in.mine > 0.5 ? max(abs(in.offset.x), abs(in.offset.y)) : length(in.offset);
    float fill = saturate(in.radius - d + 0.5);
    // A thin outline in the ground color keeps overlapping markers apart.
    float outline = saturate(0.4 * u.scale + 0.5 - abs(d - in.radius));
    float3 rgb = mix(u.ink.rgb * fill, u.ground.rgb, outline);
    float alpha = mix(fill, 1.0, outline);
    return float4(rgb, alpha);
}
