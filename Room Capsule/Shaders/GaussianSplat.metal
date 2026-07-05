//
//  GaussianSplat.metal
//  Room Capsule
//
//  3D Gaussian Splatting の実レンダリング。
//  各ガウスの 3D 共分散(CPU で事前計算済み)をスクリーン空間の 2D 共分散へ投影し、
//  固有分解した楕円クアッドをインスタンス描画する。
//  ソート済みインデックス(奥→手前)でアルファ合成する前提。
//

#include <metal_stdlib>
using namespace metal;

struct SplatUniforms {
    float4x4 view;        // モデル(上下反転)込みのビュー行列
    float4x4 projection;
    float2 viewport;      // ドローアブルのピクセルサイズ
    float2 focal;         // ピクセル単位の焦点距離 (fx, fy)
};

struct SplatOut {
    float4 position [[position]];
    float2 local;         // クアッド内ローカル座標(±2 = ±2σ 相当)
    half4 color;
};

static SplatOut culled() {
    SplatOut out;
    out.position = float4(0.0, 0.0, 2.0, 1.0); // クリップ外に飛ばして捨てる
    out.local = float2(0.0);
    out.color = half4(0.0);
    return out;
}

vertex SplatOut splatVertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    const device packed_float3* positions [[buffer(0)]],
    const device float* covariances [[buffer(1)]],
    const device uchar4* colors [[buffer(2)]],
    const device uint* sortedIndices [[buffer(3)]],
    constant SplatUniforms& u [[buffer(4)]])
{
    uint gi = sortedIndices[iid];
    float3 center = float3(positions[gi]);

    float4 viewPos = u.view * float4(center, 1.0);
    // カメラは -z を向く。背後・至近は捨てる
    if (viewPos.z > -0.02) {
        return culled();
    }
    float4 clip = u.projection * viewPos;
    float margin = 1.3 * clip.w;
    if (clip.x < -margin || clip.x > margin || clip.y < -margin || clip.y > margin) {
        return culled();
    }

    // 世界空間の 3D 共分散(対称行列)
    float cxx = covariances[6 * gi + 0];
    float cxy = covariances[6 * gi + 1];
    float cxz = covariances[6 * gi + 2];
    float cyy = covariances[6 * gi + 3];
    float cyz = covariances[6 * gi + 4];
    float czz = covariances[6 * gi + 5];
    float3x3 Vrk = float3x3(
        float3(cxx, cxy, cxz),
        float3(cxy, cyy, cyz),
        float3(cxz, cyz, czz));

    // ビュー回転(上位 3x3)でビュー空間へ
    float3x3 R = float3x3(u.view[0].xyz, u.view[1].xyz, u.view[2].xyz);
    float3x3 Sv = R * Vrk * transpose(R);

    // 透視投影のヤコビアンで 2D へ(u = -fx·x/z, v = -fy·y/z)
    float invZ = 1.0 / viewPos.z;
    float3 J0 = float3(-u.focal.x * invZ, 0.0, u.focal.x * viewPos.x * invZ * invZ);
    float3 J1 = float3(0.0, -u.focal.y * invZ, u.focal.y * viewPos.y * invZ * invZ);
    float a = dot(J0, Sv * J0) + 0.3; // +0.3px はアンチエイリアス用ローパス
    float b = dot(J0, Sv * J1);
    float c = dot(J1, Sv * J1) + 0.3;

    // 2x2 共分散の固有分解 → 楕円の長短軸(ピクセル)
    float mid = 0.5 * (a + c);
    float rad = length(float2(0.5 * (a - c), b));
    float lambda1 = mid + rad;
    float lambda2 = max(mid - rad, 0.01);
    float2 diag = (abs(b) < 1e-6)
        ? ((a >= c) ? float2(1.0, 0.0) : float2(0.0, 1.0))
        : normalize(float2(b, lambda1 - a));
    float2 majorAxis = min(sqrt(2.0 * lambda1), 1024.0) * diag;
    float2 minorAxis = min(sqrt(2.0 * lambda2), 1024.0) * float2(diag.y, -diag.x);

    // 三角形ストリップの 4 隅(±2σ をカバー)
    float2 corner = float2((vid & 1) ? 2.0 : -2.0, (vid & 2) ? 2.0 : -2.0);
    float2 centerNdc = clip.xy / clip.w;
    float2 offsetNdc = (corner.x * majorAxis + corner.y * minorAxis) * 2.0 / u.viewport;

    SplatOut out;
    out.position = float4(centerNdc + offsetNdc, 0.0, 1.0);
    out.local = corner;
    out.color = half4(colors[gi]) / 255.0h;
    return out;
}

fragment half4 splatFragment(SplatOut in [[stage_in]]) {
    // ガウス減衰。exp(-4) 以下は捨てる
    float falloff = -dot(in.local, in.local);
    if (falloff < -4.0) {
        discard_fragment();
    }
    half alpha = half(exp(falloff)) * in.color.a;
    // プリマルチプライド α で奥→手前に合成
    return half4(in.color.rgb * alpha, alpha);
}
