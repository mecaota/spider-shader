#ifndef SPIDERCOCOON_VISIONJACK_INCLUDED
#define SPIDERCOCOON_VISIONJACK_INCLUDED

// ---------------------------------------------------------------------------
// SpiderCocoon_VisionJack.cginc
// カメラが繭の内側に入ったとき、糸の描画を画面いっぱいに引き伸ばして
// 視界をジャックする。発火条件の判定と、頂点をフルスクリーンへリマップする処理。
// ※ spider-thread/SpiderThread_VisionJack.cginc を基に内側判定へ作り替え。
//
// 重要: 発火判定は「頂点の表裏」ではなく「カメラ位置が繭の内側か」で行う。
//   円柱は常に半分が裏面なので、頂点単位の裏面判定では正面から見ても
//   奥の裏面が条件を満たして誤発火してしまう。カメラ位置で判定すれば
//   外から見ている間は決して発火せず、内側に入った時だけ発火する。
// ---------------------------------------------------------------------------

// 視界ジャックを発火するか（全頂点で同じ結果＝カメラ単位の判定）
bool SC_VisionJackActive()
{
    if (_VisionJackEnable < 0.5) return false;
    if (SC_IsInMirror() && _VisionJackInMirror < 0.5) return false;

    // カメラ位置をオブジェクト空間へ。軸(ローカルY)からの距離と高さで内外判定。
    float3 camOS  = mul(unity_WorldToObject, float4(_WorldSpaceCameraPos, 1.0)).xyz;
    float  radial = length(camOS.xz);
    return (radial < _VisionJackRadius) && (abs(camOS.y) < _VisionJackHeight);
}

// 発火時、頂点 UV をクリップ空間フルスクリーンへ写す。
// メッシュ UV が 0..1 を覆っていれば裏面領域が画面全体へ展開される。
// 近平面に置き深度テストを実質無効化（常に手前）。
float4 SC_VisionJackClipPos(float2 uv)
{
    float2 ndc = uv * 2.0 - 1.0;
    ndc.y *= _ProjectionParams.x;   // プラットフォームの上下反転に追従
    return float4(ndc, UNITY_NEAR_CLIP_VALUE, 1.0);
}

#endif // SPIDERCOCOON_VISIONJACK_INCLUDED
