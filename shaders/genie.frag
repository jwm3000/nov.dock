#version 440
// Draws the bent window, with its outermost pixel softened so the curved
// sides do not show stair steps.

layout(location = 0) in vec2 coord;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float progress;
    float edge;
    vec4 fromRect;
    vec4 toRect;
};

layout(binding = 1) uniform sampler2D source;

void main() {
    vec4 color = texture(source, coord);
    vec2 d = max(fwidth(coord) * 1.25, vec2(1e-5));
    float soft = smoothstep(0.0, d.x, coord.x) * smoothstep(0.0, d.x, 1.0 - coord.x)
               * smoothstep(0.0, d.y, coord.y) * smoothstep(0.0, d.y, 1.0 - coord.y);
    fragColor = color * soft * qt_Opacity;
}
