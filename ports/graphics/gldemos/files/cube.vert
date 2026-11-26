#version 450
// vkcube's vertex shader: each corner coloured, turned by the matrix.
layout(push_constant) uniform Transform {
    mat4 model_view_projection;
} transform;
layout(location = 0) in vec3 position;
layout(location = 1) in vec3 color;
layout(location = 0) out vec3 vertex_color;
void main() {
    vertex_color = color;
    gl_Position = transform.model_view_projection * vec4(position, 1.0);
}
