using UnityEngine;

public sealed class OutlineColorTableBinder : MonoBehaviour
{
    [Tooltip("The color table asset to use.")]
    public OutlineColorTable colorTable;

    [Range(0.01f, 0.5f)]
    public float colorTolerance = 0.05f;

    private const int MaxColors = 16;
    private readonly Vector4[] _surfaceColors = new Vector4[MaxColors];
    private readonly Vector4[] _outlineColors  = new Vector4[MaxColors];

    void Update()
    {
        int count = 0;

        if (colorTable != null && colorTable.entries != null)
        {
            count = Mathf.Min(colorTable.entries.Count, MaxColors);
            for (int i = 0; i < count; i++)
            {
                _surfaceColors[i] = (Vector4)colorTable.entries[i].surfaceColor;
                _outlineColors[i]  = (Vector4)colorTable.entries[i].outlineColor;
            }
        }

        for (int i = count; i < MaxColors; i++)
        {
            _surfaceColors[i] = Vector4.zero;
            _outlineColors[i]  = Vector4.zero;
        }

        Shader.SetGlobalInt("_ColorCount", count);
        Shader.SetGlobalVectorArray("_SurfaceColors", _surfaceColors);
        Shader.SetGlobalVectorArray("_OutlineColors",  _outlineColors);
        Shader.SetGlobalFloat("_ColorTolerance",       colorTolerance);
    }
}   