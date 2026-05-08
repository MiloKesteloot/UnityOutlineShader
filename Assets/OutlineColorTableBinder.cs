using UnityEngine;

public sealed class OutlineColorTableBinder : MonoBehaviour
{
    [Tooltip("The color object table asset to use.")]
    public ColorObjectTable colorObjectTable;

    [Range(0.01f, 0.5f)]
    public float colorTolerance = 0.05f;

    [Range(0.0001f, 10.0f)]
    public float depthContactThreshold = 0.001f;

    private const int MaxAliases = 64;
    private const int MaxObjects = 16;

    private readonly Vector4[] _aliasColors        = new Vector4[MaxAliases];
    private readonly Vector4[] _aliasIds           = new Vector4[MaxAliases];
    private readonly Vector4[] _objectMainColor    = new Vector4[MaxObjects];
    private readonly Vector4[] _objectOutlineColor = new Vector4[MaxObjects];

    private ColorObjectTable _lastTable;
    private float _lastTolerance;
    private float _lastContactThreshold;
    private int _lastHash;

    void Update()
    {
        int hash = ComputeHash();
        if (colorObjectTable != _lastTable
         || colorTolerance        != _lastTolerance
         || depthContactThreshold != _lastContactThreshold
         || hash                  != _lastHash)
        {
            Bake();
            _lastTable            = colorObjectTable;
            _lastTolerance        = colorTolerance;
            _lastContactThreshold = depthContactThreshold;
            _lastHash             = hash;
        }
    }

    private int ComputeHash()
    {
        if (colorObjectTable == null || colorObjectTable.objects == null)
            return 0;

        int h = 17;
        foreach (var obj in colorObjectTable.objects)
        {
            if (obj == null) continue;
            h = h * 31 + obj.mainColor.GetHashCode();
            h = h * 31 + obj.outlineColor.GetHashCode();
            if (obj.groupA != null)
                foreach (var c in obj.groupA) h = h * 31 + c.GetHashCode();
            if (obj.groupB != null)
                foreach (var c in obj.groupB) h = h * 31 + c.GetHashCode();
        }
        return h;
    }

    private void Bake()
    {
        int aliasCount  = 0;
        int objectCount = 0;

        if (colorObjectTable != null && colorObjectTable.objects != null)
        {
            int objLimit = Mathf.Min(colorObjectTable.objects.Count, MaxObjects);
            for (int objIdx = 0; objIdx < objLimit; objIdx++)
            {
                var obj = colorObjectTable.objects[objIdx];
                if (obj == null) continue;

                _objectMainColor[objectCount]    = (Vector4)obj.mainColor;
                _objectOutlineColor[objectCount] = (Vector4)obj.outlineColor;

                // groupId is unique per (object × subgroup): object 0 → ids 0,1; object 1 → ids 2,3; etc.
                int groupIdA = objectCount * 2;
                int groupIdB = objectCount * 2 + 1;

                // mainColor is always an implicit groupA alias.
                if (aliasCount < MaxAliases)
                {
                    Color mc = obj.mainColor;
                    _aliasColors[aliasCount] = new Vector4(mc.r, mc.g, mc.b, 0f);
                    _aliasIds[aliasCount]    = new Vector4(groupIdA, objectCount, 0f, 0f);
                    aliasCount++;
                }

                if (obj.groupA != null)
                    foreach (var c in obj.groupA)
                    {
                        if (aliasCount >= MaxAliases) break;
                        _aliasColors[aliasCount] = new Vector4(c.r, c.g, c.b, 0f);
                        _aliasIds[aliasCount]    = new Vector4(groupIdA, objectCount, 0f, 0f);
                        aliasCount++;
                    }

                if (obj.groupB != null)
                    foreach (var c in obj.groupB)
                    {
                        if (aliasCount >= MaxAliases) break;
                        _aliasColors[aliasCount] = new Vector4(c.r, c.g, c.b, 0f);
                        _aliasIds[aliasCount]    = new Vector4(groupIdB, objectCount, 0f, 0f);
                        aliasCount++;
                    }

                objectCount++;
            }
        }

        for (int i = aliasCount;  i < MaxAliases; i++) { _aliasColors[i] = Vector4.zero; _aliasIds[i] = new Vector4(-1f, -1f, 0f, 0f); }
        for (int i = objectCount; i < MaxObjects;  i++) { _objectMainColor[i] = Vector4.zero; _objectOutlineColor[i] = Vector4.zero; }

        Shader.SetGlobalInt("_AliasCount",           aliasCount);
        Shader.SetGlobalVectorArray("_AliasColors",  _aliasColors);
        Shader.SetGlobalVectorArray("_AliasIds",     _aliasIds);
        Shader.SetGlobalInt("_ObjectCount",          objectCount);
        Shader.SetGlobalVectorArray("_ObjectMainColor",    _objectMainColor);
        Shader.SetGlobalVectorArray("_ObjectOutlineColor", _objectOutlineColor);
        Shader.SetGlobalFloat("_ColorTolerance",           colorTolerance);
        Shader.SetGlobalFloat("_DepthContactThreshold",    depthContactThreshold);
    }
}
