// =============================================================================
//  SpiderWeb_Drape.cginc — 投げつけた網が体に覆いかぶさる頂点変形（_DrapeEnable）
//
//  ■ 何をしているか（シェーダー入門向け）
//    平らな網（WebPlane メッシュ）の頂点を、頂点シェーダーで体の表面へ動かす。
//    体の形は Udon（CaptureNetDrape）がボーン位置から作った「カプセル」
//    （線分＋半径＝ソーセージ形）最大 SW_DRAPE_MAX 本で近似し、毎フレーム
//    MaterialPropertyBlock の配列 _DrapeCapA / _DrapeCapB で渡す。
//
//    1. 網は「飛んできた方向 D」に垂直な円盤として考える。頂点の UV から
//       円盤上の 2D 位置 q（中心から何 m 右・上か）を求める。
//    2. q を通って D 方向に進む光線が、各カプセルに最初に当たる深さを計算する
//       （光線とカプセルの交差＝数式で一発）。当たれば網はそこ（体の手前の面）に乗る。
//    3. どのカプセルにも当たらない（体の輪郭の外の）頂点は、はみ出した長さの分だけ
//       カプセルの断面の円に沿って背中側へ回り込む（弧の長さ＝はみ出し）。真後ろまで
//       回っても余った分は後ろへ伸び、はみ出しの 2 乗に比例して重力で垂れる。
//       → 網のふちが体の横から背中側へ回り込む、覆いかぶさった見た目になる。
//       どの部位に巻きつくかは「同じ高さの部位」を優先する（_DrapeCling）。
//       膝の横の網は上にある手ではなく脚に巻きつくので、ドレス状に広がらず脚の形が出る。
//       螺旋巻きモードでは、余った網を体の周りへ何周も巻きつける。
//       _DrapeTurns は最大の周回数で、0 なら上記の従来の動きのまま。
//       _DrapeLayer は 1 周ごとに外へ重ねる厚みで、網どうしが重なるちらつきを抑える。
//       _DrapeBunch は巻ききれない余りを外へふくらませる量（余り 1m あたりの厚み）。
//    4. カプセルごとの深さは smooth-min（なめらかな最小値）で合成する。
//       腕と胴のすき間のような所は、網がすき間に落ち込まず橋渡しする。
//    5. 床より下へ垂れた頂点は床の上へ押し戻す（床の高さは Udon が足元へ Raycast して渡す）。
//    6. 法線・接線は q を少しずらした 2 点も同じ計算に通して差分で求める
//       （変形後の面に合わせた陰影になる）。
//
//  変位はワールド空間で直接計算するので、Transform は描画範囲（カリング用の
//  バウンズ）を決めるだけ。模様は UV で決まるため、糸は面に貼りついたまま伸び縮みする。
//
//  ■ 姿勢追従（_DrapeFollow）
//    着弾時の姿勢を「基準のカプセル」として保存し、その姿勢の上で網の形を決める。
//    各点を近くの体の部位へ貼りつけ、部位の動きに合わせて動かす（スキニング）。
//    アバターのメッシュがボーンについて動くのと同じ考え方で、関節の境目は
//    複数の部位の動きをなめらかに混ぜる。毎フレーム投影し直さないので位置が滑らない。
//    体に触れている所は部位と一緒に動き、体から離れて垂れている余り（裾）は
//    体が傾いた（寝た）分だけ地面の方へ垂れる（_DrapeFollowHang）。横向きに寝ても裾が上へ立たない。
//    その後、重力で下へ垂らし、現在の体から押し戻し、最後に現在の床の上へ戻す。
//    0 のときは従来どおり。上から降る網には使わない。
//
//  ■ 上から降ってきた網（_DrapeFall.x = 1、FallingWebArea）
//    上の光線モデルは「横から飛んできた網」用で、真上から当てると余りが体の中へ
//    潰れてしまう。真上から落ちた網は、頭のてっぺんに中心が乗って肩から体の周りへ
//    垂れ下がる（投網やシーツをかぶった形）ので、別の決め方をする（SW_DrapeFallDeform）。
//    1. 網の UV を極座標（中心からの距離 ρ・向き φ）にする。
//    2. 体の軸（胴の中心）から向き φ へ、各高さで体がどこまで張り出しているかを求める
//       （カプセルの水平断面をその向きへ測った長さ＝支持関数。部位間は smooth-max）。
//    3. 頭のてっぺんから下へ、その張り出しに沿った断面の線を少しずつたどり、
//       たどった長さ（弧長）が ρ になる所に頂点を置く。一番張り出した所（肩・ひじ）から
//       下は _DrapeFall.y の割合で真下へ垂れる（0 なら体にぴったり貼りつく）。
//       輪の長さが体の周りより余る分は縦のひだになる。
//    4. 床まで届いた余りは床の上へ外向きに広がる。
//    落下中（_DrapeFall.w > 0）は体のてっぺんからその高さに浮いた平らな円盤で、
//    ふちは少し持ち上がって波打つ。着地後は _DrapeDir.w（0..1）で中心から順に
//    かぶさり、ふちはまず下へ落ちてから体へ寄る。
// =============================================================================
#ifndef SPIDERWEB_DRAPE_INCLUDED
#define SPIDERWEB_DRAPE_INCLUDED

#define SW_DRAPE_MAX 20

float  _DrapeEnable;
float  _DrapeGap;       // 体の表面からの浮き (m)
float  _DrapeSmooth;    // 部位どうしのなじみ幅 (m)
float  _DrapeWrap;      // 背中側へ巻き込む量 0..1
float  _DrapeCling;     // 同じ高さの部位に巻きつく強さ（上下のはみ出しを何倍に数えるか）
float  _DrapeTail;      // 巻き込んだ後の余りが後ろへ伸びる比率
float  _DrapeSag;       // 余りの重力たるみ (m / m²)
float  _DrapeTurns;     // 螺旋巻きの最大周回数（0 なら従来の動き）
float  _DrapeLayer;     // 1 周ごとに外へ重ねる厚み (m)
float  _DrapeBunch;     // 巻ききれない余りのふくらみ (m / m)
float  _DrapeStretchFade; // 何倍に伸びたら薄くし始めるか（その 2 倍で完全に消える）
float  _DrapeFollowBlend; // 姿勢追従で部位の動きを混ぜる幅 (m)
float  _DrapeFollowPush;  // 現在の体から押し戻す強さ 0..1
float  _DrapeFollowHang;  // 体から離れた余りを重力で垂らす割合 0..1
float  _DrapeFollowHangDist; // 体からこの距離 (m) 離れた所で垂らしきる
float  _DrapeCount;     // 有効カプセル数（Udon が設定）
// 以下は Udon が MaterialPropertyBlock で渡す（Properties には書かない）
float4 _DrapeCenter;    // xyz 網の中心（胴）   w 網の半径 (m)
float4 _DrapeDir;       // xyz 飛んできた方向（体へ向かう向き）  w かぶさり具合 0..1
float4 _DrapeUp;        // xyz 網の上方向の基準  w たるみの揺れ倍率
float4 _DrapeFloor;     // 床の平面 xyz 法線 w 距離（法線 0 で無効）
float4 _DrapeCapA[SW_DRAPE_MAX];  // xyz カプセルの端点 A  w 半径 (m)
float4 _DrapeCapB[SW_DRAPE_MAX];  // xyz カプセルの端点 B
// 追従中は上記のカプセル・中心・向きが着弾時の基準姿勢。床だけは現在の平面。
float  _DrapeFollow;             // 0 が従来、1 が姿勢追従（MPB 専用）
float4 _DrapeCurA[SW_DRAPE_MAX];  // 現在の端点 A xyz、半径 w
float4 _DrapeCurB[SW_DRAPE_MAX];  // 現在の端点 B xyz
float4 _DrapeSkinX[SW_DRAPE_MAX]; // 基準位置から現在位置への 3x4 行列の各行
float4 _DrapeSkinY[SW_DRAPE_MAX];
float4 _DrapeSkinZ[SW_DRAPE_MAX];
// 上から降ってきた網（0 のままなら従来の投げた網）
//   x 1=上から降る網  y 垂れ下がり 0（体に貼りつく）..1（一番広い所から真下へ）
//   z 落下中にふちが持ち上がる高さ (m)  w 体のてっぺんからの落下高さ (m、0=着地)
//   このとき _DrapeCenter.xz が体の軸、_DrapeUp.xyz が網の向き（水平の基準軸）
float4 _DrapeFall;

bool SW_DrapeActive()
{
    return (_DrapeEnable > 0.5) && (_DrapeCount > 0.5) && (_DrapeCenter.w > 1e-4);
}

// 隣の頂点が手と腰など別の部位へ巻きつくと、三角形が翼のように長く引き伸ばされる。
// 本物の糸ならそこまで伸びると細く薄くなるため、元の網に対する伸び率で透明にする。
// フラグメント専用。巻きつき変形が無効、または螺旋巻きが 0 のときは元の不透明度を保つ。
float SW_DrapeStretchFade(float3 worldPos, float2 uv)
{
    if (!SW_DrapeActive() || _DrapeTurns <= 0.001) return 1.0;

    // 平らな網の位置もメートルにそろえ、画面の横・縦それぞれの長さの変化を比べる。
    float2 netPos = (uv - 0.5) * 2.0 * _DrapeCenter.w;
    float3 worldDx = ddx(worldPos);
    float3 worldDy = ddy(worldPos);
    float2 netDx = ddx(netPos);
    float2 netDy = ddy(netPos);
    // 元の長さがほぼ 0 のときも割り算が壊れないよう、長さの二乗に下限を設ける。
    float stretchX2 = dot(worldDx, worldDx) / max(dot(netDx, netDx), 1e-12);
    float stretchY2 = dot(worldDy, worldDy) / max(dot(netDy, netDy), 1e-12);
    float stretch = sqrt(max(stretchX2, stretchY2));
    return 1.0 - smoothstep(_DrapeStretchFade, _DrapeStretchFade * 2.0, stretch);
}

// 光線（原点 ro・単位方向 rd）とカプセル（端点 pa, pb・半径 ra）の最初の交点までの距離。
// 当たらなければ -1。円柱部分を解いて、外れたら端の球を解く（iq の公式）。
float SW_CapsuleHit(float3 ro, float3 rd, float3 pa, float3 pb, float ra)
{
    float3 ba = pb - pa;
    float3 oa = ro - pa;
    float baba = dot(ba, ba);
    float bard = dot(ba, rd);
    float baoa = dot(ba, oa);
    float a = baba - bard * bard;
    float3 oc;
    if (a > 1e-8)
    {
        float b = baba * dot(rd, oa) - baoa * bard;
        float c = baba * dot(oa, oa) - baoa * baoa - ra * ra * baba;
        float h = b * b - a * c;
        if (h < 0.0) return -1.0;                   // 無限円柱に当たらない＝カプセルにも当たらない
        float t = (-b - sqrt(h)) / a;
        float y = baoa + t * bard;
        if (y > 0.0 && y < baba) return t;          // 円柱の側面
        oc = (y <= 0.0) ? oa : ro - pb;             // はみ出した側の端の球
    }
    else
    {
        // 光線と線分が平行（または長さ 0 の球）: 光線が先に通る側の端の球
        oc = (bard >= 0.0) ? oa : ro - pb;
    }
    float bb = dot(rd, oc);
    float cc = dot(oc, oc) - ra * ra;
    float hh = bb * bb - cc;
    if (hh < 0.0) return -1.0;
    return -bb - sqrt(hh);
}

// 円盤上の 2D 位置 q の網の、変形後のワールド位置。
// C 中心, X/Y 円盤の右・上, D 飛んできた方向（X×Y=D）
float3 SW_DrapePoint(float2 q, float3 C, float3 X, float3 Y, float3 D, bool follow, out float sag, float extraGap)
{
    sag = 0.0;                                      // 追従時だけ、重力のたるみを後段へ渡す
    float  far  = _DrapeCenter.w + 2.0;             // 光線は円盤の十分手前から撃つ
    float3 ro   = C + X * q.x + Y * q.y - D * far;
    float  k    = max(_DrapeSmooth, 1e-3);
    // smooth-min の途中値（log-sum-exp をオンラインで更新）
    float  dMin = 1e6, dSum = 0.0;                   // 深さ
    float  oMin = 1e6, oSum = 0.0;                   // どの部位に巻きつくかの重み
    float2 shift = 0.0;                              // 巻き込みによる横ずれ（重み付き）
    float  looseSum = 0.0;                           // 輪郭の外に余った長さ（重み付き）
    float3 wrapSum = 0.0;                            // 螺旋巻きのワールド位置（同じ部位の重み付き）
    float  wrapW = 0.0;                              // その重みの合計（部位の選び方を鋭くした別の重み）
    float  kW = k * 0.3;                             // 巻きつく部位を 1 つに決める鋭さ（平均すると部位間に膜が張る）
    int n = clamp((int)_DrapeCount, 0, SW_DRAPE_MAX);
    [loop]
    for (int i = 0; i < n; i++)
    {
        float4 A = _DrapeCapA[i];
        float3 a = A.xyz - C, b = _DrapeCapB[i].xyz - C;
        float  r = A.w + (_DrapeGap + extraGap);
        // 円盤の平面へ投影した 2D の線分と、その上で q に一番近い点
        float2 a2 = float2(dot(a, X), dot(a, Y));
        float2 b2 = float2(dot(b, X), dot(b, Y));
        float2 ab = b2 - a2;
        float  u  = saturate(dot(q - a2, ab) / max(dot(ab, ab), 1e-8));
        float2 d2 = q - (a2 + ab * u);
        float  rho = length(d2);
        float2 outward = (rho > 1e-5) ? d2 / rho : float2(0.0, 1.0);
        float  outside = rho - r;                   // 負なら光線がこのカプセルに当たる
        float  za = dot(lerp(a, b, u), D);          // 中心線の深さ
        float  depth;
        float2 shiftI = 0.0;
        if (outside <= 0.0)
        {
            float t = SW_CapsuleHit(ro, D, A.xyz, _DrapeCapB[i].xyz, r);
            depth = (t > 0.0) ? t - far : za - sqrt(max(r * r - rho * rho, 0.0));
        }
        else
        {
            // 輪郭の外: はみ出した長さ L だけ、断面の円に沿って背中側へ回り込む
            // （弧の長さ = L）。4 分の 1 周で真後ろに着き、残りは後ろへ伸びる余り。
            float arc = r * 1.5707963;
            float th  = min(outside, arc) / max(r, 1e-4);
            float lam = (outside < arc) ? r * cos(th) : 0.0;          // 中心線からの横距離
            depth  = za + ((outside < arc) ? r * sin(th) : r + (outside - arc) * _DrapeTail);
            shiftI = -outward * (rho - lam);                          // 中心線側へ寄せる量
        }
        // 深さの smooth-min（一番手前の面が勝つ・部位間はなめらかに橋渡し）
        if (depth < dMin) { dSum = dSum * exp((depth - dMin) / k) + 1.0; dMin = depth; }
        else dSum += exp((dMin - depth) / k);
        // どの部位に巻きつくか: はみ出しが小さい部位ほど重い（smooth-min の重み）。
        // 上下方向のはみ出しは _DrapeCling 倍に数えるので、網の各段は「同じ高さの部位」
        // （膝の横なら上の手ではなく脚）に巻きつき、体の形が浮き出る。
        // 輪郭上（outside=0）では倍率に関係なく 0 なので、重みは輪郭をまたいでも連続。
        float stretch = length(float2(d2.x, d2.y * max(_DrapeCling, 1.0))) / max(rho, 1e-5);
        float oW = (outside > 0.0) ? outside * stretch : outside;
        float w;
        if (oW < oMin)
        {
            float s = exp((oW - oMin) / k);
            oSum *= s; shift *= s; looseSum *= s;
            float sW = exp((oW - oMin) / kW);
            wrapSum *= sW; wrapW *= sW;
            oMin = oW; w = 1.0;
        }
        else w = exp((oMin - oW) / k);
        float wW = (oW <= oMin) ? 1.0 : exp((oMin - oW) / kW);
        oSum += w; shift += shiftI * w; looseSum += max(outside, 0.0) * w;
        UNITY_BRANCH
        if (_DrapeTurns > 0.001)
        {
            float3 wrapI;
            if (outside <= 0.0)
            {
                // 当たった頂点は、この部位の手前の面へ置く（depth は深さを合成する前の値）。
                wrapI = C + X * q.x + Y * q.y + D * depth;
            }
            else
            {
                float3 cen = C + lerp(a, b, u);
                float3 o3 = normalize(X * outward.x + Y * outward.y);
                float3 bk = D - o3 * dot(D, o3);
                bk = (length(bk) > 1e-4) ? normalize(bk) : normalize(cross(o3, X));
                // 輪郭を出た長さを角度に変える。1 周ごとに外へ重ね、周回数を超えた余りはふくらみにする。
                float theta = outside / max(r, 1e-4);
                float thetaMax = 6.2831853 * _DrapeTurns;
                float th = min(theta, thetaMax);
                float R = r + _DrapeLayer * th / 6.2831853 + _DrapeBunch * max(theta - thetaMax, 0.0) * r;
                wrapI = cen + o3 * (R * cos(th)) + bk * (R * sin(th));
            }
            wrapSum += wrapI * wW; wrapW += wW;
        }
    }
    float depth = dMin - k * log(max(dSum, 1e-6));
    float loose = (oSum > 0.0) ? looseSum / oSum : 0.0;         // 体の輪郭の外に余った長さ
    // 背中側への巻き込み（0 なら横へは寄らず、輪郭から真後ろへ落ちる）
    float2 qW = q + ((oSum > 0.0) ? shift / oSum : 0.0) * saturate(_DrapeWrap);
    float3 p = C + X * qW.x + Y * qW.y + D * depth;
    // 余りは重力で垂れる（着弾直後はたるみが揺れる）
    UNITY_BRANCH
    if (follow) sag = _DrapeSag * _DrapeUp.w * loose * loose;
    else p.y -= _DrapeSag * _DrapeUp.w * loose * loose;
    UNITY_BRANCH
    if (_DrapeTurns > 0.001)
    {
        // 輪郭から 4cm の間で螺旋巻きへなじませる。重力のたるみは従来の位置 p だけに掛ける。
        float3 pWrap = (wrapW > 0.0) ? wrapSum / wrapW : p;
        float t = smoothstep(0.0, 0.04, loose) * saturate(_DrapeTurns * 4.0);
        p = lerp(p, pWrap, t);
        if (follow) sag *= 1.0 - t;                  // 螺旋側にはたるみを掛けない
    }
    // 垂れた余りは床にめり込ませない（床の平面の上へ押し戻す。引きずられている間も床に沿う）
    if (!follow && dot(_DrapeFloor.xyz, _DrapeFloor.xyz) > 0.5)
        p += _DrapeFloor.xyz * max(0.01 - (dot(_DrapeFloor.xyz, p) + (_DrapeFloor.w - extraGap)), 0.0);
    return p;
}

// 線分上で p に最も近い位置。長さ 0 のカプセルも端点の球として扱う。
float3 SW_DrapeClosest(float3 p, float3 a, float3 b)
{
    float3 ab = b - a;
    return a + ab * saturate(dot(p - a, ab) / max(dot(ab, ab), 1e-8));
}

// 軸 axis（単位ベクトル）まわりに角度 angle だけ v を回す（ロドリゲスの回転公式）
float3 SW_DrapeRotate(float3 v, float3 axis, float angle)
{
    float s = sin(angle), c = cos(angle);
    return v * c + cross(axis, v) * s + axis * dot(axis, v) * (1.0 - c);
}

// 基準の体表面までの距離で重みを決め、近くの部位の剛体変換を混ぜる。
// 体から離れた余り（垂れた裾など）は、体が傾いた分だけ支点（裾の付け根にあたる
// 体の表面の点）から真下へ垂らす。立ったままなら着弾時の形のまま、
// 横向きに寝ても裾が上へ立たずに地面の方へ垂れる。
float3 SW_DrapeSkin(float3 restPoint, float extraGap)
{
    int n = clamp((int)_DrapeCount, 0, SW_DRAPE_MAX);
    if (n == 0) return restPoint;
    float dMin = 1e6;
    float k = max(_DrapeFollowBlend, 1e-3);
    float3 sum = 0.0;
    float weightSum = 0.0;
    float3 anchorSum = 0.0;                         // 体の表面の支点（重み付き）
    float3 rowX = 0.0, rowY = 0.0, rowZ = 0.0;      // 混ぜた回転（3x3 の各行、重み付き）
    [loop]
    for (int j = 0; j < n; j++)
    {
        float3 c = SW_DrapeClosest(restPoint, _DrapeCapA[j].xyz, _DrapeCapB[j].xyz);
        float3 e = restPoint - c;
        float len = length(e);
        float d = len - _DrapeCapA[j].w;
        // 最短距離が更新されたら既存の和を同じ比率で縮める。距離を二度走査しない。
        float w;
        if (d < dMin)
        {
            float rescale = exp((d - dMin) / k);
            sum *= rescale; weightSum *= rescale; anchorSum *= rescale;
            rowX *= rescale; rowY *= rescale; rowZ *= rescale;
            dMin = d; w = 1.0;
        }
        else w = exp((dMin - d) / k);
        float3 moved = float3(dot(_DrapeSkinX[j].xyz, restPoint) + _DrapeSkinX[j].w,
                              dot(_DrapeSkinY[j].xyz, restPoint) + _DrapeSkinY[j].w,
                              dot(_DrapeSkinZ[j].xyz, restPoint) + _DrapeSkinZ[j].w);
        sum += w * moved;
        weightSum += w;
        anchorSum += w * (c + e / max(len, 1e-5) * (_DrapeCapA[j].w + (_DrapeGap + extraGap)));
        rowX += w * _DrapeSkinX[j].xyz;
        rowY += w * _DrapeSkinY[j].xyz;
        rowZ += w * _DrapeSkinZ[j].xyz;
    }
    // 最も近い部位の重みは必ず 1 なので weightSum >= 1
    float3 skinned = sum / weightSum;

    // 混合行列は剛体回転ではなく、上方向が相殺されて長さ 0 にもなる。
    // 正規化せず各回転の傾きの cos を平均する。相殺点でも連続で、単独の回転は従来と同じ。
    rowX /= weightSum; rowY /= weightSum; rowZ /= weightSum;
    float tilt = saturate(acos(clamp(rowY.y, -1.0, 1.0)) / 1.5707963);
    // 体からどれだけ離れているか（基準姿勢）と体の傾きで、重力で垂らす割合を決める
    float hang = saturate(_DrapeFollowHang) * tilt
               * smoothstep(0.0, max(_DrapeFollowHangDist, 1e-3), max(dMin, 0.0));
    UNITY_BRANCH
    if (hang > 0.0)
    {
        float3 rel = restPoint - anchorSum / weightSum;
        // 支点（体の表面）から見た余りの向き（体と一緒に回った後）。アフィン変換なので
        // 支点の移動先 = skinned - 回転×rel になる
        float3 arm = float3(dot(rowX, rel), dot(rowY, rel), dot(rowZ, rel));
        float3 pivot = skinned - arm;
        // 余りを支点から真下へ向ける回転（通常は長さを保つ）。体を通り抜けた所は後の押し戻しで体に沿う
        float lenArm = length(arm);
        float3 u = (lenArm > 1e-5) ? arm / max(lenArm, 1e-5) : float3(0.0, -1.0, 0.0);
        float3 down = float3(0.0, -1.0, 0.0);
        float3 axis = cross(u, down);
        float s = length(axis);
        float cs = dot(u, down);
        float angle = atan2(s, cs) * hang;
        axis /= max(s, 1e-5);
        float3 swung = SW_DrapeRotate(arm, axis, angle);
        // 真上では最短回転の軸が左右で反転する。約 6 度の範囲だけ直線補間へ連続的に
        // なじませ、隣接点や差分法線が飛ばないようにする（この範囲では腕の短縮を許す）。
        float pole = cs < 0.0 ? smoothstep(0.0, 0.01, s * s) : 1.0;
        skinned = pivot + lerp(lerp(arm, down * lenArm, hang), swung, pole);
    }
    return skinned;
}

// 関節を曲げて混合位置が体に入った所を、現在のカプセルから順番に押し出す。
float3 SW_DrapePush(float3 p, float extraGap)
{
    int n = clamp((int)_DrapeCount, 0, SW_DRAPE_MAX);
    [loop]
    for (int i = 0; i < n; i++)
    {
        float3 a = _DrapeCurA[i].xyz, b = _DrapeCurB[i].xyz;
        float3 c = SW_DrapeClosest(p, a, b);
        float3 v = p - c;
        float dist = length(v);
        float rr = _DrapeCurA[i].w + (_DrapeGap + extraGap) * 0.6;
        if (dist < rr)
        {
            float3 outward;
            if (dist > 1e-5) outward = v / dist;
            else
            {
                // 中心線上では線分と直交する向き。縦の線分や長さ 0 の球にも備える。
                float3 perpendicular = cross(b - a, float3(0.0, 1.0, 0.0));
                if (dot(perpendicular, perpendicular) < 1e-10)
                    perpendicular = cross(b - a, float3(1.0, 0.0, 0.0));
                outward = dot(perpendicular, perpendicular) > 1e-10
                    ? normalize(perpendicular) : float3(1.0, 0.0, 0.0);
            }
            p += outward * (rr - dist) * saturate(_DrapeFollowPush);
        }
    }
    return p;
}

// かぶさり具合 _DrapeDir.w で「体の手前の平らな円盤」→「体に沿った形」へ補間。
// 中心と差分用の隣接点をすべて同じ最終位置まで計算し、法線・接線に反映する。
float3 SW_DrapeBlend(float2 q, float3 C, float3 X, float3 Y, float3 D, float extraGap)
{
    float  amount = saturate(_DrapeDir.w);
    float3 flat   = C + X * q.x + Y * q.y - D * (0.45 * _DrapeCenter.w + extraGap);
    float sag = 0.0;
    float3 result = flat;
    UNITY_BRANCH
    if (_DrapeFollow > 0.5)
    {
        float3 restPoint = lerp(flat, SW_DrapePoint(q, C, X, Y, D, true, sag, extraGap), amount);
        sag *= amount;                             // 平らな網にはたるみがない
        float3 p = SW_DrapeSkin(restPoint, extraGap);
        p.y -= sag;                                // 姿勢が寝ても重力はワールドの下方向
        p = SW_DrapePush(p, extraGap);
        if (dot(_DrapeFloor.xyz, _DrapeFloor.xyz) > 0.5)
            p += _DrapeFloor.xyz * max(0.01 - (dot(_DrapeFloor.xyz, p) + (_DrapeFloor.w - extraGap)), 0.0);
        result = p;
    }
    else
    {
        // 従来は点の中でたるみ・螺旋・床を計算してから平らな網と混ぜる。順番を変えない。
        result = lerp(flat, SW_DrapePoint(q, C, X, Y, D, false, sag, extraGap), amount);
    }
    return result;
}

// ---- 上から降ってきた網（_DrapeFall） ----
#define SW_FALL_STEPS  20      // 頭のてっぺんから床までの断面をたどる段数（上ほど細かい）
#define SW_FALL_PLEAT  0.12    // 余った輪の長さ 1m あたりの縦ひだの深さ (m)
#define SW_FALL_SPREAD 1.2     // かぶさりが中心からふちへ伝わる遅れ

// 断面上の 1 点 S（半径 r の球）が高さ y で向き d0 / d1 へどこまで張り出すか
void SW_FallSample(float3 S, float r, float y, float2 O, float2 d0, float2 d1, inout float2 s)
{
    float v = r * r - (y - S.y) * (y - S.y);
    if (v > 0.0)
    {
        float2 o = S.xz - O;
        s = max(s, float2(dot(o, d0), dot(o, d1)) + sqrt(v));
    }
}

// 高さ y の体の水平断面が、軸 O から向き d0 / d1 へどこまで張り出しているか。
// 部位ごとの値を smooth-max（log-sum-exp）でなめらかにまとめる。何もない高さは -1e5。
float2 SW_FallExtent(float y, float2 O, float2 d0, float2 d1, int n, float k, float extraGap)
{
    float2 m = -1e5, sum = 0.0;
    [loop]
    for (int i = 0; i < n; i++)
    {
        float3 A = _DrapeCapA[i].xyz, B = _DrapeCapB[i].xyz;
        float  r = _DrapeCapA[i].w + (_DrapeGap + extraGap);
        float  dy = B.y - A.y;
        // 線分上でその高さの点と両端の球。斜めの部位も、横向きの線分（肩・腰）も拾える
        float3 P = lerp(A, B, abs(dy) > 1e-4 ? saturate((y - A.y) / dy) : 0.0);
        float2 s = -1e5;
        SW_FallSample(P, r, y, O, d0, d1, s);
        SW_FallSample(A, r, y, O, d0, d1, s);
        SW_FallSample(B, r, y, O, d0, d1, s);
        if (s.x > -1e4)
        {
            if (s.x > m.x) { sum.x = sum.x * exp((m.x - s.x) / k) + 1.0; m.x = s.x; }
            else sum.x += exp((s.x - m.x) / k);
        }
        if (s.y > -1e4)
        {
            if (s.y > m.y) { sum.y = sum.y * exp((m.y - s.y) / k) + 1.0; m.y = s.y; }
            else sum.y += exp((s.y - m.y) / k);
        }
    }
    return float2(sum.x > 0.0 ? m.x + k * log(sum.x) : -1e5,
                  sum.y > 0.0 ? m.y + k * log(sum.y) : -1e5);
}

// 縦ひだの深さの割合 0..1（整数周波数なので一周でつながる）
float SW_FallFold(float phi)
{
    return 0.5 + 0.3 * cos(5.0 * phi + 1.3) + 0.2 * cos(8.0 * phi + 4.1);
}

void SW_DrapeFallDeform(float2 uv, out float3 p, out float3 N, out float3 T, float extraGap)
{
    float  R  = max(_DrapeCenter.w, 1e-3);
    float2 O  = _DrapeCenter.xz;                       // 体の軸
    float3 up = float3(0.0, 1.0, 0.0);
    float3 X  = float3(_DrapeUp.x, 0.0, _DrapeUp.z);
    X = dot(X, X) > 1e-6 ? normalize(X) : float3(1.0, 0.0, 0.0);
    float3 Y  = float3(-X.z, 0.0, X.x);                 // X×Y = 下向き（従来の D と同じ約束）
    float2 q   = (uv - 0.5) * 2.0 * R;
    float  rho = max(length(q), 1e-3);
    float  phi = atan2(q.y, q.x);
    const float dphi = 0.03;                            // 周方向の接線を差分で求める幅 (rad)
    float3 w0 = X * cos(phi) + Y * sin(phi);
    float3 w1 = X * cos(phi + dphi) + Y * sin(phi + dphi);
    int    n  = clamp((int)_DrapeCount, 0, SW_DRAPE_MAX);
    float  k  = max(_DrapeSmooth * 0.5, 1e-3);

    // 体のてっぺんと床
    float top = -1e5, low = 1e5;
    [loop]
    for (int i = 0; i < n; i++)
    {
        float r = _DrapeCapA[i].w + (_DrapeGap + extraGap);
        top = max(top, max(_DrapeCapA[i].y, _DrapeCapB[i].y) + r);
        low = min(low, min(_DrapeCapA[i].y, _DrapeCapB[i].y) - r);
    }
    bool  hasFloor = _DrapeFloor.y > 0.5;
    float floorY = hasFloor ? -(_DrapeFloor.w - extraGap) / _DrapeFloor.y : low - 0.6;
    floorY = min(floorY, top - 0.05);
    float span = top - floorY;
    float hang = saturate(_DrapeFall.y);

    // 頭のてっぺんから断面の線をたどり、弧長が rho になる所を探す（向き φ と φ+dphi を同時に）
    float2 prev0 = float2(0.0, top), prev1 = prev0;
    float2 at0 = prev0, at1 = prev1, slope0 = float2(1.0, 0.0);
    float  s0 = 0.0, s1 = 0.0, rmax0 = 0.0, rmax1 = 0.0;
    bool   done0 = false, done1 = false;
    [loop]
    for (int j = 1; j <= SW_FALL_STEPS; j++)
    {
        float  y = top - span * pow(j / (float)SW_FALL_STEPS, 1.6);
        float2 e = SW_FallExtent(y, O, w0.xz, w1.xz, n, k, extraGap);
        // 何もない高さ（足より下）は一つ上の広さのまま真下へ
        float2 cling = max(float2(e.x > -1e4 ? e.x : prev0.x, e.y > -1e4 ? e.y : prev1.x), 0.02);
        rmax0 = max(rmax0, cling.x); rmax1 = max(rmax1, cling.y);
        float2 c0 = float2(lerp(cling.x, rmax0, hang), y);
        float2 c1 = float2(lerp(cling.y, rmax1, hang), y);
        float2 g0 = c0 - prev0, g1 = c1 - prev1;
        float  l0 = max(length(g0), 1e-5), l1 = max(length(g1), 1e-5);
        if (!done0 && s0 + l0 >= rho) { at0 = prev0 + g0 * ((rho - s0) / l0); slope0 = g0 / l0; done0 = true; }
        if (!done1 && s1 + l1 >= rho) { at1 = prev1 + g1 * ((rho - s1) / l1); done1 = true; }
        s0 += l0; s1 += l1; prev0 = c0; prev1 = c1;
        if (done0 && done1) break;
    }
    // 網が体より長い: 余りは床の上へ外向きに広がる（床が無ければそのまま垂れる）
    if (!done0)
    {
        at0 = hasFloor ? float2(prev0.x + rho - s0, floorY + 0.01) : float2(prev0.x, prev0.y - (rho - s0));
        slope0 = hasFloor ? float2(1.0, 0.0) : float2(0.0, -1.0);
    }
    if (!done1) at1 = hasFloor ? float2(prev1.x + rho - s1, floorY + 0.01) : float2(prev1.x, prev1.y - (rho - s1));

    // 輪の長さが体の周りより余った分は縦のひだになる（外へだけふくらむ）
    float  fold0 = SW_FallFold(phi), fold1 = SW_FallFold(phi + dphi);
    float  pleat0 = SW_FALL_PLEAT * max(rho - at0.x, 0.0) * fold0;
    float  pleat1 = SW_FALL_PLEAT * max(rho - at1.x, 0.0) * fold1;
    float  u = rho / R;
    // 着地直後はすその垂れが揺れる
    float  bounce = (_DrapeUp.w - 1.0) * 0.15 * u * u;
    float3 base = float3(O.x, 0.0, O.y);
    float3 drape0 = base + w0 * (at0.x + pleat0) + up * (at0.y - bounce);
    float3 drape1 = base + w1 * (at1.x + pleat1) + up * (at1.y - bounce);

    // 落下中の平らな網: 体のてっぺんから _DrapeFall.w 上。ふちは空気で持ち上がって波打つ
    float fallH = max(_DrapeFall.w, 0.0);
    float lift  = _DrapeFall.z * u * u + 0.04 * u * sin(3.0 * phi + _Time.y * 4.0 + u * 5.0);
    float flatY = top + fallH + lift;

    // かぶさり具合: 中心から順に。ふちは先に下へ落ち（高さ）、あとから体へ寄る（水平）
    float a  = saturate(_DrapeDir.w * (1.0 + SW_FALL_SPREAD) - SW_FALL_SPREAD * u);
    float ay = a * (2.0 - a);
    float ar = a * a;
    float3 drapeH = drape0 - base; drapeH.y = 0.0;
    p = base + lerp(w0 * rho, drapeH, ar) + up * lerp(flatY, drape0.y, ay);
    if (hasFloor) p.y = max(p.y, floorY + 0.01);

    // 法線・接線: 断面の線の向き（ρ 方向）と隣の向き（φ 方向）から UV の x/y 方向の変化を組み立てる
    float  dPleat = SW_FALL_PLEAT * fold0 * (1.0 - slope0.x);
    float3 dRho = w0 * (slope0.x + dPleat) + up * slope0.y;
    float3 dPhi = (drape1 - drape0) / dphi;
    float2 qn = q / rho;
    float3 dX = dRho * qn.x - dPhi * (qn.y / rho);
    float3 dY = dRho * qn.y + dPhi * (qn.x / rho);
    dX = lerp(X, dX, a);
    dY = lerp(Y, dY, a);
    float3 nn = -cross(dX, dY);                         // 平らなときは上向き（落ちてくる側）
    N = dot(nn, nn) > 1e-12 ? normalize(nn) : up;
    T = dot(dX, dX) > 1e-12 ? normalize(dX) : X;
}

// 横から投げつけた網（従来の光線モデル）
void SW_DrapeThrownDeform(float2 uv, out float3 p, out float3 N, out float3 T, float extraGap)
{
    float3 C = _DrapeCenter.xyz;
    float3 D = normalize(_DrapeDir.xyz);
    float3 up = _DrapeUp.xyz;
    if (abs(dot(normalize(up + 1e-6), D)) > 0.98) up = abs(D.y) < 0.9 ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 X = normalize(cross(up, D));
    float3 Y = cross(D, X);                             // X×Y = D（円盤の表は -D 側）
    float2 q = (uv - 0.5) * 2.0 * _DrapeCenter.w;
    float  e = max(_DrapeCenter.w * 0.012, 0.004);
    p = SW_DrapeBlend(q, C, X, Y, D, extraGap);
    float3 dT = SW_DrapeBlend(q + float2(e, 0.0), C, X, Y, D, extraGap) - SW_DrapeBlend(q - float2(e, 0.0), C, X, Y, D, extraGap);
    float3 dB = SW_DrapeBlend(q + float2(0.0, e), C, X, Y, D, extraGap) - SW_DrapeBlend(q - float2(0.0, e), C, X, Y, D, extraGap);
    float3 nn = -cross(dT, dB);                         // 平らなときは -D（投げた側を向く）
    N = dot(nn, nn) > 1e-12 ? normalize(nn) : -D;
    T = dot(dT, dT) > 1e-12 ? normalize(dT) : X;
}

// extraGap: この頂点の追加の浮き (m)。カプセルの半径・追従の支点・押し戻しに伝播する。
// 床は CaptureNetDrape の floor.w -= shell と同じだけ外へ移す。
// 差分法線の近傍点にも同じ extraGap を使う（UVによる間隔の勾配は近似）。
// uv: 網の UV（0..1、中心 0.5 が網の中心）。位置・法線・接線をワールドで返す
void SW_DrapeDeform(float2 uv, out float3 p, out float3 N, out float3 T, float extraGap)
{
    UNITY_BRANCH
    if (_DrapeFall.x > 0.5) SW_DrapeFallDeform(uv, p, N, T, extraGap);
    else SW_DrapeThrownDeform(uv, p, N, T, extraGap);
}

// 従来シェーダーの入口は保持する。追加の浮きが0なら従来の式に戻る。
void SW_DrapeDeform(float2 uv, out float3 p, out float3 N, out float3 T)
{
    SW_DrapeDeform(uv, p, N, T, 0.0);
}

#endif // SPIDERWEB_DRAPE_INCLUDED
