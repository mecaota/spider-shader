using System;
using UnityEditor;
using UnityEngine;

/// <summary>
/// 段階3のミップと圧縮。被覆率は浮動小数点で面積平均してから各レベルをR8へ量子化する。
/// 形状の平均距離だけで遠景を判定しないため、被覆率は形状と別に保持する。
/// </summary>
internal static class SpiderGooSheetTextureUtility
{
    internal sealed class Mip
    {
        internal int Size;
        internal Color[] Shape;
        internal Color[] Detail;
        internal float[] Coverage;
    }

    internal static long TextureBytes(int resolution, int variants, bool compressed)
    {
        long bytes = 0;
        for (int side = resolution; side > 0; side >>= 1)
        {
            long pixels = (long)side * side;
            // BC5/BC7はどちらも4x4ごとに16bytes。1x1・2x2 mipにも1ブロックが必要。
            long shapeAndDetail = compressed ? (long)((side + 3) / 4) * ((side + 3) / 4) * 32 : pixels * 8;
            bytes += shapeAndDetail + pixels; // 被覆率はR8
        }
        return bytes * variants;
    }

    internal static Mip Downsample(Mip source)
    {
        int size = source.Size / 2;
        var result = new Mip { Size = size, Shape = new Color[size * size], Detail = new Color[size * size], Coverage = new float[size * size] };
        for (int y = 0; y < size; y++)
        for (int x = 0; x < size; x++)
        {
            float coverage = 0f, distance = 0f, radius = 0f, fallbackRadius = 0f;
            Color attributes = Color.clear;
            for (int oy = 0; oy < 2; oy++)
            for (int ox = 0; ox < 2; ox++)
            {
                int index = (y * 2 + oy) * source.Size + x * 2 + ox;
                float weight = source.Coverage[index];
                coverage += weight;
                distance += source.Shape[index].r;
                radius += source.Shape[index].g * weight;
                fallbackRadius += source.Shape[index].g;
                attributes += source.Detail[index] * weight;
            }
            int target = y * size + x;
            result.Coverage[target] = coverage * 0.25f;
            result.Shape[target] = new Color(distance * 0.25f,
                coverage > 1e-8f ? radius / coverage : fallbackRadius * 0.25f, 0f, 1f);
            // 空隙の向き/光沢を混ぜない。向きの正規化は読取側で行う。
            result.Detail[target] = coverage > 1e-8f ? attributes / coverage : new Color(0.5f, 0.5f, 0f, 0f);
        }
        return result;
    }

    internal static void WriteSlice(Texture2DArray shape, Texture2DArray detail, Texture2DArray coverage,
        Mip mip, int slice, float uvSpan, bool compressed, out float distanceRange, out float radiusRange)
    {
        float maximumRadius = 0.0001f;
        foreach (Color pixel in mip.Shape) maximumRadius = Mathf.Max(maximumRadius, pixel.g);
        // 近景で必要な断面全体を含み、輪郭付近へ8bitを割り当てる。遠い正距離は飽和してよい。
        distanceRange = Mathf.Max(16f * uvSpan / mip.Size, maximumRadius * 1.25f);
        radiusRange = maximumRadius * 1.01f;
        Texture2D encodedShape = null, encodedDetail = null;
        try
        {
            if (compressed)
            {
                encodedShape = new Texture2D(mip.Size, mip.Size, TextureFormat.RGBA32, true, true);
                encodedDetail = new Texture2D(mip.Size, mip.Size, TextureFormat.RGBA32, true, true);
            }
            int level = 0;
            while (true)
            {
                var mask = new byte[mip.Coverage.Length];
                for (int i = 0; i < mask.Length; i++) mask[i] = (byte)Mathf.RoundToInt(Mathf.Clamp01(mip.Coverage[i]) * 255f);
                coverage.SetPixelData(mask, level, slice);
                if (compressed)
                {
                    var data = new Color32[mip.Shape.Length];
                    var attributes = new Color32[mip.Detail.Length];
                    for (int i = 0; i < data.Length; i++)
                    {
                        data[i] = new Color(Mathf.Clamp01(mip.Shape[i].r / distanceRange * 0.5f + 0.5f),
                            Mathf.Clamp01(mip.Shape[i].g / radiusRange), 0f, 1f);
                        attributes[i] = mip.Detail[i];
                    }
                    encodedShape.SetPixelData(data, level);
                    encodedDetail.SetPixelData(attributes, level);
                }
                else
                {
                    var data = new ushort[mip.Shape.Length * 2];
                    var attributes = new Color32[mip.Detail.Length];
                    for (int i = 0; i < mip.Shape.Length; i++)
                    {
                        data[i * 2] = Mathf.FloatToHalf(Mathf.Clamp(mip.Shape[i].r, -65504f, 65504f));
                        data[i * 2 + 1] = Mathf.FloatToHalf(Mathf.Clamp(mip.Shape[i].g, 0.0001f, 65504f));
                        attributes[i] = mip.Detail[i];
                    }
                    shape.SetPixelData(data, level, slice);
                    detail.SetPixelData(attributes, level, slice);
                }
                if (mip.Size == 1) break;
                mip = Downsample(mip);
                level++;
            }
            if (compressed)
            {
                encodedShape.Apply(false, false);
                encodedDetail.Apply(false, false);
                EditorUtility.CompressTexture(encodedShape, TextureFormat.BC5, TextureCompressionQuality.Best);
                EditorUtility.CompressTexture(encodedDetail, TextureFormat.BC7, TextureCompressionQuality.Best);
                if (encodedShape.format != TextureFormat.BC5 || encodedDetail.format != TextureFormat.BC7)
                    throw new InvalidOperationException("BC5/BC7圧縮に失敗しました。無圧縮を選ぶか、Editorの対応形式を確認してください。");
                // GPUだけのCopyTextureではなくCPUデータを配列へ入れ、.assetへ確実に保存する。
                for (int i = 0; i < shape.mipmapCount; i++)
                {
                    shape.SetPixelData(encodedShape.GetPixelData<byte>(i), i, slice);
                    detail.SetPixelData(encodedDetail.GetPixelData<byte>(i), i, slice);
                }
            }
        }
        finally
        {
            if (encodedShape != null) UnityEngine.Object.DestroyImmediate(encodedShape);
            if (encodedDetail != null) UnityEngine.Object.DestroyImmediate(encodedDetail);
        }
    }
}
