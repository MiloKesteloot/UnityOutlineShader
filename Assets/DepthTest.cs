using UnityEngine;
using UnityEngine.Rendering.PostProcessing;
using System;

[Serializable]
[PostProcess(typeof(DepthTestRenderer), PostProcessEvent.BeforeTransparent, "Debug/Depth Test")]
public sealed class DepthTest : PostProcessEffectSettings { }

public sealed class DepthTestRenderer : PostProcessEffectRenderer<DepthTest>
{
    public override void Init()
    {
        Camera.main.depthTextureMode |= DepthTextureMode.Depth;
    }

    public override void Render(PostProcessRenderContext context)
    {
        context.camera.depthTextureMode |= DepthTextureMode.Depth;
        var sheet = context.propertySheets.Get(Shader.Find("Hidden/DepthTest"));
        context.command.BlitFullscreenTriangle(context.source, context.destination, sheet, 0);
    }
}