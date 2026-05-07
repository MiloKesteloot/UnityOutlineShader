using System;
using UnityEngine;
using UnityEngine.Rendering.PostProcessing;

// ---------------------------------------------------------------
// Post Process Settings
// ---------------------------------------------------------------
[Serializable]
[PostProcess(typeof(PostProcessOutlineRenderer), PostProcessEvent.BeforeStack, "Roystan/Post Process Outline")]
public sealed class PostProcessOutline : PostProcessEffectSettings
{
    [Tooltip("Outline thickness in pixels at 1080p. Automatically scales at other resolutions to keep visual thickness constant.")]
    public FloatParameter scale = new() { value = 1f };

    [Tooltip("Depth difference required to draw an edge.")]
    public FloatParameter depthThreshold = new() { value = 1.5f };

    [Tooltip("World-space depth offset added to the normalisation denominator. 0 = pure relative (far-stable, close-variable). Higher values blend toward absolute sensitivity, stabilising outlines on close-up geometry.")]
    public FloatParameter depthBlend = new() { value = 0f };

    [Range(0, 1), Tooltip("Normal/view angle threshold that affects depth sensitivity on slopes.")]
    public FloatParameter depthNormalThreshold = new() { value = 0.5f };

    [Tooltip("Scales how strongly depthNormalThreshold affects the depth threshold.")]
    public FloatParameter depthNormalThresholdScale = new() { value = 7 };

    [Range(0, 1), Tooltip("Normal difference required to draw an edge.")]
    public FloatParameter normalThreshold = new() { value = 0.4f };
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
