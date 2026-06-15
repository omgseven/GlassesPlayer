#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 ndc;
};

struct Uniforms {
    float cameraYaw;
    float cameraPitch;
    float tanHalfVFOV;
    float aspectRatio;
    int eyeIndex;
    int sourceLayout;
};

vertex VertexOut projectionVertex(uint vid [[vertex_id]]) {
    float2 positions[] = {float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1)};
    VertexOut out;
    out.position = float4(positions[vid], 0, 1);
    out.ndc = positions[vid];
    return out;
}

fragment float4 projectionFragment(VertexOut in [[stage_in]],
                                   texture2d<float> videoTexture [[texture(0)]],
                                   constant Uniforms &uniforms [[buffer(0)]]) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear,
                                 address::clamp_to_edge);

    float texU, texV;

    // Flat 2D projection — direct NDC-to-UV mapping, both eyes see the same frame
    if (uniforms.sourceLayout == 3) {
        float2 uv = (in.ndc + 1.0) * 0.5;
        uv.y = 1.0 - uv.y;
        return videoTexture.sample(texSampler, uv);
    }

    // 360° / 180° equirectangular projection
    float2 ndc = in.ndc;
    float3 camDir = normalize(float3(ndc.x * uniforms.tanHalfVFOV * uniforms.aspectRatio,
                                     ndc.y * uniforms.tanHalfVFOV, 1.0));

    float cp = cos(uniforms.cameraPitch), sp = sin(uniforms.cameraPitch);
    float3 p = float3(camDir.x, camDir.y * cp + camDir.z * sp, -camDir.y * sp + camDir.z * cp);

    float cy = cos(uniforms.cameraYaw), sy = sin(uniforms.cameraYaw);
    float3 dir = float3(p.x * cy + p.z * sy, p.y, -p.x * sy + p.z * cy);

    if (uniforms.sourceLayout != 2 && dir.z <= 0.0) return float4(0, 0, 0, 0);

    float theta = atan2(dir.x, dir.z);
    float phi = acos(clamp(dir.y, -1.0f, 1.0f));
    float rawU = theta / M_PI_F + 0.5;
    float rawV = phi / M_PI_F;

    if (uniforms.sourceLayout == 0) {
        texU = rawU * 0.5 + float(uniforms.eyeIndex) * 0.5;
        texV = rawV;
    } else if (uniforms.sourceLayout == 1) {
        texU = rawU;
        texV = rawV * 0.5 + float(uniforms.eyeIndex) * 0.5;
    } else {
        texU = theta / (2.0 * M_PI_F) + 0.5;
        texV = rawV;
    }

    return videoTexture.sample(texSampler, float2(texU, texV));
}
