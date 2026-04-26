Shader "Hidden/Roystan/Outline Post Process"
{
    SubShader
    {
        Cull Off ZWrite Off ZTest Always

        Pass
        {
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            #include "Packages/com.unity.postprocessing/PostProcessing/Shaders/StdLib.hlsl"

            TEXTURE2D_SAMPLER2D(_MainTex, sampler_MainTex);
            TEXTURE2D_SAMPLER2D(_CameraNormalsTexture, sampler_CameraNormalsTexture);
            TEXTURE2D_SAMPLER2D(_CameraDepthTexture, sampler_CameraDepthTexture);

            float4 _MainTex_TexelSize;

            float _Scale;
            float _DepthThreshold;
            float _DepthNormalThreshold;
            float _DepthNormalThresholdScale;
            float _NormalThreshold;
            float _ColorTolerance;
            float _DepthContactThreshold;

            float4x4 _ClipToView;

            int _ColorCount;
            float4 _SurfaceColors[32];
            float4 _OutlineColors[32];

            // NOTE: Color matching is performed in the color space of _MainTex (typically gamma
            // in Unity's built-in pipeline). _SurfaceColors set via the inspector are also
            // gamma-encoded in that case, so matching is consistent. If you switch to a linear
            // color space pipeline, verify that both sides agree on encoding.
            int GetColorPriority(float3 pixel)
            {
                int bestIndex = -1;
                float bestDist = _ColorTolerance;
                // Clamped to 32 to guard against misconfigured _ColorCount exceeding the array size.
                int count = min(_ColorCount, 32);
                for (int i = 0; i < count; i++)
                {
                    float dist = length(pixel - _SurfaceColors[i].rgb);
                    if (dist < bestDist)
                    {
                        bestDist = dist;
                        bestIndex = i;
                    }
                }
                return bestIndex;
            }

            float4 alphaBlend(float4 top, float4 bottom)
            {
                float3 color = (top.rgb * top.a) + (bottom.rgb * (1 - top.a));
                float alpha = top.a + bottom.a * (1 - top.a);
                return float4(color, alpha);
            }

            struct Varyings
            {
                float4 vertex : SV_POSITION;
                float2 texcoord : TEXCOORD0;
                float2 texcoordStereo : TEXCOORD1;
                float3 viewSpaceDir : TEXCOORD2;
            #if STEREO_INSTANCING_ENABLED
                uint stereoTargetEyeIndex : SV_RenderTargetArrayIndex;
            #endif
            };

            Varyings Vert(AttributesDefault v)
            {
                Varyings o;
                o.vertex = float4(v.vertex.xy, 0.0, 1.0);
                o.texcoord = TransformTriangleVertexToUV(v.vertex.xy);
                o.viewSpaceDir = mul(_ClipToView, o.vertex).xyz;
            #if UNITY_UV_STARTS_AT_TOP
                o.texcoord = o.texcoord * float2(1.0, -1.0) + float2(0.0, 1.0);
            #endif
                o.texcoordStereo = TransformStereoScreenSpaceTex(o.texcoord, 1.0);
                return o;
            }

            float4 Frag(Varyings i) : SV_Target
            {
                // 8 evenly spaced directions around a circle (every 45 degrees).
                // Diagonal offsets are scaled by 1/sqrt(2) so all samples sit on
                // a true circle of radius _Scale pixels rather than a square.
                static const float DIAG = 0.70710678;
                static const float2 RING_DIRS[8] =
                {
                    float2( 1,     0    ),  // E
                    float2( DIAG,  DIAG ),  // NE
                    float2( 0,     1    ),  // N
                    float2(-DIAG,  DIAG ),  // NW
                    float2(-1,     0    ),  // W
                    float2(-DIAG, -DIAG ),  // SW
                    float2( 0,    -1    ),  // S
                    float2( DIAG, -DIAG ),  // SE
                };

                float2 texelRadius = _MainTex_TexelSize.xy * _Scale;

                // Sample the true center pixel for depth, normal, and color.
                float  centerDepth  = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_CameraDepthTexture, i.texcoord).r;
                float3 centerNormal = SAMPLE_TEXTURE2D(_CameraNormalsTexture, sampler_CameraNormalsTexture, i.texcoord).rgb;
                float4 centerColor  = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.texcoord);

                // Sample the 8 ring positions.
                float  ringDepth [8];
                float3 ringNormal[8];
                float4 ringColor [8];

                for (int s = 0; s < 8; s++)
                {
                    float2 uv = i.texcoord + RING_DIRS[s] * texelRadius;
                    ringDepth [s] = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_CameraDepthTexture, uv).r;
                    ringNormal[s] = SAMPLE_TEXTURE2D(_CameraNormalsTexture, sampler_CameraNormalsTexture, uv).rgb;
                    ringColor [s] = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv);
                }

                // --- Depth edge ---
                // Build the adaptive threshold from the center normal and view direction.
                // viewSpaceDir is interpolated across the triangle so it must be normalized.
                float3 viewNormal = centerNormal * 2 - 1;
                float NdotV = 1 - dot(viewNormal, -normalize(i.viewSpaceDir));
                // Guard against divide-by-zero when _DepthNormalThreshold is exactly 1.
                float depthNormalDenom = max(1 - _DepthNormalThreshold, 1e-5);
                float normalThreshold01 = saturate((NdotV - _DepthNormalThreshold) / depthNormalDenom);
                float normalThreshold   = normalThreshold01 * _DepthNormalThresholdScale + 1;
                float depthThreshold    = _DepthThreshold * centerDepth * normalThreshold;

                // Compare each ring sample against the true center and take the max difference.
                float maxDepthDiff = 0;
                for (int d = 0; d < 8; d++)
                    maxDepthDiff = max(maxDepthDiff, abs(ringDepth[d] - centerDepth));
                float edgeDepth = (maxDepthDiff * 100) > depthThreshold ? 1 : 0;

                // --- Normal edge ---
                // Normal differences are computed in [0,1] space; the *2-1 decode cancels out
                // in subtraction so this is equivalent to comparing in [-1,1] space.
                // Compare each ring sample against the true center and take the max difference.
                float maxNormalDiff = 0;
                for (int n = 0; n < 8; n++)
                {
                    float3 diff = ringNormal[n] - centerNormal;
                    maxNormalDiff = max(maxNormalDiff, dot(diff, diff));
                }
                float edgeNormal = sqrt(maxNormalDiff) > _NormalThreshold ? 1 : 0;

                // --- Color edge ---
                // Fires when any ring sample matches a different registered color than the center.
                // This catches edges like red vs blue that have similar luminance.
                int centerPriority = GetColorPriority(centerColor.rgb);
                int ringPriority[8];
                for (int c = 0; c < 8; c++)
                    ringPriority[c] = GetColorPriority(ringColor[c].rgb);

                float edgeColor = 0;
                for (int e = 0; e < 8; e++)
                {
                    if (ringPriority[e] != centerPriority)
                    {
                        edgeColor = 1;
                        break;
                    }
                }

                float edge = max(max(edgeDepth, edgeNormal), edgeColor);

                // ---------------------------------------------------------------
                // PRIORITY SELECTION
                //
                // Raw depth: higher value = closer to camera (reversed Z).
                // If depth spread exceeds _DepthContactThreshold = silhouette.
                // Silhouette: nearest sample (highest raw depth) wins outright.
                // Contact: lowest priority index across all samples wins.
                // ---------------------------------------------------------------

                float minDepth = centerDepth;
                float maxDepth = centerDepth;
                for (int md = 0; md < 8; md++)
                {
                    minDepth = min(minDepth, ringDepth[md]);
                    maxDepth = max(maxDepth, ringDepth[md]);
                }
                bool isSilhouette = (maxDepth - minDepth) > _DepthContactThreshold;

                int winnerIndex = -1;

                if (isSilhouette)
                {
                    // Highest raw depth value = nearest to camera.
                    // Start with the center as the initial nearest candidate.
                    float nearestDepth = centerDepth;
                    winnerIndex = centerPriority;
                    for (int si = 0; si < 8; si++)
                    {
                        if (ringDepth[si] > nearestDepth)
                        {
                            nearestDepth = ringDepth[si];
                            winnerIndex  = ringPriority[si];
                        }
                    }
                }
                else
                {
                    // Contact edge — lowest priority index wins.
                    if (centerPriority >= 0) winnerIndex = centerPriority;
                    for (int ci = 0; ci < 8; ci++)
                    {
                        if (ringPriority[ci] >= 0 && (winnerIndex < 0 || ringPriority[ci] < winnerIndex))
                            winnerIndex = ringPriority[ci];
                    }
                }

                if (winnerIndex < 0 || edge < 0.5)
                    return centerColor;

                float4 outlineColor = _OutlineColors[winnerIndex];
                return alphaBlend(outlineColor, centerColor);
            }
            ENDHLSL
        }
    }
}