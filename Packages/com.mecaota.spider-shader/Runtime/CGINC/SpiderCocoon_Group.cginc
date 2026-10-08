#ifndef SPIDERCOCOON_GROUP_INCLUDED
#define SPIDERCOCOON_GROUP_INCLUDED

// ---------------------------------------------------------------------------
// SpiderCocoon_Group.cginc
// 近くにある巻き付き繭（SpiderCocoonDepthDecal）どうしを「1 つの繭」として描く仕組み。
//
// ■ 何をしているか（シェーダー初心者向け）
//   シェーダーは「自分の箱」のことしか知らないので、近くの繭との関係は
//   Udon（CocoonGroupLinker）が毎フレーム MaterialPropertyBlock で渡す。
//     ・くっついた繭（両手首を合わせた・手を胸に当てた・両足をそろえた等）を
//       1 グループにまとめる
//     ・初回は最大の繭を代表にし、結合中はその代表を保持する。
//       代表だけが仲間全員の円筒の中の体表を描く（外殻無効時）。
//       描く範囲は「仲間それぞれの円筒の和」だけなので、繭の無い部位
//       （骨盤・頭など）は元になる体表として選ばない。
//       外殻有効時は GroupShell のワールド座標の円筒と橋を使う。
//     ・帯の向き（巻き座標）だけをグループで共通にする。軸は代表の軸、位置は
//       大きい繭ほど強く引き寄せた重み付き平均（_GroupCylA）。帯が繭をまたいで
//       同じ向きに走る。GroupShell の AxisWrap で高さを各部位の軸に沿わせる。
//     ・代表以外の繭は描かない（代表に任せる）。描く箱が 1 つなので、
//       繭どうしの継ぎ目や二重描きが起きない
//   グループに入っていない繭（_GroupRole=0）は従来どおり自分の円筒だけを巻く。
//
// 前提: _ProjectRange / _GlueThickness が宣言済み（SpiderCocoonDepthDecal.shader の CGINCLUDE）
// ---------------------------------------------------------------------------

// ---- CocoonGroupLinker が MaterialPropertyBlock で渡す（Properties には書かない） ----
float  _GroupRole;      // 0 = 単独 / 1 = 代表（まとめて描く）/ -1 = 代表に任せて描かない
float4 _GroupCylA;      // 巻き座標の軸: xyz = 軸が通る点（world）, w = 仲間全員を包む半径（m）
float4 _GroupCylB;      // xyz = 軸方向 × 半分の高さ（world）
float4 _GroupBoxHalf;   // 代表の箱を広げた半サイズ（オブジェクト空間。仲間全員を包む大きさ）

// 仲間それぞれの円筒（代表のときだけ使う。描く範囲はこれらの和）
#define SCG_MAX_MEMBERS 8
float4 _GroupMemA[SCG_MAX_MEMBERS];   // xyz = 中心（world）, w = 半径（m）
float4 _GroupMemB[SCG_MAX_MEMBERS];   // xyz = 軸方向 × 半分の高さ（world）
float  _GroupMemCount;

// ---- マテリアル ----
float _GroupBulge;     // grouped shell thickness beyond the original glue (m)
float _GroupBridgeSpan; // maximum extra span of taut silk between supported body parts
float _GroupShellBlend; // smooth union of neighbouring inflated surfaces
float _GooEdgeFray;     // 巻きの端のほつれ幅（m。0 でほつれ無し）
float _WrapFacing;      // 体表の向きで他の部位を除くしきい値（-1 で無効）

bool SCG_Hidden() { return _GroupRole < -0.5; }
bool SCG_Lead()   { return _GroupRole >  0.5; }

// 点 p から円筒（中心 c・軸方向×半分の高さ h・半径 r。端は平ら）表面までの
// 符号付き距離（m。負=内側）
float SCG_CylinderSD(float3 p, float3 c, float3 h, float r)
{
    float  hh  = length(h);
    float3 ax  = h / max(hh, 1e-6);
    float3 d   = p - c;
    float  y   = dot(d, ax);
    float2 q   = float2(length(d - ax * y) - r, abs(y) - hh);
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0));
}

// 描く範囲までの距離（代表のときだけ意味を持つ）。範囲は仲間それぞれの円筒の和で、
// 単独のときの体表の選択範囲と同じ。外殻の最終描画範囲は厚み分だけ広がる
float SCG_GroupSD(float3 p)
{
    int   n = (int)_GroupMemCount;
    float d = 1e3;
    [loop]
    for (int k = 0; k < SCG_MAX_MEMBERS; ++k)
    {
        if (k >= n) break;
        d = min(d, SCG_CylinderSD(p, _GroupMemA[k].xyz, _GroupMemB[k].xyz, _GroupMemA[k].w));
    }
    return d;
}

// 点 p を巻いている骨の軸（単独は自分、代表は p を一番内側に含む仲間の軸）
void SCG_OwnerAxis(float3 p, out float3 c, out float3 ax)
{
    c  = float3(unity_ObjectToWorld._m03, unity_ObjectToWorld._m13, unity_ObjectToWorld._m23);
    ax = normalize(float3(unity_ObjectToWorld._m01, unity_ObjectToWorld._m11, unity_ObjectToWorld._m21));
    if (!SCG_Lead()) return;
    int   n    = (int)_GroupMemCount;
    float best = 1e3;
    [loop]
    for (int k = 0; k < SCG_MAX_MEMBERS; ++k)
    {
        if (k >= n) break;
        float d = SCG_CylinderSD(p, _GroupMemA[k].xyz, _GroupMemB[k].xyz, _GroupMemA[k].w);
        if (d < best)
        {
            best = d;
            c    = _GroupMemA[k].xyz;
            float hl = length(_GroupMemB[k].xyz);
            ax = (hl > 1e-6) ? _GroupMemB[k].xyz / hl : ax;
        }
    }
}

// 体表の向き n（カメラ側を向いた世界法線）が、巻いている骨の軸から見て外向きか。
// 自分の手足の表面は軸から外を向く（内積≒1）。輪の中に入り込んだ別の部位
// （腕の内側・隣の腿など）の、こちらを向いた面は内向き（内積<0）になるので除ける
bool SCG_FacingOK(float3 p, float3 n)
{
    float3 c, ax;
    SCG_OwnerAxis(p, c, ax);
    float3 d   = p - c;
    float3 rad = d - ax * dot(d, ax);
    float  l   = length(rad);
    if (l < 1e-4) return true;
    return dot(n, rad / l) >= _WrapFacing;
}

// 代表のときは、まとめた繭を包む大きさまで箱を広げる（頂点シェーダーと
// フラグメントの箱判定で共用。オブジェクト空間の半サイズ）
float3 SCG_BoxHalf()
{
    if (!SCG_Lead()) return float3(0.5, 0.5, 0.5);
    float3 scale = float3(length(unity_ObjectToWorld._m00_m10_m20),
                          length(unity_ObjectToWorld._m01_m11_m21),
                          length(unity_ObjectToWorld._m02_m12_m22));
    float padding = (_GroupBulge > 0.0005) ? (max(_GlueThickness, 0.0) + _GroupBulge) * 1.3 : 0.0;
    return max(_GroupBoxHalf.xyz, 0.5) + padding / max(scale, 1e-4);
}

// 巻き座標（帯の角度・高さ）の原点。代表のときは「まとめた繭の円筒の中心」へずらす
// （軸は代表と同じなので平行移動だけでよい）。ずらさないと、代表から離れた仲間
// （両足の片方など）の上では角度がほとんど変わらず、帯が横倒しの縞になってしまう
float3 SCG_WrapLocal(float3 localPos)
{
    if (!SCG_Lead()) return localPos;
    float3 center = mul(unity_WorldToObject, float4(_GroupCylA.xyz, 1.0)).xyz;
    return localPos - center;
}

// 巻きの端からの深さ 0..1（ほつれ用）。sd は境界までの距離（m, 負=内側）
float SCG_Edge01(float sd)
{
    return saturate(-sd / max(_GooEdgeFray, 1e-4));
}

#endif // SPIDERCOCOON_GROUP_INCLUDED
