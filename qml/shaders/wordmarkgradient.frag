#version 440

// MarqueeTheme.swift:134-141: three golds swept top-leading to bottom-trailing,
// kept only where the wordmark's glyphs are.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 start;
    vec4 middle;
    vec4 end;
};

layout(binding = 1) uniform sampler2D source;

void main()
{
    float t = clamp((qt_TexCoord0.x + qt_TexCoord0.y) * 0.5, 0.0, 1.0);
    vec4 gold = t < 0.5 ? mix(start, middle, t * 2.0) : mix(middle, end, (t - 0.5) * 2.0);
    float coverage = texture(source, qt_TexCoord0).a;
    fragColor = gold * coverage * qt_Opacity;
}
