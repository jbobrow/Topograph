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
    float4 surface;
    float2 drawable;   // pixels
    float2 translate;  // points
    float scale;       // pixels per point
    float k;           // points per map unit
    float origin;      // map units the field extends past the map
    float cell;        // map units per field cell
    float dotRadius;   // points; when above 0, every marker is a plain dot this size
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
    float radius = (u.dotRadius > 0 ? u.dotRadius : m.base * sqrt(u.k)) * u.scale;
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
    float outline = u.dotRadius > 0 ? 0 : saturate(0.4 * u.scale + 0.5 - abs(d - in.radius));
    float3 rgb = mix(u.ink.rgb * fill, u.ground.rgb, outline);
    float alpha = mix(fill, 1.0, outline);
    return float4(rgb, alpha);
}

// Thumbnails. Each is drawn on its own, with a frame: heavy for what you made, fine
// for what you kept.

struct Thumb {
    float2 center;  // pixels
    float2 half_size;
    float frame;
    float mine;
    float mode;     // 0 color, 1 gray or 1-bit (both follow the theme's ramp)
    float has_image;
    float nearest;
    float depth;    // Metal's depth, for 3D; 0 on the flat map
};

struct ThumbVarying {
    float4 position [[position]];
    float2 local;   // pixels from the center
};

vertex ThumbVarying thumbVertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]],
                                constant Thumb &t [[buffer(1)]]) {
    float2 corner = float2(vid & 1, (vid >> 1) & 1) * 2 - 1;
    float2 local = corner * (t.half_size + t.frame);
    float2 clip = (t.center + local) / u.drawable * 2 - 1;
    return { float4(clip.x, -clip.y, t.depth, 1), local };
}

fragment float4 thumbFragment(ThumbVarying in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                              constant Thumb &t [[buffer(1)]], texture2d<float> image [[texture(0)]]) {
    constexpr sampler smooth(filter::linear, mip_filter::linear, address::clamp_to_edge);
    constexpr sampler blocky(filter::nearest, address::clamp_to_edge);

    if (any(abs(in.local) > t.half_size)) {
        if (t.mine > 0.5) return u.ink;
        // A fine line at the outer edge, then a sliver of surface.
        float2 outer = t.half_size + t.frame - abs(in.local);
        return min(outer.x, outer.y) < 0.75 * u.scale ? u.ink : u.surface;
    }
    if (t.has_image < 0.5) {
        // Not ready yet: a hatched card rather than a blank one.
        float line = fmod(in.local.x + in.local.y + 4096.0, 6.0 * u.scale);
        return line < u.scale ? u.hair : u.surface;
    }
    float2 uv = in.local / t.half_size * 0.5 + 0.5;
    float4 c = t.nearest > 0.5 ? image.sample(blocky, uv) : image.sample(smooth, uv);
    if (t.mode < 0.5) return float4(c.rgb, 1);
    // Luminance onto the theme's own dark-to-light ramp, so pictures stay positive in dark mode.
    float lum = dot(c.rgb, float3(0.2126, 0.7152, 0.0722));
    bool inkIsDark = dot(u.ink.rgb, float3(1)) < dot(u.surface.rgb, float3(1));
    float3 lo = inkIsDark ? u.ink.rgb : u.surface.rgb, hi = inkIsDark ? u.surface.rgb : u.ink.rgb;
    return float4(mix(lo, hi, lum), 1);
}

// Plain rectangles in pixels, for the selection's viewfinder.

struct Bar {
    float2 origin;
    float2 size;
};

vertex float4 barVertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Uniforms &u [[buffer(0)]],
                        constant Bar *bars [[buffer(1)]]) {
    float2 corner = float2(vid & 1, (vid >> 1) & 1);
    float2 clip = (bars[iid].origin + corner * bars[iid].size) / u.drawable * 2 - 1;
    return float4(clip.x, -clip.y, 0, 1);
}

fragment float4 barFragment(constant Uniforms &u [[buffer(0)]]) {
    return u.ink;
}

// Region names: each one a small bitmap, premultiplied.

struct Label {
    float2 origin;  // pixels
    float2 size;
    float alpha;
};

struct LabelVarying {
    float4 position [[position]];
    float2 uv;
    float alpha;
};

vertex LabelVarying labelVertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]],
                                constant Label &l [[buffer(1)]]) {
    float2 corner = float2(vid & 1, (vid >> 1) & 1);
    float2 clip = (l.origin + corner * l.size) / u.drawable * 2 - 1;
    return { float4(clip.x, -clip.y, 0, 1), corner, l.alpha };
}

fragment float4 labelFragment(LabelVarying in [[stage_in]], texture2d<float> image [[texture(0)]]) {
    constexpr sampler near(filter::nearest, address::clamp_to_edge);
    return image.sample(near, in.uv) * in.alpha;
}

// The palette: a dot for each picture, in its own color, already placed on screen.

struct PaletteDot {
    float2 center;  // pixels
    float half_size;
    float pad;
    float4 color;
};

struct PaletteDotVarying {
    float4 position [[position]];
    float2 local;
    float half_size;
    float4 color;
};

vertex PaletteDotVarying paletteDotVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                          constant Uniforms &u [[buffer(0)]],
                                          constant PaletteDot *dots [[buffer(1)]]) {
    PaletteDot d = dots[iid];
    float2 corner = float2(vid & 1, (vid >> 1) & 1) * 2 - 1;
    float2 local = corner * d.half_size;
    float2 clip = (d.center + local) / u.drawable * 2 - 1;
    return { float4(clip.x, -clip.y, 0, 1), local, d.half_size, d.color };
}

fragment float4 paletteDotFragment(PaletteDotVarying in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    // A hair of the ground's opposite keeps colors near the ground's own visible.
    float edge = in.half_size - max(abs(in.local.x), abs(in.local.y));
    float3 line = mix(in.color.rgb, u.ink.rgb, 0.28);
    return float4(edge < u.scale * 0.5 ? line : in.color.rgb, 1);
}

// The palette's guide lines: rings and the axis.

struct PaletteLine {
    float2 from;  // pixels
    float2 to;
    float width;
    float alpha;
};

struct PaletteLineVarying {
    float4 position [[position]];
    float alpha;
};

vertex PaletteLineVarying paletteLineVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                            constant Uniforms &u [[buffer(0)]],
                                            constant PaletteLine *lines [[buffer(1)]]) {
    PaletteLine l = lines[iid];
    float2 along = l.to - l.from;
    float2 side = normalize(float2(-along.y, along.x) + float2(1e-5, 0)) * l.width * 0.5;
    float2 ends = float2(vid & 1, (vid >> 1) & 1);
    float2 pixel = l.from + along * ends.x + side * (ends.y * 2 - 1);
    float2 clip = pixel / u.drawable * 2 - 1;
    return { float4(clip.x, -clip.y, 0, 1), l.alpha };
}

fragment float4 paletteLineFragment(PaletteLineVarying in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    return float4(u.ink.rgb * in.alpha, in.alpha);
}

// The terrain in 3D: the elevation field stood up as a mesh, one vertex per cell, over a
// level ground plane that runs out to the horizon. Its shading is the flat map's, the same
// dither in whole screen points and the same contour lines, with light from the northwest
// adding to the dither on slopes that face away. Fog thins it all out with distance.

// Keep in step with `ReliefUniforms` in TerrainRenderer.swift.
struct Relief {
    float4x4 viewProjection;
    float4 eye;
    float4 sun;          // toward the light
    float height;        // map units at elevation 1, as far as the relief has risen
    float exponent;
    float fogNear;       // map units from the eye
    float fogFar;
    float focal;         // points per map unit at a depth of one map unit
    float thumbnailZoom; // seen this close, a marker is a plain dot, as the flat map does
    float dotRadius;
    float gridStep;      // map units between the ground's rules
    uint side;           // mesh vertices per row
    float extent;        // half the ground plane's width
    float2 center;       // the ground plane's middle, on the map
};

struct ReliefVarying {
    float4 position [[position]];
    float2 map;
    float3 world;
};

static float3 surface(texture2d<float, access::read> field, constant Uniforms &u, constant Relief &r, float2 map) {
    Elevation e = sampleField(field, (map + u.origin) / u.cell - 0.5);
    return float3(map.x, r.height * pow(max(e.value, 0.0), r.exponent), map.y);
}

vertex ReliefVarying reliefVertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]],
                                  constant Relief &r [[buffer(1)]], texture2d<float, access::read> field [[texture(0)]]) {
    float2 map = (float2(vid % r.side, vid / r.side) + 0.5) * u.cell - u.origin;
    float3 world = surface(field, u, r, map);
    return { r.viewProjection * float4(world, 1), map, world };
}

vertex ReliefVarying groundVertex(uint vid [[vertex_id]], constant Relief &r [[buffer(1)]]) {
    float2 corner = float2(vid & 1, (vid >> 1) & 1) * 2 - 1;
    float2 map = r.center + corner * r.extent;
    // Just under the mesh, whose edges come down to zero.
    float3 world = float3(map.x, -0.4, map.y);
    return { r.viewProjection * float4(world, 1), map, world };
}

fragment float4 reliefFragment(ReliefVarying in [[stage_in]],
                               constant Uniforms &u [[buffer(0)]],
                               constant float *thresholds [[buffer(1)]],
                               constant float *dither [[buffer(2)]],
                               constant float *bayer [[buffer(3)]],
                               constant uint &levels [[buffer(4)]],
                               constant Relief &r [[buffer(5)]],
                               texture2d<float, access::read> field [[texture(0)]]) {
    float2 point = in.position.xy / u.scale;
    float3 color = u.ground.rgb;
    float distance = length(in.world - r.eye.xyz);
    float clear = 1 - saturate((distance - r.fogNear) / max(r.fogFar - r.fogNear, 1.0));

    // The ground's rules, fading out before they'd crowd into moiré.
    float2 across = fwidth(in.map);
    float2 off = abs(fract(in.map / r.gridStep + 0.5) - 0.5) * r.gridStep / max(across, 1e-5);
    float rule = saturate(0.75 - min(off.x, off.y)) * saturate(1.5 - max(across.x, across.y) * 8 / r.gridStep);
    color = mix(color, u.hair.rgb, rule * clear);

    Elevation e = sampleField(field, (in.map + u.origin) / u.cell - 0.5);
    float value = max(e.value, 0.0);

    // The slope of the height, for the light: h = height * value^exponent.
    float rate = value > 1e-3 ? r.height * r.exponent * pow(value, r.exponent - 1) : 0;
    float2 grad = clamp(rate * e.slope / u.cell, -8.0, 8.0);
    float3 normal = normalize(float3(-grad.x, 1, -grad.y));
    float shade = (r.sun.y - saturate(dot(normal, r.sun.xyz))) * 0.8;

    int band = -1;
    for (uint i = 0; i < levels; i++) {
        if (value >= thresholds[i]) band = i;
    }
    float density = (band >= 0 ? dither[band] : 0.0) + (value > 0.004 ? shade : 0.0);
    // Capped, as the flat map's is, so pictures and names stay readable on the shadowed side.
    density = clamp(density, 0.0, 0.6) * clear;
    uint2 dot = uint2(point) % 8;
    if (bayer[dot.y * 8 + dot.x] < density * 64) color = u.ink.rgb;

    // Contour lines a constant width on screen, however steeply they're seen.
    float step = max(fwidth(value), 1e-7);
    for (uint i = 0; i < levels; i++) {
        bool index = i % 4 == 3;
        float half_width = (index ? 1.1 : 0.5) * u.scale / 2;
        float coverage = saturate(half_width + 0.5 - abs(value - thresholds[i]) / step);
        color = mix(color, u.ink.rgb, coverage * (index ? 0.9 : 0.45) * clear);
    }
    return float4(color, 1);
}

// Markers standing on the relief: drawn a little toward the eye so the ground doesn't swallow
// them, sized by how near they are, and plain dots near enough for pictures, as on the flat map.
vertex MarkerVarying reliefMarkerVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                        constant Uniforms &u [[buffer(0)]],
                                        constant Marker *markers [[buffer(1)]],
                                        constant Relief &r [[buffer(2)]],
                                        texture2d<float, access::read> field [[texture(0)]]) {
    Marker m = markers[iid];
    float3 world = surface(field, u, r, m.position);
    world += normalize(r.eye.xyz - world) * 1.5;
    float4 clip = r.viewProjection * float4(world, 1);
    if (clip.w <= 0) return { float4(2, 2, 2, 1), float2(0), 0, 0 };
    float k = r.focal / clip.w;
    // Smaller than on the flat map, and shrinking faster with distance: seen at a slant and far
    // off, many more items share each point of the screen, and at full size they'd ink it solid.
    float radius = (k >= r.thumbnailZoom ? r.dotRadius * 0.7 : m.base * sqrt(k) * min(1.0, sqrt(k / r.thumbnailZoom)) * 0.8) * u.scale;
    float reach = radius + 1.0 * u.scale + 1.0;
    float2 corner = float2(vid & 1, (vid >> 1) & 1) * 2 - 1;
    clip.xy += corner * reach / u.drawable * 2 * clip.w;
    return { clip, corner * reach, radius, m.mine };
}
