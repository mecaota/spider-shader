// SurfaceContactDeformer の追従ボーン指定用 enum。
// UdonSharp では UnityEngine.HumanBodyBones の「配列」が Udon に露出しておらず
// コンパイルできないため、同じ整数値を持つ自作 enum を配列で使う
// （U# はユーザー定義 enum の配列を int[] として扱い、インスペクターは EnumPopup で描く）。
// 実行時は (HumanBodyBones)(int)bone でそのまま変換できる。
public enum TrackBone
{
    Hips = 0,
    LeftUpperLeg = 1,
    RightUpperLeg = 2,
    LeftLowerLeg = 3,
    RightLowerLeg = 4,
    LeftFoot = 5,
    RightFoot = 6,
    Spine = 7,
    Chest = 8,
    Neck = 9,
    Head = 10,
    LeftShoulder = 11,
    RightShoulder = 12,
    LeftUpperArm = 13,
    RightUpperArm = 14,
    LeftLowerArm = 15,
    RightLowerArm = 16,
    LeftHand = 17,
    RightHand = 18,
    LeftToes = 19,
    RightToes = 20,
    UpperChest = 54,
}

// 接触判定に使う面の形（オブジェクトのローカル空間）
public enum SurfaceShape
{
    Plane = 0,    // ローカル XZ 平面、法線 +Y（WebPlane メッシュ）
    Sphere = 1,   // 原点中心の球（標準 Sphere は半径 0.5）
    Cylinder = 2, // Y 軸の円柱（標準 Cylinder は半径 0.5・半高 1）
}
