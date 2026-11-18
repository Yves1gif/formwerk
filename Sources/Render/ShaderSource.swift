// The Metal shaders, compiled when the app starts (device.makeLibrary(source:)).
// Kept as text so building needs no extra Metal toolchain download (Xcode 26 asks for one).
// Layouts must match RenderTypes.swift.

enum ShaderSource {
    static let code = #"""
#include <metal_stdlib>
using namespace metal;

// Layouts must match RenderTypes.swift.

struct Uniforms {
    float4x4 viewProj;
    float4 cameraPos;     // xyz
    float4 viewDir;       // xyz: direction the camera looks
    float4 cameraRight;   // xyz: screen right in world space
    float4 cameraUp;      // xyz: screen up in world space
    float4 clipPlane;     // xyz normal, w = offset; geometry with dot(n,p) > w is cut away
    float2 viewport;      // drawable size in pixels
    float clipOn;
    float pixelScale;     // pixels per point
};

struct MeshVertex {
    packed_float3 position;
    packed_float3 normal;
    uint face;
};

struct BodyUniforms {
    float4 color;
    float4 hoverColor;
    float4 selectColor;
    uint pickBase;        // body index << 20
    float alpha;
    float2 pad;
};

struct MeshOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    uint face [[flat]];
};

// Section view: everything on the positive side of the plane is cut away.
static bool clipped(constant Uniforms &u, float3 p) {
    return u.clipOn > 0.5 && dot(u.clipPlane.xyz, p) > u.clipPlane.w;
}

vertex MeshOut mesh_vertex(uint vid [[vertex_id]],
                           device const MeshVertex *verts [[buffer(0)]],
                           constant Uniforms &u [[buffer(1)]]) {
    MeshVertex v = verts[vid];
    MeshOut o;
    float3 p = float3(v.position);
    o.position = u.viewProj * float4(p, 1);
    o.world = p;
    o.normal = float3(v.normal);
    o.face = v.face;
    return o;
}

fragment float4 mesh_fragment(MeshOut in [[stage_in]],
                              bool front [[front_facing]],
                              constant Uniforms &u [[buffer(1)]],
                              constant BodyUniforms &b [[buffer(2)]],
                              device const uchar *faceState [[buffer(3)]]) {
    if (clipped(u, in.world)) discard_fragment();
    float3 n = normalize(in.normal);
    float3 toEye = normalize(u.cameraPos.xyz - in.world);
    // Back faces only show through a section cut: draw them as a flat cap colour.
    if (!front && dot(n, toEye) < 0) {
        return float4(b.color.rgb * 0.55, 1);
    }
    if (dot(n, toEye) < 0) n = -n;

    // Studio rig fixed to the camera, so every side of a part reads the same way when you orbit:
    // a warm key from the upper left, a weak cool fill from the right, a rim light from behind.
    float3 F = u.viewDir.xyz, R = u.cameraRight.xyz, U = u.cameraUp.xyz;
    float3 keyL  = normalize(-F * 0.75 + U * 0.55 - R * 0.40);
    float3 fillL = normalize(-F * 0.70 - U * 0.15 + R * 0.70);
    float3 rimL  = normalize( F * 0.60 + U * 0.70 + R * 0.20);
    // Wrapped diffuse: soft terminator instead of a hard light/shadow line.
    float key  = saturate((dot(n, keyL) + 0.25) / 1.25);
    float fill = saturate((dot(n, fillL) + 0.40) / 1.40);
    float rimD = saturate(dot(n, rimL));
    // Hemispheric ambient in world space: sky above (Z up), warm floor bounce below.
    float hemi = 0.5 + 0.5 * n.z;
    float3 ambient = mix(float3(0.27, 0.265, 0.26), float3(0.44, 0.455, 0.48), hemi);
    float3 h = normalize(keyL + toEye);
    float spec = pow(saturate(dot(n, h)), 48.0) * 0.16;
    float fresnel = pow(1.0 - saturate(dot(n, toEye)), 4.0);

    float3 base = b.color.rgb;
    uchar state = faceState[in.face];
    if (state == 1) base = mix(base, b.hoverColor.rgb, 0.35);
    else if (state == 2) base = mix(base, b.selectColor.rgb, 0.55);
    else if (state == 3) base = mix(base, float3(1.0, 0.55, 0.1), 0.75);   // overhang
    else if (state == 4) base = mix(base, float3(0.95, 0.15, 0.2), 0.75);  // thin wall

    float3 light = ambient + key * float3(0.50, 0.49, 0.47) + fill * float3(0.12, 0.13, 0.15);
    float3 c = base * light + spec + rimD * 0.07 + fresnel * 0.06;
    return float4(c, b.alpha);
}

fragment uint mesh_pick(MeshOut in [[stage_in]], constant Uniforms &u [[buffer(1)]], constant BodyUniforms &b [[buffer(2)]]) {
    if (clipped(u, in.world)) discard_fragment();
    return b.pickBase | in.face;
}

// MARK: - Lines (screen-space quads, one instance per segment)

struct LineSegment {
    packed_float3 a;
    packed_float3 b;
    packed_float4 color;
    float width;          // points
    uint pick;            // 0 = not pickable
};

struct LineOut {
    float4 position [[position]];
    float4 color;
    uint pick [[flat]];
    float across;         // pixels from the line's centre (signed)
    float halfWidth [[flat]];  // half the line's width in pixels
    float3 world;
};

vertex LineOut line_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                           device const LineSegment *segs [[buffer(0)]],
                           constant Uniforms &u [[buffer(1)]],
                           constant float &widthScale [[buffer(2)]]) {
    LineSegment s = segs[iid];
    float3 a = float3(s.a), b = float3(s.b);
    // Pull lines a tiny bit towards the camera (in world space, so it works at every depth)
    // so they win against the faces they lie on but stay hidden behind other faces.
    a += (u.cameraPos.xyz - a) * 0.0015;
    b += (u.cameraPos.xyz - b) * 0.0015;
    float4 ca = u.viewProj * float4(a, 1);
    float4 cb = u.viewProj * float4(b, 1);
    // Keep both ends in front of the camera.
    if (ca.w < 1e-4) ca = mix(ca, cb, (1e-4 - ca.w) / (cb.w - ca.w));
    if (cb.w < 1e-4) cb = mix(cb, ca, (1e-4 - cb.w) / (ca.w - cb.w));
    float2 sa = ca.xy / ca.w * u.viewport * 0.5;
    float2 sb = cb.xy / cb.w * u.viewport * 0.5;
    float2 d = sb - sa;
    float len = length(d);
    float2 dir = len > 1e-5 ? d / len : float2(1, 0);
    float2 perp = float2(-dir.y, dir.x);
    // Whole-pixel widths stay crisp on Retina (1.1 pt → 2 px at 2×, 3 px at 3×); one extra pixel
    // on each side holds the anti-aliased fringe.
    float hw = max(round(s.width * u.pixelScale * widthScale), 1.0) * 0.5;
    float w = hw + 1.0;

    // 0,1,2 / 2,1,3 → corners (end, side)
    uint corner = (vid == 0) ? 0 : (vid == 1 || vid == 4) ? 1 : (vid == 2 || vid == 3) ? 2 : 3;
    bool atB = corner == 1 || corner == 3;
    float side = (corner == 2 || corner == 3) ? 1.0 : -1.0;
    float4 c = atB ? cb : ca;
    float2 sp = (atB ? sb : sa) + perp * side * w + dir * (atB ? hw : -hw);
    LineOut o;
    // Pull lines slightly towards the camera so they win against the faces they lie on.
    o.position = float4(sp / (u.viewport * 0.5) * c.w, c.z, c.w);
    o.color = float4(s.color);
    o.pick = s.pick;
    o.across = side * w;
    o.halfWidth = hw;
    o.world = atB ? b : a;
    return o;
}

fragment float4 line_fragment(LineOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    if (clipped(u, in.world - u.clipPlane.xyz * 0.01)) discard_fragment();
    // A one-pixel coverage ramp centred on the true edge: crisp, on top of MSAA.
    float alpha = in.color.a * saturate(in.halfWidth + 0.5 - abs(in.across));
    return float4(in.color.rgb, alpha);
}

struct GridUniforms {
    float4 center;        // xyz on the plane, w = radius where the grid has faded out
    float4 normal;        // xyz = plane normal
};

// Grid lines: like line_fragment, but fading out with distance and towards the horizon.
fragment float4 grid_fragment(LineOut in [[stage_in]], constant Uniforms &u [[buffer(1)]],
                              constant GridUniforms &g [[buffer(2)]]) {
    if (clipped(u, in.world - u.clipPlane.xyz * 0.01)) discard_fragment();
    float alpha = in.color.a * saturate(in.halfWidth + 0.5 - abs(in.across));
    float r = g.center.w;
    float d = distance(in.world, g.center.xyz);
    alpha *= 1.0 - smoothstep(r * 0.3, r, d);
    // Where the plane turns edge-on the lines crowd into moiré: let them go.
    float3 toEye = normalize(u.cameraPos.xyz - in.world);
    alpha *= smoothstep(0.03, 0.22, abs(dot(toEye, g.normal.xyz)));
    if (alpha < 0.002) discard_fragment();
    return float4(in.color.rgb, alpha);
}

fragment uint line_pick(LineOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    if (in.pick == 0 || clipped(u, in.world - u.clipPlane.xyz * 0.01)) discard_fragment();
    return in.pick;
}

// MARK: - Points (round sprites)

struct PointSprite {
    packed_float3 p;
    packed_float4 color;
    float size;           // points
    uint pick;
};

struct PointOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
};

vertex PointOut point_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                             device const PointSprite *pts [[buffer(0)]],
                             constant Uniforms &u [[buffer(1)]]) {
    PointSprite s = pts[iid];
    float3 wp = float3(s.p);
    wp += (u.cameraPos.xyz - wp) * 0.003;
    float4 c = u.viewProj * float4(wp, 1);
    float2 corners[6] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(-1,1), float2(1,-1), float2(1,1) };
    float2 k = corners[vid];
    float r = s.size * u.pixelScale * 0.5;
    PointOut o;
    o.position = c + float4(k * r / (u.viewport * 0.5) * c.w, 0, 0);
    o.color = float4(s.color);
    o.uv = k;
    return o;
}

fragment float4 point_fragment(PointOut in [[stage_in]]) {
    float d = length(in.uv);
    if (d > 1.0) discard_fragment();
    // White ring around a coloured dot reads well on any background.
    float3 c = d > 0.62 ? float3(1) : in.color.rgb;
    return float4(c, in.color.a * smoothstep(1.0, 0.85, d));
}

// MARK: - Contact shadows (one blurred rounded rectangle per body, on the ground)

struct Shadow {
    float4 rect;          // minX, minY, maxX, maxY
    float4 params;        // ground z, blur, corner radius, darkness
};

struct ShadowOut {
    float4 position [[position]];
    float2 p;
};

vertex ShadowOut shadow_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(1)]],
                               constant Shadow &s [[buffer(2)]]) {
    float2 corners[6] = { float2(0,0), float2(1,0), float2(0,1), float2(0,1), float2(1,0), float2(1,1) };
    float m = s.params.y;
    float2 lo = s.rect.xy - m, hi = s.rect.zw + m;
    float2 p = mix(lo, hi, corners[vid]);
    ShadowOut o;
    o.position = u.viewProj * float4(p, s.params.x, 1);
    o.p = p;
    return o;
}

fragment float4 shadow_fragment(ShadowOut in [[stage_in]], constant Shadow &s [[buffer(2)]]) {
    float2 c = (s.rect.xy + s.rect.zw) * 0.5;
    float2 hs = (s.rect.zw - s.rect.xy) * 0.5;   // ("half" is a type name in Metal)
    float r = min(s.params.z, min(hs.x, hs.y));
    float2 q = abs(in.p - c) - hs + r;
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;   // < 0 inside the footprint
    float blur = max(s.params.y, 1e-3);
    float a = s.params.w * (1.0 - smoothstep(-blur * 0.6, blur, d));
    return float4(0, 0, 0, a);
}

// MARK: - Flat translucent triangles (sketch regions)

struct FlatUniforms { float4 color; };

vertex float4 flat_vertex(uint vid [[vertex_id]],
                          device const packed_float3 *pos [[buffer(0)]],
                          constant Uniforms &u [[buffer(1)]]) {
    float3 p = float3(pos[vid]);
    p += (u.cameraPos.xyz - p) * 0.0008;
    return u.viewProj * float4(p, 1);
}

fragment float4 flat_fragment(constant FlatUniforms &f [[buffer(0)]]) {
    return f.color;
}

"""#
}
