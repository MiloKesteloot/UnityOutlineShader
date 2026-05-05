using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering.PostProcessing;

// ---------------------------------------------------------------
// ScriptableObject asset — create one via:
//   Assets > Create > Roystan > Outline Color Table
// ---------------------------------------------------------------
[CreateAssetMenu(menuName = "Roystan/Outline Color Table", fileName = "OutlineColorTable")]
public sealed class OutlineColorTable : ScriptableObject
{
    [Tooltip("Ordered list of surface/outline color pairs. Index 0 = highest priority. Maximum 16 entries.")]
    public List<OutlineColorEntry> entries = new List<OutlineColorEntry>()
    {
        new OutlineColorEntry { surfaceColor = Color.red,   outlineColor = new Color(0.5f, 0f,   0f  ) },
        new OutlineColorEntry { surfaceColor = Color.green, outlineColor = new Color(0f,   0.5f, 0f  ) },
        new OutlineColorEntry { surfaceColor = Color.blue,  outlineColor = new Color(0f,   0f,   0.5f) },
    };
}

[Serializable]
public sealed class OutlineColorEntry
{
    public Color surfaceColor = Color.red;
    public Color outlineColor = Color.black;
}

// ---------------------------------------------------------------
// Post Process Settings
// ---------------------------------------------------------------
[Serializable]
[PostProcess(typeof(PostProcessOutlineRenderer), PostProcessEvent.BeforeStack, "Roystan/Post Process Outline")]
public sealed class PostProcessOutline : PostProcessEffectSettings
{
    [Tooltip("Number of pixels between samples tested for an edge.")]
    public IntParameter scale = new IntParameter { value = 1 };

    [Tooltip("Depth difference required to draw an edge.")]
    public FloatParameter depthThreshold = new FloatParameter { value = 1.5f };

    [Tooltip("World-space depth offset added to the normalisation denominator. 0 = pure relative (far-stable, close-variable). Higher values blend toward absolute sensitivity, stabilising outlines on close-up geometry.")]
    public FloatParameter depthBlend = new() { value = 0f };

    [Range(0, 1), Tooltip("Normal/view angle threshold that affects depth sensitivity on slopes.")]
    public FloatParameter depthNormalThreshold = new FloatParameter { value = 0.5f };

    [Tooltip("Scales how strongly depthNormalThreshold affects the depth threshold.")]
    public FloatParameter depthNormalThresholdScale = new FloatParameter { value = 7 };

    [Range(0, 1), Tooltip("Normal difference required to draw an edge.")]
    public FloatParameter normalThreshold = new FloatParameter { value = 0.4f };
}

// ---------------------------------------------------------------
// Renderer — color data comes from OutlineColorTableBinder via
// Shader.SetGlobal*, so no color params needed here.
// ---------------------------------------------------------------
public sealed class PostProcessOutlineRenderer : PostProcessEffectRenderer<PostProcessOutline>
{
    public override void Render(PostProcessRenderContext context)
    {
        context.camera.depthTextureMode |= DepthTextureMode.Depth;
        context.camera.depthTextureMode |= DepthTextureMode.DepthNormals;

        var sheet = context.propertySheets.Get(Shader.Find("Hidden/Roystan/Outline Post Process"));

        sheet.properties.SetFloat("_Scale",                     settings.scale);
        sheet.properties.SetFloat("_DepthThreshold",            settings.depthThreshold);
        sheet.properties.SetFloat("_DepthBlend",                settings.depthBlend);
        sheet.properties.SetFloat("_DepthNormalThreshold",      settings.depthNormalThreshold);
        sheet.properties.SetFloat("_DepthNormalThresholdScale", settings.depthNormalThresholdScale);
        sheet.properties.SetFloat("_NormalThreshold",           settings.normalThreshold);

        Matrix4x4 clipToView = GL.GetGPUProjectionMatrix(context.camera.projectionMatrix, true).inverse;
        sheet.properties.SetMatrix("_ClipToView", clipToView);

        context.command.BlitFullscreenTriangle(context.source, context.destination, sheet, 0);
    }
}