//
//  AnalyticsGraphShaders.metal
//  AXTerm
//
//  Created by AXTerm on 2026-03-20.
//

#include <metal_stdlib>
using namespace metal;

struct GraphUniforms {
    float2 viewSize;
    float2 inset;
    float2 offset;
    float scale;
    float padding;
};

struct CircleVertex {
    float2 position;
};

struct NodeInstance {
    float2 center;
    float radius;
    float4 color;
};

struct EdgeInstance {
    float2 start;
    float2 end;
    float thickness;
    float4 color;
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

float2 toPixel(float2 normalized, constant GraphUniforms &u) {
    float2 size = u.viewSize;
    float2 inset = u.inset;
    float2 base = float2(
        inset.x + normalized.x * (size.x - inset.x * 2.0),
        inset.y + normalized.y * (size.y - inset.y * 2.0)
    );
    float2 center = size * 0.5;
    return (base - center) * u.scale + center + u.offset;
}

float2 toClip(float2 pixel, constant GraphUniforms &u) {
    float2 size = u.viewSize;
    return float2(
        (pixel.x / size.x) * 2.0 - 1.0,
        1.0 - (pixel.y / size.y) * 2.0
    );
}

vertex VertexOut graphNodeVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant CircleVertex *vertices [[buffer(0)]],
    constant NodeInstance *instances [[buffer(1)]],
    constant GraphUniforms &uniforms [[buffer(2)]]
) {
    CircleVertex vertex = vertices[vertexID];
    NodeInstance node = instances[instanceID];
    float2 centerPixel = toPixel(node.center, uniforms);
    float2 pixel = centerPixel + vertex.position * node.radius * uniforms.scale;
    VertexOut out;
    out.position = float4(toClip(pixel, uniforms), 0.0, 1.0);
    out.color = node.color;
    return out;
}

vertex VertexOut graphEdgeVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant EdgeInstance *edges [[buffer(0)]],
    constant GraphUniforms &uniforms [[buffer(1)]]
) {
    EdgeInstance edge = edges[instanceID];
    float2 startPixel = toPixel(edge.start, uniforms);
    float2 endPixel = toPixel(edge.end, uniforms);
    float2 dir = endPixel - startPixel;
    float len = length(dir);
    if (len < 0.0001) {
        dir = float2(0.0, 1.0);
    } else {
        dir /= len;
    }
    float2 normal = float2(-dir.y, dir.x);
    float halfThickness = max(0.5, edge.thickness * uniforms.scale) * 0.5;
    float2 offset = normal * halfThickness;

    float2 pixel;
    switch (vertexID) {
        case 0:
            pixel = startPixel - offset;
            break;
        case 1:
            pixel = startPixel + offset;
            break;
        case 2:
            pixel = endPixel - offset;
            break;
        default:
            pixel = endPixel + offset;
            break;
    }

    VertexOut out;
    out.position = float4(toClip(pixel, uniforms), 0.0, 1.0);
    out.color = edge.color;
    return out;
}

fragment float4 graphSolidFragment(VertexOut in [[stage_in]]) {
    return in.color;
}
