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
            // World-space depth added to the denominator before normalising.
            // 0 = pure relative (current behaviour). Larger values blend toward
            // absolute, stabilising edge detection for close-up geometry without
            // losing smooth-surface suppression at distance.
            float _DepthBlend;

            float4x4 _ClipToView;

            int _ColorCount;
            float4 _SurfaceColors[32];
            float4 _OutlineColors[32];

            // Converts raw non-linear depth to linear eye depth (world units).
            // This ensures depth comparisons are consistent regardless of camera distance.
            // _ZBufferParams is a Unity built-in: (z/far, far, z/far*near, far-near) with reversed Z.
            float LinearizeDepth(float rawDepth)
            {
                return 1.0 / (_ZBufferParams.z * rawDepth + _ZBufferParams.w);
            }

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
                // 32 evenly spaced directions around a circle (every 11.25 degrees).
                // All vectors are unit length (computed from cos/sin), so no scaling needed.
                static const int NUM_DIRS = 32;
                static const float2 RING_DIRS[32] =
                {
                    float2( 1.0000,  0.0000),  //   0°
                    float2( 0.9808,  0.1951),  //  11.25°
                    float2( 0.9239,  0.3827),  //  22.5°
                    float2( 0.8315,  0.5556),  //  33.75°
                    float2( 0.7071,  0.7071),  //  45°
                    float2( 0.5556,  0.8315),  //  56.25°
                    float2( 0.3827,  0.9239),  //  67.5°
                    float2( 0.1951,  0.9808),  //  78.75°
                    float2( 0.0000,  1.0000),  //  90°
                    float2(-0.1951,  0.9808),  // 101.25°
                    float2(-0.3827,  0.9239),  // 112.5°
                    float2(-0.5556,  0.8315),  // 123.75°
                    float2(-0.7071,  0.7071),  // 135°
                    float2(-0.8315,  0.5556),  // 146.25°
                    float2(-0.9239,  0.3827),  // 157.5°
                    float2(-0.9808,  0.1951),  // 168.75°
                    float2(-1.0000,  0.0000),  // 180°
                    float2(-0.9808, -0.1951),  // 191.25°
                    float2(-0.9239, -0.3827),  // 202.5°
                    float2(-0.8315, -0.5556),  // 213.75°
                    float2(-0.7071, -0.7071),  // 225°
                    float2(-0.5556, -0.8315),  // 236.25°
                    float2(-0.3827, -0.9239),  // 247.5°
                    float2(-0.1951, -0.9808),  // 258.75°
                    float2( 0.0000, -1.0000),  // 270°
                    float2( 0.1951, -0.9808),  // 281.25°
                    float2( 0.3827, -0.9239),  // 292.5°
                    float2( 0.5556, -0.8315),  // 303.75°
                    float2( 0.7071, -0.7071),  // 315°
                    float2( 0.8315, -0.5556),  // 326.25°
                    float2( 0.9239, -0.3827),  // 337.5°
                    float2( 0.9808, -0.1951),  // 348.75°
                };

                // Sample center depth first so we can linearize it before sampling the ring.
                float centerDepth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_CameraDepthTexture, i.texcoord).r;
                float linearCenterDepth = LinearizeDepth(centerDepth);

                // Scale the ring radius proportionally with screen height so outline thickness
                // stays visually constant when the window is resized. _Scale is in "pixels at
                // 1080p": at 2160p the pixel count doubles, but objects are also twice as large
                // in pixels, so the visual proportion is unchanged.
                float pixelRadius = _Scale * (_ScreenParams.y / 1080.0);
                float2 texelRadius = _MainTex_TexelSize.xy * pixelRadius;

                // Sample remaining center data and all 8 ring positions.
                float3 centerNormal = SAMPLE_TEXTURE2D(_CameraNormalsTexture, sampler_CameraNormalsTexture, i.texcoord).rgb;
                float4 centerColor  = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.texcoord);

                float  ringDepth [32];
                float3 ringNormal[32];
                float4 ringColor [32];

                for (int s = 0; s < NUM_DIRS; s++)
                {
                    float2 uv = i.texcoord + RING_DIRS[s] * texelRadius;
                    ringDepth [s] = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_CameraDepthTexture, uv).r;
                    ringNormal[s] = SAMPLE_TEXTURE2D(_CameraNormalsTexture, sampler_CameraNormalsTexture, uv).rgb;
                    ringColor [s] = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv);
                }

                // Linearize ring depths; track min/max for priority selection below.
                float linearRingDepth[32];
                float linearMinDepth = linearCenterDepth;
                float linearMaxDepth = linearCenterDepth;
                for (int ld = 0; ld < NUM_DIRS; ld++)
                {
                    linearRingDepth[ld] = LinearizeDepth(ringDepth[ld]);
                    linearMinDepth = min(linearMinDepth, linearRingDepth[ld]);
                    linearMaxDepth = max(linearMaxDepth, linearRingDepth[ld]);
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

                // Walk outward in small steps per direction and check each step-to-step
                // relative linear depth difference. Using a ratio (delta / prev) makes the
                // threshold distance-independent: a smooth surface produces the same relative
                // gradient at any depth, while a true geometric edge produces a spike regardless
                // of how far away it is. The final step reuses the already-linearized ring
                // depth to avoid a redundant fetch.
                static const int DEPTH_STEPS = 5;
                float edgeDepth = 0;
                // Also track depth extremes across all step samples so the silhouette check
                // below sees any foreground geometry the step loop detected even if the ring
                // samples (at full radius) overshot it back onto the background.
                float stepMinLinear = linearCenterDepth;
                float stepMaxLinear = linearCenterDepth;
                [unroll]
                for (int d = 0; d < NUM_DIRS; d++)
                {
                    float prevLinear = linearCenterDepth;
                    [unroll]
                    for (int step = 1; step < DEPTH_STEPS; step++)
                    {
                        float t = (float)step / (float)DEPTH_STEPS;
                        float2 uv = i.texcoord + RING_DIRS[d] * texelRadius * t;
                        float stepRaw    = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_CameraDepthTexture, uv).r;
                        float stepLinear = LinearizeDepth(stepRaw);
                        if (abs(stepLinear - prevLinear) / (prevLinear + _DepthBlend) > _DepthThreshold * normalThreshold)
                            edgeDepth = 1;
                        stepMinLinear = min(stepMinLinear, stepLinear);
                        stepMaxLinear = max(stepMaxLinear, stepLinear);
                        prevLinear = stepLinear;
                    }
                    float ringLinear = linearRingDepth[d];
                    if (abs(ringLinear - prevLinear) / (prevLinear + _DepthBlend) > _DepthThreshold * normalThreshold)
                        edgeDepth = 1;
                }
                // Merge step-sample extremes into the ring extremes for a complete depth range.
                float allMinDepth = min(linearMinDepth, stepMinLinear);
                float allMaxDepth = max(linearMaxDepth, stepMaxLinear);

                // --- Normal edge ---
                // Normal differences are computed in [0,1] space; the *2-1 decode cancels out
                // in subtraction so this is equivalent to comparing in [-1,1] space.
                // Compare each ring sample against the true center and take the max difference.
                float maxNormalDiff = 0;
                for (int n = 0; n < NUM_DIRS; n++)
                {
                    float3 diff = ringNormal[n] - centerNormal;
                    maxNormalDiff = max(maxNormalDiff, dot(diff, diff));
                }
                float edgeNormal = sqrt(maxNormalDiff) > _NormalThreshold ? 1 : 0;

                // --- Color edge ---
                // Fires when any ring sample matches a different registered color than the center.
                // This catches edges like red vs blue that have similar luminance.
                int centerPriority = GetColorPriority(centerColor.rgb);
                int ringPriority[32];
                for (int c = 0; c < NUM_DIRS; c++)
                    ringPriority[c] = GetColorPriority(ringColor[c].rgb);

                float edgeColor = 0;
                for (int e = 0; e < NUM_DIRS; e++)
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
                // If linear depth spread exceeds _DepthContactThreshold = silhouette.
                // Silhouette: nearest sample (smallest linear depth) wins outright.
                // Contact:    lowest priority index across all samples wins.
                // ---------------------------------------------------------------

                // Using max/min ratio rather than (max-min)/center makes this check
                // truly scale-invariant: two surfaces at the same relative depth separation
                // produce the same ratio regardless of absolute camera distance.
                bool isSilhouette = (allMaxDepth / max(allMinDepth, 1e-5)) > (1.0 + _DepthContactThreshold);

                int winnerIndex = -1;

                if (isSilhouette)
                {
                    // Nearest-to-camera wins, but only if it is meaningfully closer than
                    // the center. Same-depth neighbours that happen to share a ring with a
                    // distant background must not steal the win — doing so bleeds their
                    // outline colour into adjacent surfaces at corners.
                    float nearestLinearDepth = linearCenterDepth;
                    winnerIndex = centerPriority;
                    bool foundValidNearSample = false;
                    for (int si = 0; si < NUM_DIRS; si++)
                    {
                        // Scale-invariant: is this sample more than _DepthContactThreshold
                        // times closer (i.e. at a fraction of center's depth)?
                        bool meaningfullyCloser = (linearCenterDepth / max(linearRingDepth[si], 1e-5)) > (1.0 + _DepthContactThreshold);
                        if (meaningfullyCloser && ringPriority[si] >= 0 && linearRingDepth[si] < nearestLinearDepth)
                        {
                            nearestLinearDepth = linearRingDepth[si];
                            winnerIndex        = ringPriority[si];
                            foundValidNearSample = true;
                        }
                    }
                    // If no registered near sample won, use the combined depth range (ring +
                    // steps) to check whether any surface is significantly closer than us.
                    // If so, we are the background looking at a foreground that just didn't
                    // match a registered colour — suppress to avoid drawing the background's
                    // own outline colour at foreground silhouettes.
                    if (!foundValidNearSample)
                    {
                        if ((linearCenterDepth / max(allMinDepth, 1e-5)) > (1.0 + _DepthContactThreshold))
                            winnerIndex = -1;
                    }
                }
                else
                {
                    // Contact edge — lowest priority index wins for a uniform outline colour
                    // along the boundary.
                    if (centerPriority >= 0) winnerIndex = centerPriority;
                    for (int ci = 0; ci < NUM_DIRS; ci++)
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