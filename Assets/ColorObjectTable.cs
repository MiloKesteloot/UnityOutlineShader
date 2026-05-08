using System;
using System.Collections.Generic;
using UnityEngine;

[CreateAssetMenu(menuName = "Roystan/Color Object Table", fileName = "ColorObjectTable")]
public sealed class ColorObjectTable : ScriptableObject
{
    [Tooltip("Ordered list of color objects. Index 0 = highest priority.")]
    public List<ColorObject> objects = new()
    {
        new()
        {
            mainColor    = Color.red,
            outlineColor = new Color(0.5f, 0f, 0f),
            groupA       = new List<Color> { Color.red },
            groupB       = new()
        }
    };
}

[Serializable]
public sealed class ColorObject
{
    public string label = "Color Object";

    [Tooltip("Color shown in the final render for every alias of this object.")]
    public Color mainColor = Color.white;

    [Tooltip("Outline color drawn at edges involving this object.")]
    public Color outlineColor = Color.black;

    [Tooltip("Group A aliases. No lines drawn between two group-A pixels of the same object.")]
    public List<Color> groupA = new();

    [Tooltip("Group B aliases. Lines ARE drawn between group-A and group-B pixels of the same object.")]
    public List<Color> groupB = new();

    [Tooltip("Group C aliases. Lines are drawn between group-C and any other group of the same object.")]
    public List<Color> groupC = new();

    [Tooltip("Decoration aliases. Lines are drawn between different decoration colors, but never between decorations and group A/B/C. Decoration pixels keep their original color in the render.")]
    public List<Color> decorations = new();
}
