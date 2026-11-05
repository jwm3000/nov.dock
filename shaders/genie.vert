#version 440
// The genie: a window pouring into its dock slot through a funnel, as on
// macOS. It runs in two phases.
//
//   1. The funnel forms: the window's far edge stays put while its near edge
//      is pulled down into the slot, and its sides bend into a soft S-curve
//      from the window's width down to the slot's.
//   2. The window slides down the funnel: every row takes the funnel's width
//      at the height it has reached, so the window narrows as it pours in.
//
// Positions are worked out in a frame where the dock lies below the window
// ("canonical"): a runs across the window, b from its far edge (0) to the
// edge nearest the dock (1). The other dock edges are mirrored and/or
// transposed into it and back out again at the end.

layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec2 qt_MultiTexCoord0;

layout(location = 0) out vec2 coord;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float progress;  // 0 = window, 1 = in the slot
    float edge;      // dock edge: 0 bottom, 1 top, 2 left, 3 right
    vec4 fromRect;   // window, canonical x, y, w, h
    vec4 toRect;     // slot, canonical x, y, w, h
};

float ease(float t) {
    t = clamp(t, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

// A gentler S-curve for the funnel's sides.
float sides(float t) {
    t = clamp(t, 0.0, 1.0);
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

void main() {
    coord = qt_MultiTexCoord0;
    float s = qt_MultiTexCoord0.x;
    float t = qt_MultiTexCoord0.y;

    // Across (a) and along (b, toward the dock) for this vertex.
    float a = s;
    float b = t;
    if (edge > 2.5) { a = t; b = s; }              // right
    else if (edge > 1.5) { a = t; b = 1.0 - s; }   // left
    else if (edge > 0.5) { a = s; b = 1.0 - t; }   // top

    float fromTop = fromRect.y;
    float toTop = toRect.y;
    float toBottom = toRect.y + toRect.w;

    // Phase 1, the funnel forms; phase 2, the window slides down it.
    const float split = 0.4;
    float form = ease(progress / split);
    float slide = ease((progress - split) / (1.0 - split));

    float cy;
    if (progress < split)
        cy = fromTop + b * mix(fromRect.w, toBottom - fromTop, form);
    else
        cy = mix(mix(fromTop, toTop, slide), toBottom, b);

    // The funnel's width at this height: the window's above the window's far
    // edge, the slot's from the top of the slot down, an S-curve in between.
    float depth = sides((cy - fromTop) / max(toTop - fromTop, 1.0)) * form;
    float left  = mix(fromRect.x, toRect.x, depth);
    float right = mix(fromRect.x + fromRect.z, toRect.x + toRect.z, depth);
    float cx = mix(left, right, a);

    // Back from the canonical frame to the screen.
    vec2 pos = vec2(cx, cy);
    if (edge > 2.5) pos = vec2(cy, cx);             // right
    else if (edge > 1.5) pos = vec2(-cy, cx);       // left
    else if (edge > 0.5) pos = vec2(cx, -cy);       // top

    gl_Position = qt_Matrix * vec4(pos, 0.0, 1.0);
}
