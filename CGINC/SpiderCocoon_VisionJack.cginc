#ifndef SPIDERCOCOON_VISIONJACK_INCLUDED
#define SPIDERCOCOON_VISIONJACK_INCLUDED

// ---------------------------------------------------------------------------
// SpiderCocoon_VisionJack.cginc
// 視界ジャック＝「包まれ演出」の共通実装。
// カメラ（VRでは両目の中点）がオブジェクトの内側に入ったら、オブジェクトを
// 中心とした「上下が閉じた紡錘形（楕円体）の繭の内壁」を実寸の深度付きで描く。
// 本体 SpiderCocoon.shader と SpiderCocoonDepthDecal.shader の両方がこれを使う。
//
// ★ 旧実装との違い（描画順・深度の扱い）:
//   旧: 深度を近クリップ面に書き ZTest Always → 視界を完全に乗っ取り、
//       自分のアバターの体さえ糸の壁の裏へ消えていた。
//   新: 内壁の「実際の深度」を SV_Depth に書き ZTest LEqual → 内壁は
//       ワールドに実在する壁として振る舞う。
//       - 壁より手前のもの（自分の体・同じ繭の中の他プレイヤー等）は
//         ハードウェアZテストで壁に勝ち、遮られず普通に見える
//       - 壁より奥の世界は糸に覆われ、糸の隙間からだけ覗ける
//       → 「視界を奪われる」ではなく「繭に包まれている」見え方になる。
//
// 使い方（両シェーダー共通のパス構成）:
//   ZWrite On / ZTest LEqual / Cull Front / Blend SrcAlpha OneMinusSrcAlpha
//   Stencil [_StencilRef]（既定128）Replace
//   （後続の glue パスがジャック画素を上塗りしない目印。他シェーダーと衝突
//     したらマテリアルで付け替え可能。本体・デカールで同値に揃えること）
//   頂点: 発火中はメッシュを×100拡大（壁が近クリップ面に切られて画面に
//         穴が開くのを防ぐ）。非発火時は縮退させフラグメント自体を出さない。
//   フラグメント: SC_VisionJackWallShade() を呼ぶだけ。
//
// 前提 include（.shader 側でこの順に読み込むこと）:
//   Noise → Common（SC_IsInMirror / SC_MonoCameraPos / uniforms）
//         → Thread → Lighting → Compose（SC_ShadeCocoonAt）→ 本ファイル
// ---------------------------------------------------------------------------

// 発火判定。radius / height はオブジェクト空間の円筒しきい値
// （軸からの距離 < radius かつ |y| < height で発火）。
// ★ 判定は SC_MonoCameraPos（VRでは両目の中点）で行う。目ごとのカメラ位置で
//   判定すると、境界付近で左目だけ発火して左右の表示が食い違うため。
//   既知の制限: VRChat のミラーは目ごとに別の反射カメラで mono 描画されるため、
//   _VisionJackInMirror=1 かつ反射カメラ位置が境界を跨いだ瞬間だけは
//   鏡の中の左右がずれ得る（既定値 0 では発生しない）。
bool SC_VisionJackActiveEx(float radius, float height)
{
    if (_VisionJackEnable < 0.5) return false;
    if (SC_IsInMirror() && _VisionJackInMirror < 0.5) return false;
    float3 camOS = mul(unity_WorldToObject, float4(SC_MonoCameraPos(), 1.0)).xyz;
    return (length(camOS.xz) < radius) && (abs(camOS.y) < height);
}

// 本体 SpiderCocoon 用の発火判定（専用プロパティを束ねただけの別名）
bool SC_VisionJackActive()
{
    return SC_VisionJackActiveEx(_VisionJackRadius, _VisionJackHeight);
}

// 繭の内壁を描く。
//   worldDir        : カメラ→ピクセルのワールドレイ（頂点から補間した非正規化ベクトル）
//   wallRadius      : 内壁楕円体の半径（オブジェクト空間）
//   wallHalfHeight  : 内壁が上下に閉じるまでの半高（オブジェクト空間）
//   outDepth        : 壁の実深度（Zバッファ値）を書き出す
// 糸の隙間のピクセルは内部で discard（色・深度・ステンシルとも書かれない）。
fixed4 SC_VisionJackWallShade(float3 worldDir, float wallRadius, float wallHalfHeight,
                              out float outDepth)
{
    // 交差先は無限円筒ではなく「上下が閉じた紡錘形（楕円体）」。
    // 上下に遠ざかるほど糸のリングの半径が縮み、極で 0 に収束して閉じる。
    // レイはピクセルごとの実視線（VRでは目ごとの位置から）を使う。壁はワールドに
    // 固定された実寸の面なので、左右の目は同じ壁を正しい視差で見る＝立体視が成立する。
    float3 rdW = normalize(worldDir);
    float3 o = mul(unity_WorldToObject, float4(_WorldSpaceCameraPos, 1.0)).xyz;
    float3 d = mul((float3x3)unity_WorldToObject, rdW);

    float A = max(wallRadius, 1e-4);       // 内壁の半径
    float B = max(wallHalfHeight, 1e-4);   // 半高（閉じるまでの距離）

    // 楕円体を単位球へスケールしてレイ-球交差（奥側解）
    float3 os = float3(o.x / A, o.y / B, o.z / A);
    float3 ds = float3(d.x / A, d.y / B, d.z / A);

    // 原点の引き込み: 内壁が発火判定より小さいため、カメラが楕円体の外
    // （または縁ぎりぎり）に居ることがある。その場合も内側へ寄せて、
    // 常に「内側から奥壁を見る」状態を保証する。
    // ★ 引き込み量は「中央カメラ（両目の中点）」基準で平行移動として求め、
    //   左右の目へ同一に適用する。目ごとに独立へ引き込むと、左右の目が
    //   「異なるワールド位置の壁」を復元してしまい、両眼視野闘争が起きる。
    //   平行移動なら IPD（両目の間隔）ベクトルが保存され、立体視が保たれる。
    // ★ 引き込み目標は「共通平行移動後に両目とも球内（余白 0.98）へ収まる」
    //   ことを保証するため、球正規化空間での半IPD ぶんだけ内側へ強める。
    //   （壁が小さいほど正規化空間での IPD は大きくなる。固定目標 0.85 だと
    //     壁のワールド半径が約0.25m を下回る現実的な設定で片目が球外に残り、
    //     下の per-eye 最終保険が発動して IPD が崩れてしまう）
    float target = 0.85;
#if defined(USING_STEREO_MATRICES)
    float3 ipdW = unity_StereoWorldSpaceCameraPos[1].xyz - unity_StereoWorldSpaceCameraPos[0].xyz;
    float3 ipdO = mul((float3x3)unity_WorldToObject, ipdW);
    float  ipdS = 0.5 * length(float3(ipdO.x / A, ipdO.y / B, ipdO.z / A)); // 半IPD（球空間）
    target = min(target, 0.98 - min(ipdS, 0.9));
#endif
    float3 oM  = mul(unity_WorldToObject, float4(SC_MonoCameraPos(), 1.0)).xyz;
    float3 osC = float3(oM.x / A, oM.y / B, oM.z / A);
    float  cLen = length(osC);
    if (cLen > target) os += osC * (target / cLen) - osC;

    // 最終保険: 壁が極端に小さく（球空間の半IPD が 0.9 超＝壁半径が数cm級）、
    // 上の適応目標でも片目が球の外に残る縮退時のみ、その目を球内へ寄せる。
    // 通常〜小型の壁では上の IPD 適応により到達しない。
    float osLen = length(os);
    if (osLen > 0.98) os *= 0.98 / osLen;

    float a2 = max(dot(ds, ds), 1e-9);
    float b2 = 2.0 * dot(os, ds);
    float c2 = dot(os, os) - 1.0;          // 引き込み後は常に負
    float t  = (-b2 + sqrt(max(b2 * b2 - 4.0 * a2 * c2, 0.0))) / (2.0 * a2);

    float3 oc = float3(os.x * A, os.y * B, os.z * A);    // 引き込み後のローカル原点
    float3 lp = oc + d * t;
    float3 wp = mul(unity_ObjectToWorld, float4(lp, 1.0)).xyz;

    // ★ 壁の実深度をZバッファ値へ変換して書き出す（包まれ演出の核心）。
    // 原点引き込み中は壁の交差点がカメラの真横〜後ろに来ることがある
    // （clip.w ≤ 0）。その画素は「顔に糸が張り付いている」状態なので
    // 最前面（近クリップ値）として扱う。
    float4 clipPos = UnityWorldToClipPos(wp);
    if (clipPos.w <= 1e-4)
    {
        outDepth = UNITY_NEAR_CLIP_VALUE;
    }
    else
    {
        float zBuf = clipPos.z / clipPos.w;
    #if !defined(UNITY_REVERSED_Z)
        zBuf = zBuf * 0.5 + 0.5;   // OpenGL系: クリップz(-1..1)→深度(0..1)
    #endif
        outDepth = saturate(zBuf); // 近クリップより手前は最前面へクランプ
    }

    // 楕円体の内向き法線（勾配ベース。ローカル→ワールドへ方向変換）
    float3 nL = normalize(float3(lp.x / (A * A), lp.y / (B * B), lp.z / (A * A)));
    float3 colX = float3(unity_ObjectToWorld._m00, unity_ObjectToWorld._m10, unity_ObjectToWorld._m20);
    float3 colY = float3(unity_ObjectToWorld._m01, unity_ObjectToWorld._m11, unity_ObjectToWorld._m21);
    float3 colZ = float3(unity_ObjectToWorld._m02, unity_ObjectToWorld._m12, unity_ObjectToWorld._m22);
    float3 nW = normalize(colX * nL.x + colY * nL.y + colZ * nL.z);

    // 糸のパラメータもライティングも通常の繭と完全に同一（SC_ShadeCocoonAt）。
    return SC_ShadeCocoonAt(lp, wp, -nW);
}

#endif // SPIDERCOCOON_VISIONJACK_INCLUDED
