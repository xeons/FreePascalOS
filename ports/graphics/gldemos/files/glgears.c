/*
 * FreePascalOS
 * Copyright (C) 2026 Brandon Scott
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

/*
 * glgears: three turning gears in a window of the display server, drawn
 * with OpenGL ES 2 through EGL's FreePascalOS platform (the window is a
 * struct fpos_window, <freepascalos/windowing.h>). The arrow keys turn
 * the view, Escape or the close button end it; the frame rate is printed
 * every five seconds. "glgears -n FRAMES" draws that many frames, checks
 * the picture is not empty, prints the rate and ends (status 0 if the
 * gears were seen).
 */
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <freepascalos/windowing.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define WINDOW_SIDE 300 /* logical units */
#define TEETH_MAXIMUM 20
#define KEY_LEFT (FPOS_KEY_CODE_EXTENDED | 0x4B)
#define KEY_RIGHT (FPOS_KEY_CODE_EXTENDED | 0x4D)
#define KEY_UP (FPOS_KEY_CODE_EXTENDED | 0x48)
#define KEY_DOWN (FPOS_KEY_CODE_EXTENDED | 0x50)

struct vertex {
	GLfloat position[3];
	GLfloat normal[3];
};

struct gear {
	struct vertex *vertices;
	int vertex_count;
	int vertex_capacity;
	GLuint buffer;
};

struct matrix {
	GLfloat m[16];
};

static struct gear gears[3];
static GLuint program;
static GLint uniform_model_view_projection;
static GLint uniform_normal_matrix;
static GLint uniform_color;
static GLint uniform_light;
static GLfloat view_rotation_x = 20.0f;
static GLfloat view_rotation_y = 30.0f;
static int surface_width;
static int surface_height;

static double seconds_now(void)
{
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	return now.tv_sec + now.tv_nsec / 1e9;
}

/* --- Matrices (column major, as OpenGL takes them) ----------------------- */

static struct matrix matrix_identity(void)
{
	struct matrix result;
	memset(&result, 0, sizeof(result));
	result.m[0] = result.m[5] = result.m[10] = result.m[15] = 1.0f;
	return result;
}

static struct matrix matrix_multiply(const struct matrix *a, const struct matrix *b)
{
	struct matrix result;
	for (int column = 0; column < 4; column++)
		for (int row = 0; row < 4; row++) {
			GLfloat sum = 0;
			for (int k = 0; k < 4; k++)
				sum += a->m[k * 4 + row] * b->m[column * 4 + k];
			result.m[column * 4 + row] = sum;
		}
	return result;
}

static struct matrix matrix_translation(GLfloat x, GLfloat y, GLfloat z)
{
	struct matrix result = matrix_identity();
	result.m[12] = x;
	result.m[13] = y;
	result.m[14] = z;
	return result;
}

static struct matrix matrix_rotation(GLfloat degrees, GLfloat x, GLfloat y, GLfloat z)
{
	struct matrix result = matrix_identity();
	GLfloat radians = degrees * (GLfloat)M_PI / 180.0f;
	GLfloat c = cosf(radians), s = sinf(radians), t = 1.0f - c;
	result.m[0] = t * x * x + c;
	result.m[1] = t * x * y + s * z;
	result.m[2] = t * x * z - s * y;
	result.m[4] = t * x * y - s * z;
	result.m[5] = t * y * y + c;
	result.m[6] = t * y * z + s * x;
	result.m[8] = t * x * z + s * y;
	result.m[9] = t * y * z - s * x;
	result.m[10] = t * z * z + c;
	return result;
}

static struct matrix matrix_frustum(GLfloat left, GLfloat right, GLfloat bottom, GLfloat top, GLfloat near,
				    GLfloat far)
{
	struct matrix result;
	memset(&result, 0, sizeof(result));
	result.m[0] = 2 * near / (right - left);
	result.m[5] = 2 * near / (top - bottom);
	result.m[8] = (right + left) / (right - left);
	result.m[9] = (top + bottom) / (top - bottom);
	result.m[10] = -(far + near) / (far - near);
	result.m[11] = -1;
	result.m[14] = -2 * far * near / (far - near);
	return result;
}

/* --- Gear geometry --------------------------------------------------------- */

static void gear_add_vertex(struct gear *gear, GLfloat x, GLfloat y, GLfloat z, GLfloat nx, GLfloat ny,
			    GLfloat nz)
{
	struct vertex *vertex;
	if (gear->vertex_count == gear->vertex_capacity) {
		gear->vertex_capacity = gear->vertex_capacity ? gear->vertex_capacity * 2 : 256;
		gear->vertices = realloc(gear->vertices, gear->vertex_capacity * sizeof(struct vertex));
	}
	vertex = &gear->vertices[gear->vertex_count++];
	vertex->position[0] = x;
	vertex->position[1] = y;
	vertex->position[2] = z;
	vertex->normal[0] = nx;
	vertex->normal[1] = ny;
	vertex->normal[2] = nz;
}

/* A flat quadrilateral (two triangles) with one normal. */
static void gear_add_quad(struct gear *gear, const GLfloat a[3], const GLfloat b[3], const GLfloat c[3],
			  const GLfloat d[3], GLfloat nx, GLfloat ny, GLfloat nz)
{
	gear_add_vertex(gear, a[0], a[1], a[2], nx, ny, nz);
	gear_add_vertex(gear, b[0], b[1], b[2], nx, ny, nz);
	gear_add_vertex(gear, c[0], c[1], c[2], nx, ny, nz);
	gear_add_vertex(gear, a[0], a[1], a[2], nx, ny, nz);
	gear_add_vertex(gear, c[0], c[1], c[2], nx, ny, nz);
	gear_add_vertex(gear, d[0], d[1], d[2], nx, ny, nz);
}

static void point(GLfloat out[3], GLfloat radius, GLfloat angle, GLfloat z)
{
	out[0] = radius * cosf(angle);
	out[1] = radius * sinf(angle);
	out[2] = z;
}

/* A gear: a ring from inner_radius to the root of its teeth, which reach
   outer_radius; width thick, teeth deep. Built of flat faces: front and
   back, the teeth's sides and tops, and the hole's wall. */
static void gear_build(struct gear *gear, GLfloat inner_radius, GLfloat outer_radius, GLfloat width, int teeth,
		       GLfloat tooth_depth)
{
	const GLfloat root = outer_radius - tooth_depth / 2.0f;
	const GLfloat tip = outer_radius + tooth_depth / 2.0f;
	const GLfloat step = 2.0f * (GLfloat)M_PI / teeth;
	const GLfloat quarter = step / 4.0f;
	const GLfloat half = width * 0.5f;

	for (int i = 0; i < teeth; i++) {
		GLfloat angle = i * step;
		GLfloat a[3], b[3], c[3], d[3];
		for (int side = 0; side < 2; side++) {
			GLfloat z = side == 0 ? half : -half;
			GLfloat normal = side == 0 ? 1.0f : -1.0f;
			/* The ring's face for this tooth's span. */
			point(a, inner_radius, angle, z);
			point(b, root, angle, z);
			point(c, root, angle + step, z);
			point(d, inner_radius, angle + step, z);
			if (side == 0)
				gear_add_quad(gear, a, b, c, d, 0, 0, normal);
			else
				gear_add_quad(gear, d, c, b, a, 0, 0, normal);
			/* The tooth's face. */
			point(a, root, angle, z);
			point(b, tip, angle + quarter, z);
			point(c, tip, angle + 2 * quarter, z);
			point(d, root, angle + 3 * quarter, z);
			if (side == 0)
				gear_add_quad(gear, a, b, c, d, 0, 0, normal);
			else
				gear_add_quad(gear, d, c, b, a, 0, 0, normal);
		}
		/* The tooth's outward faces: rising side, top, falling side,
		   then the root up to the next tooth. */
		{
			const GLfloat edges[5][2] = {
				{root, angle},
				{tip, angle + quarter},
				{tip, angle + 2 * quarter},
				{root, angle + 3 * quarter},
				{root, angle + step},
			};
			for (int e = 0; e < 4; e++) {
				GLfloat nx, ny, length;
				point(a, edges[e][0], edges[e][1], half);
				point(b, edges[e][0], edges[e][1], -half);
				point(c, edges[e + 1][0], edges[e + 1][1], -half);
				point(d, edges[e + 1][0], edges[e + 1][1], half);
				nx = d[1] - a[1];
				ny = -(d[0] - a[0]);
				length = sqrtf(nx * nx + ny * ny);
				if (length > 0) {
					nx /= length;
					ny /= length;
				}
				gear_add_quad(gear, a, b, c, d, nx, ny, 0);
			}
		}
		/* The hole's wall, facing inward. */
		point(a, inner_radius, angle, -half);
		point(b, inner_radius, angle, half);
		point(c, inner_radius, angle + step, half);
		point(d, inner_radius, angle + step, -half);
		gear_add_quad(gear, a, b, c, d, -cosf(angle + step / 2), -sinf(angle + step / 2), 0);
	}

	glGenBuffers(1, &gear->buffer);
	glBindBuffer(GL_ARRAY_BUFFER, gear->buffer);
	glBufferData(GL_ARRAY_BUFFER, gear->vertex_count * sizeof(struct vertex), gear->vertices, GL_STATIC_DRAW);
}

/* --- Drawing --------------------------------------------------------------- */

static const char *vertex_shader_source =
	"uniform mat4 model_view_projection;\n"
	"uniform mat4 normal_matrix;\n"
	"uniform vec4 color;\n"
	"uniform vec3 light;\n"
	"attribute vec3 position;\n"
	"attribute vec3 normal;\n"
	"varying vec4 shade;\n"
	"void main() {\n"
	"  vec3 n = normalize((normal_matrix * vec4(normal, 0.0)).xyz);\n"
	"  float diffuse = max(dot(n, normalize(light)), 0.0);\n"
	"  shade = vec4(color.rgb * (0.25 + 0.75 * diffuse), color.a);\n"
	"  gl_Position = model_view_projection * vec4(position, 1.0);\n"
	"}\n";

static const char *fragment_shader_source =
	"precision mediump float;\n"
	"varying vec4 shade;\n"
	"void main() { gl_FragColor = shade; }\n";

static GLuint compile(GLenum kind, const char *source)
{
	GLuint shader = glCreateShader(kind);
	GLint compiled = 0;
	glShaderSource(shader, 1, &source, NULL);
	glCompileShader(shader);
	glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
	if (!compiled) {
		char log[1024];
		glGetShaderInfoLog(shader, sizeof(log), NULL, log);
		fprintf(stderr, "glgears: shader: %s\n", log);
		exit(1);
	}
	return shader;
}

static void setup_scene(void)
{
	program = glCreateProgram();
	glAttachShader(program, compile(GL_VERTEX_SHADER, vertex_shader_source));
	glAttachShader(program, compile(GL_FRAGMENT_SHADER, fragment_shader_source));
	glBindAttribLocation(program, 0, "position");
	glBindAttribLocation(program, 1, "normal");
	glLinkProgram(program);
	glUseProgram(program);
	uniform_model_view_projection = glGetUniformLocation(program, "model_view_projection");
	uniform_normal_matrix = glGetUniformLocation(program, "normal_matrix");
	uniform_color = glGetUniformLocation(program, "color");
	uniform_light = glGetUniformLocation(program, "light");
	glUniform3f(uniform_light, 5.0f, 5.0f, 10.0f);

	gear_build(&gears[0], 1.0f, 4.0f, 1.0f, 20, 0.7f);
	gear_build(&gears[1], 0.5f, 2.0f, 2.0f, 10, 0.7f);
	gear_build(&gears[2], 1.3f, 2.0f, 0.5f, 10, 0.7f);
	glEnable(GL_DEPTH_TEST);
}

static void draw_gear(const struct gear *gear, const struct matrix *projection, const struct matrix *view,
		      GLfloat x, GLfloat y, GLfloat angle, const GLfloat color[4])
{
	struct matrix translation = matrix_translation(x, y, 0);
	struct matrix rotation = matrix_rotation(angle, 0, 0, 1);
	struct matrix model = matrix_multiply(&translation, &rotation);
	struct matrix model_view = matrix_multiply(view, &model);
	struct matrix model_view_projection = matrix_multiply(projection, &model_view);

	glUniformMatrix4fv(uniform_model_view_projection, 1, GL_FALSE, model_view_projection.m);
	/* Rotations and translations only: the model view matrix turns
	   normals right as it is. */
	glUniformMatrix4fv(uniform_normal_matrix, 1, GL_FALSE, model_view.m);
	glUniform4fv(uniform_color, 1, color);
	glBindBuffer(GL_ARRAY_BUFFER, gear->buffer);
	glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, sizeof(struct vertex), (void *)0);
	glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, sizeof(struct vertex), (void *)(3 * sizeof(GLfloat)));
	glEnableVertexAttribArray(0);
	glEnableVertexAttribArray(1);
	glDrawArrays(GL_TRIANGLES, 0, gear->vertex_count);
}

static void draw_frame(GLfloat angle)
{
	static const GLfloat red[4] = {0.8f, 0.1f, 0.0f, 1.0f};
	static const GLfloat green[4] = {0.0f, 0.8f, 0.2f, 1.0f};
	static const GLfloat blue[4] = {0.2f, 0.2f, 1.0f, 1.0f};
	GLfloat aspect = (GLfloat)surface_height / (GLfloat)(surface_width ? surface_width : 1);
	struct matrix projection = matrix_frustum(-1.0f, 1.0f, -aspect, aspect, 5.0f, 60.0f);
	struct matrix view = matrix_translation(0, 0, -40.0f);
	struct matrix rotate_x = matrix_rotation(view_rotation_x, 1, 0, 0);
	struct matrix rotate_y = matrix_rotation(view_rotation_y, 0, 1, 0);

	view = matrix_multiply(&view, &rotate_x);
	view = matrix_multiply(&view, &rotate_y);

	glViewport(0, 0, surface_width, surface_height);
	glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	draw_gear(&gears[0], &projection, &view, -3.0f, -2.0f, angle, red);
	draw_gear(&gears[1], &projection, &view, 3.1f, -2.0f, -2.0f * angle - 9.0f, green);
	draw_gear(&gears[2], &projection, &view, -3.1f, 4.2f, -2.0f * angle - 25.0f, blue);
}

/* Whether the picture has something other than the background in it. */
static int picture_has_gears(void)
{
	int width = surface_width, height = surface_height;
	unsigned char *pixels = malloc((size_t)width * height * 4);
	int coloured = 0;
	if (!pixels)
		return 0;
	glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
	for (int i = 0; i < width * height; i++)
		if (pixels[i * 4] > 40 || pixels[i * 4 + 1] > 40 || pixels[i * 4 + 2] > 40)
			coloured++;
	free(pixels);
	printf("glgears: %d of %d pixels show gears\n", coloured, width * height);
	return coloured > width * height / 20;
}

/* --- The window and its events -------------------------------------------- */

/* Handles what came; 0 when the program should end. */
static int handle_events(struct fpos_display *display, struct fpos_window *window)
{
	struct fpos_window_message message;
	while (fpos_display_next_event(display, &message)) {
		switch (message.kind) {
		case FPOS_EVENT_CLOSE_REQUESTED:
			return 0;
		case FPOS_EVENT_RESIZED:
			fpos_window_set_surface(window, message.surface_width, message.surface_height);
			break;
		case FPOS_EVENT_SCALE_CHANGED:
			if (message.window == window->number && window->scale) {
				int width = window->width * (int)message.code / (int)window->scale;
				int height = window->height * (int)message.code / (int)window->scale;
				window->scale = message.code;
				fpos_window_set_surface(window, width, height);
			}
			break;
		case FPOS_EVENT_KEY:
			if (message.value == 0)
				break;
			if (message.code == FPOS_KEY_ESCAPE)
				return 0;
			if (message.code == KEY_LEFT)
				view_rotation_y += 5.0f;
			else if (message.code == KEY_RIGHT)
				view_rotation_y -= 5.0f;
			else if (message.code == KEY_UP)
				view_rotation_x += 5.0f;
			else if (message.code == KEY_DOWN)
				view_rotation_x -= 5.0f;
			break;
		default:
			break;
		}
	}
	return !display->broken;
}

int main(int argc, char **argv)
{
	static const EGLint config_attributes[] = {
		EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
		EGL_DEPTH_SIZE, 16,
		EGL_NONE,
	};
	static const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
	struct fpos_display display;
	struct fpos_window window;
	EGLDisplay egl_display;
	EGLConfig config;
	EGLint config_count = 0;
	EGLSurface surface;
	EGLContext context;
	long frame_limit = 0;
	long frames = 0, frames_counted = 0;
	double start, last_report;
	int side, status = 0;

	if (argc == 3 && strcmp(argv[1], "-n") == 0)
		frame_limit = atol(argv[2]);

	if (fpos_display_connect(&display) != 0) {
		fprintf(stderr, "glgears: no display server\n");
		return 1;
	}
	side = fpos_logical_to_pixels(WINDOW_SIDE, display.scale);
	if (fpos_window_create(&display, 120, 120, side, side, "Gears", FPOS_WINDOW_FRAMED | FPOS_WINDOW_RESIZABLE,
			       &window) != 0) {
		fprintf(stderr, "glgears: cannot make a window\n");
		return 1;
	}
	fpos_window_show(&window, 1);

	egl_display = eglGetDisplay(&display);
	if (!eglInitialize(egl_display, NULL, NULL) ||
	    !eglChooseConfig(egl_display, config_attributes, &config, 1, &config_count) || config_count == 0) {
		fprintf(stderr, "glgears: no EGL configuration for a window\n");
		return 1;
	}
	eglBindAPI(EGL_OPENGL_ES_API);
	surface = eglCreateWindowSurface(egl_display, config, &window, NULL);
	context = eglCreateContext(egl_display, config, EGL_NO_CONTEXT, context_attributes);
	if (surface == EGL_NO_SURFACE || context == EGL_NO_CONTEXT ||
	    !eglMakeCurrent(egl_display, surface, surface, context)) {
		fprintf(stderr, "glgears: cannot make an OpenGL ES context for the window (0x%x)\n", eglGetError());
		return 1;
	}
	printf("glgears: %s, %s\n", (const char *)glGetString(GL_RENDERER), (const char *)glGetString(GL_VERSION));
	setup_scene();

	start = last_report = seconds_now();
	while (handle_events(&display, &window)) {
		double now = seconds_now();
		surface_width = window.width;
		surface_height = window.height;
		draw_frame((GLfloat)fmod((now - start) * 70.0, 360.0));
		if (frame_limit && frames + 1 == frame_limit && !picture_has_gears())
			status = 1;
		eglSwapBuffers(egl_display, surface);
		frames++;
		frames_counted++;
		if (now - last_report >= 5.0 || (frame_limit && frames >= frame_limit)) {
			printf("glgears: %ld frames in %.1f seconds = %.1f FPS\n", frames_counted, now - last_report,
			       frames_counted / (now - last_report > 0 ? now - last_report : 1));
			fflush(stdout);
			last_report = now;
			frames_counted = 0;
		}
		if (frame_limit && frames >= frame_limit)
			break;
	}

	eglMakeCurrent(egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	eglDestroySurface(egl_display, surface);
	eglDestroyContext(egl_display, context);
	eglTerminate(egl_display);
	fpos_window_destroy(&window);
	fpos_display_disconnect(&display);
	if (frame_limit)
		printf("glgears: %s\n", status == 0 ? "gears drawn" : "FAIL: nothing drawn");
	return status;
}
